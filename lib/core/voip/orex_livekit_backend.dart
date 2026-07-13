import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:matrix/matrix.dart';

import '../logging/orex_logger.dart';
import 'matrix_request_gate.dart';

@visibleForTesting
bool orexMediaKeySenderEpochMatches({
  required String? claimedEpoch,
  required String activeMembershipId,
}) => claimedEpoch == null || claimedEpoch == activeMembershipId;

@visibleForTesting
Set<String> orexMediaKeyRecipientIdsAfterLeaveDebounce(
  Iterable<String> currentParticipantIds,
) => currentParticipantIds.toSet();

/// Session-scoped MatrixRTC/LiveKit backend. It keeps the SDK wire format while
/// making delayed sender-key work cancellable, loading missing DeviceKeys, and
/// bounding key-delivery retries.
final class OrexLiveKitBackend extends LiveKitBackend {
  OrexLiveKitBackend({
    required super.livekitServiceUrl,
    required super.livekitAlias,
    required this.membershipEpoch,
    super.e2eeEnabled = true,
  });

  static const String _senderEpochField = 'org.orex.call.sender_membership_id';
  static const int _sendAttempts = 3;

  final String membershipEpoch;
  final Map<CallParticipant, Map<int, Uint8List>> _keys =
      <CallParticipant, Map<int, Uint8List>>{};

  Future<void> _operationTail = Future<void>.value();
  Timer? _pendingLocalKeyTimer;
  int? _pendingLocalKeyRevision;
  Timer? _memberLeaveTimer;
  DateTime _lastNewKeyAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _indexCounter = 0;
  int _latestLocalKeyIndex = 0;
  int _appliedLocalKeyRevision = -1;
  int _localKeyRevision = 0;
  int _epoch = 0;
  bool _disposed = false;
  Future<void>? _fullyDrained;

  /// Monotonic revision used by VoipService to invalidate its exact-recipient
  /// delivery snapshot whenever this backend rotates the local sender key.
  int get localKeyRevision => _localKeyRevision;

  Future<void> get fullyDrained =>
      _fullyDrained ?? _operationTail.then<void>((_) {}, onError: (_, _) {});

  Future<void> _enqueue(Future<void> Function(int epoch) operation) {
    final expectedEpoch = _epoch;
    final previous = _operationTail;
    late final Future<void> next;
    next = (() async {
      try {
        await previous;
      } catch (_) {
        // A failed network send must not poison the per-call operation queue.
      }
      if (_disposed || expectedEpoch != _epoch) return;
      await operation(expectedEpoch);
    })();
    _operationTail = next;
    return next;
  }

  bool _isCurrent(int expectedEpoch) => !_disposed && expectedEpoch == _epoch;

  CallMembership? _activeMembership(
    GroupCallSession groupCall,
    String userId,
    String deviceId,
  ) {
    for (final membership in groupCall.room.getCallMembershipsForUser(
      userId,
      deviceId,
      groupCall.voip,
    )) {
      if (membership.callId == groupCall.groupCallId &&
          membership.roomId == groupCall.room.id &&
          membership.scope == groupCall.scope &&
          membership.backend.type == type &&
          !membership.isExpired) {
        return membership;
      }
    }
    return null;
  }

  bool _validSenderEpoch(
    GroupCallSession groupCall,
    String userId,
    String deviceId,
    Map<String, dynamic> content,
  ) {
    final membership = _activeMembership(groupCall, userId, deviceId);
    if (membership == null) return false;
    final claimedEpoch = content[_senderEpochField]?.toString();
    // Other MatrixRTC implementations do not know the Orex extension. Keep
    // interoperability, while Orex-to-Orex events are strictly session-bound.
    return orexMediaKeySenderEpochMatches(
      claimedEpoch: claimedEpoch,
      activeMembershipId: membership.membershipId,
    );
  }

  List<CallParticipant> _uniqueRemoteParticipants(
    Iterable<CallParticipant> participants,
  ) {
    final byId = <String, CallParticipant>{};
    for (final participant in participants) {
      if (!participant.isLocal && participant.deviceId != null) {
        byId[participant.id] = participant;
      }
    }
    return byId.values.toList(growable: false);
  }

  Uint8List _newKey() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256), growable: false),
    );
  }

  int _nextKeyIndex(int keyRingSize) {
    final index = _indexCounter % keyRingSize;
    _indexCounter++;
    return index;
  }

  Uint8List? _localKey(GroupCallSession groupCall, int index) =>
      _keys[groupCall.localParticipant]?[index];

  Future<void> prepareLocalKey(GroupCallSession groupCall) {
    return _enqueue((epoch) async {
      if (_localKey(groupCall, _latestLocalKeyIndex) != null) return;
      await _makeNewSenderKey(
        groupCall,
        const <CallParticipant>[],
        delayBeforeUse: false,
        expectedEpoch: epoch,
        ignoreJoinDebounce: true,
      );
    });
  }

  /// Sends the current local sender key to exactly [participants]. Device keys
  /// are resolved inside the same serialized operation, so callers may mark
  /// only this snapshot as shared after the future succeeds.
  Future<void> shareCurrentKeyWith(
    GroupCallSession groupCall,
    Iterable<CallParticipant> participants,
  ) {
    final recipients = _uniqueRemoteParticipants(participants);
    return _enqueue((epoch) async {
      if (_localKey(groupCall, _latestLocalKeyIndex) == null) {
        await _makeNewSenderKey(
          groupCall,
          recipients,
          delayBeforeUse: false,
          expectedEpoch: epoch,
          ignoreJoinDebounce: true,
        );
      } else {
        await _sendEncryptionKey(
          groupCall,
          _latestLocalKeyIndex,
          recipients,
          expectedEpoch: epoch,
        );
        if (_appliedLocalKeyRevision != _localKeyRevision) {
          _scheduleLocalKeyUse(
            groupCall,
            groupCall.localParticipant!,
            _latestLocalKeyIndex,
            _localKeyRevision,
            epoch,
          );
        }
      }
    });
  }

  @override
  Future<void> preShareKey(GroupCallSession groupCall) async {
    await groupCall.onMemberStateChanged();
    final recipients = _uniqueRemoteParticipants(groupCall.participants);
    await _enqueue((epoch) async {
      await _makeNewSenderKey(
        groupCall,
        recipients,
        delayBeforeUse: false,
        expectedEpoch: epoch,
      );
    });
  }

  Future<void> _makeNewSenderKey(
    GroupCallSession groupCall,
    List<CallParticipant> recipients, {
    required bool delayBeforeUse,
    required int expectedEpoch,
    bool ignoreJoinDebounce = false,
  }) async {
    if (!_isCurrent(expectedEpoch) || !e2eeEnabled) return;
    final existing = _localKey(groupCall, _latestLocalKeyIndex);
    final joinDelay = groupCall.voip.timeouts!.makeKeyOnJoinDelay;
    if (!ignoreJoinDebounce &&
        existing != null &&
        _lastNewKeyAt.add(joinDelay).isAfter(DateTime.now())) {
      await _sendEncryptionKey(
        groupCall,
        _latestLocalKeyIndex,
        recipients,
        expectedEpoch: expectedEpoch,
      );
      if (_appliedLocalKeyRevision != _localKeyRevision) {
        _scheduleLocalKeyUse(
          groupCall,
          groupCall.localParticipant!,
          _latestLocalKeyIndex,
          _localKeyRevision,
          expectedEpoch,
        );
      }
      return;
    }

    final participant = groupCall.localParticipant;
    if (participant == null) {
      throw StateError('MatrixRTC local participant is unavailable');
    }
    final index = _nextKeyIndex(groupCall.voip.keyRingSize);
    final key = _newKey();
    await _setEncryptionKey(
      groupCall,
      participant,
      index,
      key,
      recipients: recipients,
      delayBeforeUse: delayBeforeUse,
      expectedEpoch: expectedEpoch,
    );
  }

  Future<void> _setEncryptionKey(
    GroupCallSession groupCall,
    CallParticipant participant,
    int index,
    Uint8List key, {
    required List<CallParticipant> recipients,
    required bool delayBeforeUse,
    required int expectedEpoch,
  }) async {
    if (!_isCurrent(expectedEpoch)) return;
    final participantKeys = _keys.putIfAbsent(
      participant,
      () => <int, Uint8List>{},
    );
    final old = participantKeys[index];
    if (old != null && !identical(old, key)) old.fillRange(0, old.length, 0);
    participantKeys[index] = Uint8List.fromList(key);
    key.fillRange(0, key.length, 0);

    if (!participant.isLocal) {
      await _applyKey(
        groupCall,
        participant,
        index,
        participantKeys[index]!,
        expectedEpoch,
      );
      return;
    }

    _latestLocalKeyIndex = index;
    _localKeyRevision++;
    final keyRevision = _localKeyRevision;
    // Invalidate an older delayed apply before any network await. Its callback
    // may already be queued, so it also validates [keyRevision] below.
    _pendingLocalKeyTimer?.cancel();
    _pendingLocalKeyTimer = null;
    _pendingLocalKeyRevision = null;
    _lastNewKeyAt = DateTime.now();
    if (recipients.isNotEmpty) {
      await _sendEncryptionKey(
        groupCall,
        index,
        recipients,
        expectedEpoch: expectedEpoch,
      );
    }
    if (!_isCurrent(expectedEpoch)) return;

    if (!delayBeforeUse) {
      await _applyKey(
        groupCall,
        participant,
        index,
        participantKeys[index]!,
        expectedEpoch,
      );
      if (_isCurrent(expectedEpoch) && _localKeyRevision == keyRevision) {
        _appliedLocalKeyRevision = keyRevision;
      }
      return;
    }

    _scheduleLocalKeyUse(
      groupCall,
      participant,
      index,
      keyRevision,
      expectedEpoch,
    );
  }

  void _scheduleLocalKeyUse(
    GroupCallSession groupCall,
    CallParticipant participant,
    int index,
    int keyRevision,
    int expectedEpoch,
  ) {
    if (_pendingLocalKeyRevision == keyRevision) {
      return;
    }
    _pendingLocalKeyTimer?.cancel();
    _pendingLocalKeyRevision = keyRevision;
    _pendingLocalKeyTimer = Timer(groupCall.voip.timeouts!.useKeyDelay, () {
      if (_pendingLocalKeyRevision == keyRevision) {
        _pendingLocalKeyTimer = null;
      }
      unawaited(
        _enqueue((timerEpoch) async {
          try {
            if (timerEpoch != expectedEpoch ||
                keyRevision != _localKeyRevision) {
              return;
            }
            final currentKey = _localKey(groupCall, index);
            if (currentKey == null) return;
            await _applyKey(
              groupCall,
              participant,
              index,
              currentKey,
              timerEpoch,
            );
            if (_isCurrent(timerEpoch) && keyRevision == _localKeyRevision) {
              _appliedLocalKeyRevision = keyRevision;
            }
          } finally {
            if (_pendingLocalKeyRevision == keyRevision) {
              _pendingLocalKeyRevision = null;
            }
          }
        }).catchError((Object error, StackTrace stackTrace) {
          OrexLog.d('VoipE2EE', 'delayed sender-key apply failed', error);
        }),
      );
    });
  }

  Future<void> _applyKey(
    GroupCallSession groupCall,
    CallParticipant participant,
    int index,
    Uint8List key,
    int expectedEpoch,
  ) async {
    if (!_isCurrent(expectedEpoch)) return;
    await groupCall.voip.delegate.keyProvider?.onSetEncryptionKey(
      participant,
      Uint8List.fromList(key),
      index,
    );
    if (!_isCurrent(expectedEpoch)) return;
  }

  Future<void> _sendEncryptionKey(
    GroupCallSession groupCall,
    int index,
    List<CallParticipant> recipients, {
    required int expectedEpoch,
  }) async {
    if (!_isCurrent(expectedEpoch) || recipients.isEmpty) return;
    final key = _localKey(groupCall, index);
    if (key == null) throw StateError('Local MatrixRTC media key is missing');
    final content = EncryptionKeysEventContent(<EncryptionKeyEntry>[
      EncryptionKeyEntry(index, base64Encode(key)),
    ], groupCall.groupCallId);
    final data = <String, Object>{
      ...content.toJson(),
      'conf_id': groupCall.groupCallId,
      'device_id': groupCall.client.deviceID!,
      'room_id': groupCall.room.id,
      _senderEpochField: membershipEpoch,
    };
    await _sendToDeviceWithRetry(
      groupCall,
      recipients,
      data,
      EventTypes.GroupCallMemberEncryptionKeys,
      expectedEpoch,
    );
  }

  Future<void> _sendToDeviceWithRetry(
    GroupCallSession groupCall,
    List<CallParticipant> recipients,
    Map<String, Object> data,
    String eventType,
    int expectedEpoch,
  ) {
    return OrexMatrixRequestGate.shared.run<void>(
      operationName: 'matrixrtc-media-key:$eventType',
      maxAttempts: _sendAttempts,
      operation: () async {
        if (!_isCurrent(expectedEpoch)) return;
        await _sendToDevice(groupCall, recipients, data, eventType);
      },
    );
  }

  Future<void> _sendToDevice(
    GroupCallSession groupCall,
    List<CallParticipant> recipients,
    Map<String, Object> data,
    String eventType,
  ) async {
    final targets = _uniqueRemoteParticipants(recipients);
    if (targets.isEmpty) return;
    final encryptedRoom = groupCall.room.encrypted;
    if (!encryptedRoom) {
      final payload = <String, Map<String, Map<String, Object>>>{};
      for (final target in targets) {
        payload.putIfAbsent(
          target.userId,
          () => <String, Map<String, Object>>{},
        )[target.deviceId!] = data;
      }
      await groupCall.client.sendToDevice(
        eventType,
        VoIP.customTxid ?? groupCall.client.generateUniqueTransactionId(),
        payload,
      );
      return;
    }

    // Media sender keys are secrets. An encrypted Matrix room must never fall
    // back to a plaintext to-device event while crypto is still initializing.
    if (!groupCall.client.encryptionEnabled ||
        groupCall.client.encryption == null) {
      throw StateError('Matrix encryption is unavailable for media-key send');
    }

    await groupCall.client.userDeviceKeysLoading;
    var missing = targets
        .where((target) {
          return groupCall
                  .client
                  .userDeviceKeys[target.userId]
                  ?.deviceKeys[target.deviceId] ==
              null;
        })
        .toList(growable: false);
    if (missing.isNotEmpty) {
      await groupCall.client.updateUserDeviceKeys(
        additionalUsers: missing.map((target) => target.userId).toSet(),
      );
      missing = targets
          .where((target) {
            return groupCall
                    .client
                    .userDeviceKeys[target.userId]
                    ?.deviceKeys[target.deviceId] ==
                null;
          })
          .toList(growable: false);
    }
    if (missing.isNotEmpty) {
      throw StateError(
        'Missing Matrix DeviceKeys for ${missing.map((p) => p.id).join(', ')}',
      );
    }
    final deviceKeys = targets
        .map(
          (target) => groupCall
              .client
              .userDeviceKeys[target.userId]!
              .deviceKeys[target.deviceId]!,
        )
        // The Matrix SDK may filter targets in-place before encryption.
        .toList();
    final blocked = deviceKeys.where((device) => device.blocked).toList();
    if (blocked.isNotEmpty) {
      throw StateError(
        'Blocked Matrix device(s) cannot receive media keys: '
        '${blocked.map((device) => '${device.userId}:${device.deviceId}').join(', ')}',
      );
    }
    await groupCall.client.sendToDeviceEncrypted(deviceKeys, eventType, data);
  }

  @override
  Future<void> requestEncrytionKey(
    GroupCallSession groupCall,
    List<CallParticipant> remoteParticipants,
  ) {
    final recipients = _uniqueRemoteParticipants(remoteParticipants);
    return _enqueue((epoch) async {
      final data = <String, Object>{
        'conf_id': groupCall.groupCallId,
        'device_id': groupCall.client.deviceID!,
        'room_id': groupCall.room.id,
        _senderEpochField: membershipEpoch,
      };
      await _sendToDeviceWithRetry(
        groupCall,
        recipients,
        data,
        EventTypes.GroupCallMemberEncryptionKeysRequest,
        epoch,
      );
    });
  }

  @override
  Future<void> onCallEncryption(
    GroupCallSession groupCall,
    String userId,
    String deviceId,
    Map<String, dynamic> content,
  ) {
    return _enqueue((epoch) async {
      if (!e2eeEnabled ||
          !_validSenderEpoch(groupCall, userId, deviceId, content)) {
        return;
      }
      final keyContent = EncryptionKeysEventContent.fromJson(content);
      if (keyContent.callId != groupCall.groupCallId) return;
      final participant = CallParticipant(
        groupCall.voip,
        userId: userId,
        deviceId: deviceId,
      );
      for (final entry in keyContent.keys) {
        await _setEncryptionKey(
          groupCall,
          participant,
          entry.index,
          base64Decode(entry.key),
          recipients: const <CallParticipant>[],
          delayBeforeUse: false,
          expectedEpoch: epoch,
        );
      }
    });
  }

  @override
  Future<void> onCallEncryptionKeyRequest(
    GroupCallSession groupCall,
    String userId,
    String deviceId,
    Map<String, dynamic> content,
  ) async {
    if (!e2eeEnabled) return;
    var membership = _activeMembership(groupCall, userId, deviceId);
    if (membership == null) {
      final useMsc3757 =
          groupCall.room.roomVersion?.contains('msc3757') ?? false;
      final stateKey = groupCall.voip.useUnprotectedPerDeviceStateKeys
          ? '${deviceId}_$userId'
          : useMsc3757
          ? '${userId}_$deviceId'
          : userId;
      await groupCall.room.client.getRoomStateWithKey(
        groupCall.room.id,
        EventTypes.GroupCallMember,
        stateKey,
      );
      await groupCall.onMemberStateChanged();
      membership = _activeMembership(groupCall, userId, deviceId);
    }
    if (membership == null) return;
    final claimedEpoch = content[_senderEpochField]?.toString();
    if (!orexMediaKeySenderEpochMatches(
      claimedEpoch: claimedEpoch,
      activeMembershipId: membership.membershipId,
    )) {
      return;
    }
    await shareCurrentKeyWith(groupCall, <CallParticipant>[
      CallParticipant(groupCall.voip, userId: userId, deviceId: deviceId),
    ]);
  }

  @override
  Future<void> onNewParticipant(
    GroupCallSession groupCall,
    List<CallParticipant> anyJoined,
  ) {
    final recipients = _uniqueRemoteParticipants(<CallParticipant>[
      ...groupCall.participants,
      ...anyJoined,
    ]);
    return _enqueue((epoch) async {
      await _makeNewSenderKey(
        groupCall,
        recipients,
        delayBeforeUse: true,
        expectedEpoch: epoch,
      );
    }).catchError((Object error, StackTrace stackTrace) {
      // GroupCallSession.enter() awaits this callback. DeviceKeys and Olm
      // sessions may legitimately arrive one sync later, so transport/key
      // delivery failure must keep the call fail-closed and let the explicit
      // reconciliation loop retry instead of rolling back Matrix membership.
      OrexLog.d('VoipE2EE', 'participant key delivery deferred', error);
    });
  }

  @override
  Future<void> onLeftParticipant(
    GroupCallSession groupCall,
    List<CallParticipant> anyLeft,
  ) async {
    for (final participant in anyLeft) {
      final removed = _keys.remove(participant);
      for (final key in removed?.values ?? const <Uint8List>[]) {
        key.fillRange(0, key.length, 0);
      }
    }
    _memberLeaveTimer?.cancel();
    final scheduledEpoch = _epoch;
    _memberLeaveTimer = Timer(groupCall.voip.timeouts!.makeKeyOnLeaveDelay, () {
      _memberLeaveTimer = null;
      // Re-evaluate the live participant set when the debounce expires. A
      // mobile device may leave and rejoin with the same Matrix device id in
      // this window; excluding the stale `anyLeft` snapshot would rotate away
      // the key that was just shared with that reconnected device.
      final recipientIds = orexMediaKeyRecipientIdsAfterLeaveDebounce(
        groupCall.participants
            .where((participant) => !participant.isLocal)
            .map((participant) => participant.id),
      );
      final recipients = _uniqueRemoteParticipants(
        groupCall.participants.where(
          (participant) => recipientIds.contains(participant.id),
        ),
      );
      unawaited(
        _enqueue((epoch) async {
          if (epoch != scheduledEpoch) return;
          await _makeNewSenderKey(
            groupCall,
            recipients,
            delayBeforeUse: true,
            expectedEpoch: epoch,
            ignoreJoinDebounce: true,
          );
        }).catchError((Object error, StackTrace stackTrace) {
          OrexLog.d('VoipE2EE', 'leave key rotation failed', error);
        }),
      );
    });
  }

  void _scrubKeyMaterial() {
    for (final participantKeys in _keys.values) {
      for (final key in participantKeys.values) {
        key.fillRange(0, key.length, 0);
      }
    }
    _keys.clear();
    _latestLocalKeyIndex = 0;
    _appliedLocalKeyRevision = -1;
    _localKeyRevision = 0;
    _lastNewKeyAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  @override
  Future<void> dispose(GroupCallSession groupCall) async {
    if (_disposed) {
      final drain = _fullyDrained;
      if (drain != null) {
        try {
          await drain.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          OrexLog.d('VoipE2EE', 'timed out awaiting disposed key backend');
        }
      }
      return;
    }
    _disposed = true;
    _epoch++;
    _pendingLocalKeyTimer?.cancel();
    _pendingLocalKeyTimer = null;
    _pendingLocalKeyRevision = null;
    _memberLeaveTimer?.cancel();
    _memberLeaveTimer = null;
    final drain = _operationTail.then<void>((_) {}, onError: (_, _) {});
    final cleanup = drain.whenComplete(_scrubKeyMaterial);
    final boundedCleanup = cleanup.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        // A dead plugin/transport Future must not retain call keys or block the
        // provider lease forever. The disposed epoch prevents new operations;
        // scrub now and allow native provider release to continue.
        _scrubKeyMaterial();
        OrexLog.d('VoipE2EE', 'forced cleanup of stalled key backend');
      },
    );
    _fullyDrained = boundedCleanup;
    await boundedCleanup;
    await super.dispose(groupCall);
  }
}

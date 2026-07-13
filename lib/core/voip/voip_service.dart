import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Типы делегата (MediaDevices/RTCPeerConnection) берём из webrtc_interface —
// именно их ожидает WebRTCDelegate. У flutter_webrtc есть устаревший
// одноимённый MediaDevices, поэтому flutter_webrtc импортируем под префиксом.
import 'package:webrtc_interface/webrtc_interface.dart';

import '../config/orex_config.dart';
import '../logging/orex_logger.dart';
import 'call_attempt.dart';
import 'call_cleanup_coordinator.dart';
import 'call_disposition_registry.dart';
import 'call_lifecycle_policy.dart';
import 'call_ring_policy.dart';
import 'matrix_request_gate.dart';
import 'personal_call_signaling.dart';
import 'livekit_e2ee_key_provider.dart';
import 'orex_livekit_backend.dart';

export 'call_attempt.dart';
export 'call_disposition_registry.dart';
export 'call_ring_policy.dart';
export 'matrix_request_gate.dart'
    show orexIsMatrixRateLimitError, orexMatrixRateLimitInfo;

class _PendingIncomingRing {
  const _PendingIncomingRing(this.room, this.occurredAt, this.ringEventId);

  final Room room;
  final DateTime occurredAt;
  final String ringEventId;
}

class _FreshIncomingRing {
  const _FreshIncomingRing(this.occurredAt, this.ringEventId);

  final DateTime occurredAt;
  final String ringEventId;
}

class _ShownIncomingRing {
  const _ShownIncomingRing(this.ringEventId, this.occurredAt);

  final String? ringEventId;
  final DateTime? occurredAt;
}

class _ValidatedDisposition {
  const _ValidatedDisposition(this.roomId, this.ringEventId);

  final String roomId;
  final String? ringEventId;
}

class _DeferredRemoteDisposition {
  const _DeferredRemoteDisposition({
    required this.type,
    required this.roomId,
    required this.sender,
    required this.ringEventId,
    required this.occurredAt,
  });

  final String type;
  final String roomId;
  final String sender;
  final String? ringEventId;
  final DateTime? occurredAt;
}

class _OutgoingRing {
  const _OutgoingRing(this.eventId);

  final String eventId;
}

class OrexIncomingCall {
  const OrexIncomingCall({required this.room, this.ringEventId});

  final Room room;
  final String? ringEventId;

  OrexCallInstance get instance =>
      OrexCallInstance(roomId: room.id, ringEventId: ringEventId);
}

class OrexIncomingCallDismissal extends OrexCallInstance {
  const OrexIncomingCallDismissal({
    required super.roomId,
    super.ringEventId,
    this.cancelsPendingAccept = true,
  });

  final bool cancelsPendingAccept;
}

class OrexRemoteCallAccepted extends OrexCallInstance {
  const OrexRemoteCallAccepted({required super.roomId, super.ringEventId});
}

class _CallKeyShareState {
  _CallKeyShareState(this.groupCall, this.owner);

  final GroupCallSession groupCall;
  final Object owner;
  final Set<String> sharedParticipantIds = <String>{};
  int sharedLocalKeyRevision = -1;
  Future<lk.BaseKeyProvider>? keyProviderLease;
  Future<void>? mediaOperationsDrained;
  Future<void> _tail = Future<void>.value();
  bool active = true;

  Future<void> run(Future<void> Function() operation) {
    final previous = _tail;
    late final Future<void> next;
    next = (() async {
      try {
        await previous;
      } catch (_) {
        // Each reconciliation attempt reports its own error.
      }
      if (!active) return;
      await operation();
    })();
    _tail = next;
    return next;
  }

  void invalidate() {
    active = false;
    sharedParticipantIds.clear();
  }
}

class OrexRemoteCallTermination {
  const OrexRemoteCallTermination({
    required this.roomId,
    required this.reason,
    this.ringEventId,
  });

  final String roomId;
  final OrexRemoteCallTerminationReason reason;
  final String? ringEventId;
}

/// MatrixRTC-сигналинг звонков (стек Element Call).
///
/// Раньше клиент просто коннектился к LiveKit-комнате и НИКАК не сообщал об
/// этом в Matrix — поэтому у собеседника «ничего не происходило». Здесь мы
/// задействуем модуль [VoIP] из SDK с LiveKit-бэкендом: он публикует в state
/// комнаты событие `com.famedly.call.member` (через [GroupCallSession.enter]) и
/// слушает входящие членства других участников. Само медиа (микрофон/камера)
/// по-прежнему гонится вашим `livekit_client` (см. CallSession) — SDK медиа для
/// LiveKit-бэкенда намеренно не трогает.
///
/// ВАЖНО: MatrixRTC-сигналинг помечен как e2ee-capable, но фактическое
/// шифрование медиапотока зависит от конфигурации LiveKit/key-provider в
/// [CallSession]. Это нужно держать отдельным security-инвариантом.
class VoipService extends ChangeNotifier {
  final OrexLiveKitE2eeKeyProvider e2eeKeyProvider =
      OrexLiveKitE2eeKeyProvider();

  VoipService(this.client) {
    _signaling = PersonalCallSignaling(client);
    voip = VoIP(client, _OrexCallDelegate(this));
    // Входящие ловим СКАНИРОВАНИЕМ комнат на каждом sync (надёжнее, чем
    // voip.onIncomingGroupCall: не зависит от того, открывали ли мы чат, и не
    // «перезванивает» по уже существующему звонку при перезагрузке).
    // Snapshot calls and ring events already present in the startup cache. A
    // ring that arrives while persisted suppress state is being restored must
    // still be treated as new; without this baseline the final startup scan
    // marked all visible calls as historical and swallowed genuine foreground
    // calls.
    _seedStartupIncomingState();
    // A ring event can be followed immediately by MatrixRTC membership state,
    // so room.lastEvent is not a reliable transport for foreground incoming
    // presentation. Observe the decrypted timeline directly and feed the exact
    // ring event into the same deduplicated scanner path.
    _timelineSub = client.onTimelineEvent.stream.listen(_handleTimelineEvent);
    _suppressionRestore = _restorePersistedLeftCalls();
    _syncSub = client.onSync.stream.listen((_) {
      if (_suppressionRestored) _scan();
      _scheduleStaleMembershipCleanup();
    }); // sync scanner
    _toDeviceSub = client.onToDeviceEvent.stream.listen(_handleToDeviceEvent);
    // «Обработано на другом моём устройстве» (принят/отклонён) → закрыть входящий.
    // Явные remote-disposition события закрывают звонок немедленно. Нельзя
    // ждать, пока MatrixRTC membership протухнет или stale lastEvent fallback
    // перестанет выглядеть активным.
    // Первичный scan запускается после восстановления persisted suppress.
    // Иначе продолжающийся звонок, из которого пользователь уже вышел до
    // process restart, успевает снова превратиться во "входящий".
    unawaited(_suppressionRestore);
    // Чистим СВОИ зависшие членства (после перезагрузки/закрытия вкладки во
    // время звонка) — иначе другой аккаунт видит нас «в звонке» (фантом).
    _staleMembershipCleanupTimer = Timer(
      const Duration(seconds: 4),
      _scheduleStaleMembershipCleanup,
    );
  }

  /// Cleanup is serialized with call ownership. Removing Matrix state while a
  /// cached SDK GroupCallSession is still entered makes Matrix immediately
  /// force-join it again, producing the phantom loop seen in the logs.
  void _scheduleStaleMembershipCleanup() {
    if (_disposed || _staleMembershipCleanupInFlight != null) return;
    late final Future<void> operation;
    operation = _cleanupOwnStaleMemberships().whenComplete(() {
      if (identical(_staleMembershipCleanupInFlight, operation)) {
        _staleMembershipCleanupInFlight = null;
      }
    });
    _staleMembershipCleanupInFlight = operation;
    unawaited(operation);
  }

  /// Удаляем своё членство в звонках, в которых мы на самом деле не находимся.
  Future<void> _cleanupOwnStaleMemberships() async {
    final myId = client.userID;
    final roomIds = <String>{
      ..._pendingMembershipCleanupRooms,
      for (final room in client.rooms)
        if (_callMembers(room).contains(myId)) room.id,
    };
    for (final roomId in roomIds) {
      if (_disposed) return;
      if (active?.room.id == roomId || _enterRequestRoomId == roomId) {
        continue;
      }
      final room = client.getRoomById(roomId);
      if (room == null) continue;
      await _cleanupStaleRoomState(room, operationName: 'startup');
    }
  }

  Future<void> _cleanupStaleRoomState(
    Room room, {
    required String operationName,
  }) async {
    if (active?.room.id == room.id) return;
    final hasOwnMembership = _callMembers(room).contains(client.userID);
    final staleSessions = voip.groupCalls.values
        .where(
          (gc) =>
              gc.room.id == room.id &&
              !identical(gc, active) &&
              (hasOwnMembership ||
                  (gc.state != GroupCallState.localCallFeedUninitialized &&
                      gc.state != GroupCallState.localCallFeedInitialized)),
        )
        .toList(growable: false);
    if (!hasOwnMembership && staleSessions.isEmpty) return;

    // Remove process-local ownership before Matrix emits the membership
    // removal. This prevents Matrix SDK's state listener from force-entering
    // the same stale GroupCallSession again.
    for (final gc in staleSessions) {
      voip.groupCalls.removeWhere((_, value) => identical(value, gc));
    }
    final membershipCallId = staleSessions.isEmpty
        ? room.id
        : staleSessions.first.groupCallId;
    final result = await const OrexCallCleanupCoordinator().cleanup(
      sessions: [
        for (final gc in staleSessions)
          OrexCallCleanupSession(
            label: gc.groupCallId,
            leave: () => OrexMatrixRequestGate.shared.run<void>(
              operationName: '$operationName-stale-session-leave',
              coalesceKey: 'matrixrtc-leave:${room.id}:${gc.groupCallId}',
              maxAttempts: 1,
              operationTimeout: const Duration(seconds: 10),
              operation: gc.leave,
            ),
            disposeBackend: () async {
              final backend = gc.backend;
              if (backend is OrexLiveKitBackend) await backend.dispose(gc);
            },
          ),
      ],
      removeMembership: () => OrexMatrixRequestGate.shared.run<void>(
        operationName: '$operationName-membership-cleanup',
        coalesceKey: 'membership-cleanup:${room.id}:$membershipCallId',
        maxAttempts: 1,
        operationTimeout: const Duration(seconds: 10),
        operation: () => room.removeFamedlyCallMemberEvent(
          membershipCallId,
          voip,
        ),
      ),
    );
    for (final failure in result.failures) {
      OrexLog.d(
        'Voip',
        'stale cleanup step failed room=${room.id} step=${failure.step}',
        failure.error,
      );
    }
    if (result.membershipRemoved) {
      _pendingMembershipCleanupRooms.remove(room.id);
      OrexLog.d('Voip', 'removed phantom call membership room=${room.id}');
    } else {
      _pendingMembershipCleanupRooms.add(room.id);
      OrexLog.d('Voip', 'cleanup stale membership deferred room=${room.id}');
    }
  }

  static const _handledEventType = OrexCallSignalTypes.handled;
  static const _acceptedEventType = OrexCallSignalTypes.accepted;
  static const _rejectedEventType = OrexCallSignalTypes.rejected;
  static const _busyEventType = OrexCallSignalTypes.busy;
  static const _endedEventType = OrexCallSignalTypes.ended;

  String? _ringEventIdFromContent(Map<String, dynamic> content) {
    for (final key in const <String>['orex_ring_event_id', 'ring_event_id']) {
      final value = content[key]?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  void _handleToDeviceEvent(ToDeviceEvent event) {
    if (_disposed) return;
    if (event.type == _handledEventType && event.sender == client.userID) {
      _handleOwnDeviceHandled(event);
      return;
    }
    if (event.type != _acceptedEventType &&
        event.type != _rejectedEventType &&
        event.type != _busyEventType &&
        event.type != _endedEventType) {
      return;
    }

    final roomId = event.content['room_id']?.toString().trim();
    final sender = event.sender.trim();
    if (roomId == null || roomId.isEmpty || sender.isEmpty) return;
    final disposition = _DeferredRemoteDisposition(
      type: event.type,
      roomId: roomId,
      sender: sender,
      ringEventId: _ringEventIdFromContent(event.content),
      occurredAt: _eventTimestamp(event.content['disposition_at_ms']),
    );
    if (_outgoingRingPendingRooms.contains(roomId) &&
        active?.room.id == roomId &&
        _activeRingEventId == null) {
      (_deferredRemoteDispositions[roomId] ??= <_DeferredRemoteDisposition>[])
          .add(disposition);
      return;
    }
    _applyRemoteDisposition(disposition);
  }

  void _drainDeferredRemoteDispositions(String roomId) {
    final pending = _deferredRemoteDispositions.remove(roomId);
    if (pending == null) return;
    for (final disposition in pending) {
      _applyRemoteDisposition(disposition);
    }
  }

  void _tombstoneAndDismissCallAttempt(
    OrexCallInstance instance, {
    DateTime? occurredAt,
    bool cancelsPendingAccept = true,
  }) {
    _recordCallDisposition(
      instance.roomId,
      occurredAt: occurredAt,
      ringEventId: instance.ringEventId,
    );
    _cancelRoomCallEnded(instance.roomId);
    _suppressCall(instance.roomId, instance.ringEventId);
    _removeShownAttempt(instance);
    _dismiss.add(
      OrexIncomingCallDismissal(
        roomId: instance.roomId,
        ringEventId: instance.ringEventId,
        cancelsPendingAccept: cancelsPendingAccept,
      ),
    );
  }

  void _handleOwnDeviceHandled(ToDeviceEvent event) {
    final originDeviceId = event.content['origin_device_id']?.toString().trim();
    final currentDeviceId = client.deviceID?.trim();
    if (originDeviceId != null &&
        originDeviceId.isNotEmpty &&
        currentDeviceId != null &&
        currentDeviceId.isNotEmpty &&
        originDeviceId == currentDeviceId) {
      return;
    }
    final roomId = event.content['room_id']?.toString().trim();
    if (roomId == null || roomId.isEmpty) return;
    final handledAt = _eventTimestamp(event.content['handled_at_ms']);
    if (!orexIsPlausibleCallControlTimestamp(handledAt)) {
      OrexLog.d('Voip', 'ignored implausible handled timestamp room=$roomId');
      return;
    }
    final ringEventId = _ringEventIdFromContent(event.content);
    if (ringEventId != null) {
      _promoteLegacyCallInstance(
        roomId,
        ringEventId,
        occurredAt: handledAt,
      );
    }
    final hasCurrentCall = _hasCurrentCallInstance(roomId);
    final expectedRingEventId = _currentRingEventId(roomId);
    if (!orexShouldApplyCallDisposition(
      hasCurrentCall: hasCurrentCall,
      expectedRingEventId: expectedRingEventId,
      receivedRingEventId: ringEventId,
    )) {
      if (orexShouldRecordOutOfOrderExactTombstone(
        currentRingEventId: expectedRingEventId,
        receivedRingEventId: ringEventId,
      )) {
        _recordCallDisposition(
          roomId,
          occurredAt: handledAt,
          ringEventId: ringEventId!,
        );
      }
      OrexLog.d(
        'Voip',
        'ignored stale handled room=$roomId ring=$ringEventId '
            'expected=$expectedRingEventId',
      );
      return;
    }
    _tombstoneAndDismissCallAttempt(
      OrexCallInstance(roomId: roomId, ringEventId: ringEventId),
      occurredAt: handledAt,
    );
  }

  _ValidatedDisposition? _validatedRemoteDisposition(
    _DeferredRemoteDisposition disposition,
  ) {
    final room = client.getRoomById(disposition.roomId);
    if (room == null || disposition.sender == client.userID) {
      OrexLog.d(
        'Voip',
        'ignored remote disposition type=${disposition.type} '
            'room=${disposition.roomId} sender=${disposition.sender}',
      );
      return null;
    }
    final joinedPeer = room
        .getParticipants([Membership.join])
        .any((user) => user.id == disposition.sender);
    if (!joinedPeer && room.directChatMatrixID != disposition.sender) {
      OrexLog.d(
        'Voip',
        'ignored non-peer disposition type=${disposition.type} '
            'room=${disposition.roomId} sender=${disposition.sender}',
      );
      return null;
    }

    if (!orexIsPlausibleCallControlTimestamp(disposition.occurredAt)) {
      OrexLog.d(
        'Voip',
        'ignored implausible disposition timestamp '
            'type=${disposition.type} room=${disposition.roomId}',
      );
      return null;
    }

    final hasCurrentCall = _hasCurrentCallInstance(disposition.roomId);
    if (!orexShouldTrustRemoteDispositionForRoom(
      isPersonalRoom: isPersonalCallRoom(room),
      hasCurrentCall: hasCurrentCall,
    )) {
      OrexLog.d(
        'Voip',
        'ignored disposition outside current personal attempt '
            'type=${disposition.type} room=${disposition.roomId}',
      );
      return null;
    }

    if (disposition.ringEventId != null) {
      _promoteLegacyCallInstance(
        disposition.roomId,
        disposition.ringEventId!,
        occurredAt: disposition.occurredAt,
      );
    }
    final expectedRingEventId = _currentRingEventId(disposition.roomId);
    if (!orexShouldApplyCallDisposition(
      hasCurrentCall: hasCurrentCall,
      expectedRingEventId: expectedRingEventId,
      receivedRingEventId: disposition.ringEventId,
    )) {
      final ringEventId = disposition.ringEventId;
      if (orexShouldRecordOutOfOrderExactTombstone(
        currentRingEventId: expectedRingEventId,
        receivedRingEventId: ringEventId,
      )) {
        // A cancellation for a same-room redial can legitimately overtake its
        // ring. Preserve the current A, but tombstone exact B so B cannot
        // surface when its timeline event arrives later.
        _recordCallDisposition(
          disposition.roomId,
          occurredAt: disposition.occurredAt,
          ringEventId: ringEventId!,
        );
      }
      OrexLog.d(
        'Voip',
        'ignored stale disposition type=${disposition.type} '
            'room=${disposition.roomId} ring=${disposition.ringEventId} '
            'expected=$expectedRingEventId',
      );
      return null;
    }
    return _ValidatedDisposition(disposition.roomId, disposition.ringEventId);
  }

  void _applyWakeCancellation(_DeferredRemoteDisposition disposition) {
    if (_disposed ||
        (disposition.type != _handledEventType &&
            disposition.type != _endedEventType)) {
      return;
    }
    final validated = _validatedRemoteDisposition(disposition);
    if (validated == null || validated.ringEventId == null) return;
    _tombstoneAndDismissCallAttempt(
      OrexCallInstance(
        roomId: validated.roomId,
        ringEventId: validated.ringEventId,
      ),
      occurredAt: disposition.occurredAt,
      // A handled envelope closes sibling ringing surfaces after another
      // device accepted. An ended envelope may cancel a still-pending accept,
      // but neither plaintext wake envelope is authoritative for established
      // media teardown; encrypted to-device control owns that decision.
      cancelsPendingAccept: disposition.type == _endedEventType,
    );
  }

  void _applyRemoteDisposition(_DeferredRemoteDisposition disposition) {
    if (_disposed) return;
    final validated = _validatedRemoteDisposition(disposition);
    if (validated == null) return;
    final instance = OrexCallInstance(
      roomId: validated.roomId,
      ringEventId: validated.ringEventId,
    );
    if (disposition.type == _handledEventType) {
      _tombstoneAndDismissCallAttempt(
        instance,
        occurredAt: disposition.occurredAt,
        // This is the original caller cancelling the outstanding ring UI after
        // receiving `accepted`. It must close stale/sibling presentations, but
        // must never invalidate the accepting device's in-flight MatrixRTC join.
        cancelsPendingAccept: false,
      );
      return;
    }
    if (disposition.type == _acceptedEventType) {
      if (validated.ringEventId != null) {
        _tombstoneAndDismissCallAttempt(
          instance,
          occurredAt: disposition.occurredAt,
        );
      }
      _remoteAccepted.add(
        OrexRemoteCallAccepted(
          roomId: validated.roomId,
          ringEventId: validated.ringEventId,
        ),
      );
      return;
    }
    if (disposition.type == _rejectedEventType) {
      _recordRejected(validated.roomId);
      _handleRemoteTermination(
        validated.roomId,
        OrexRemoteCallTerminationReason.rejected,
        occurredAt: disposition.occurredAt,
        ringEventId: validated.ringEventId,
      );
      return;
    }
    if (disposition.type == _busyEventType) {
      _recordBusy(validated.roomId);
      _handleRemoteTermination(
        validated.roomId,
        OrexRemoteCallTerminationReason.busy,
        occurredAt: disposition.occurredAt,
        ringEventId: validated.ringEventId,
      );
      return;
    }
    _handleRemoteTermination(
      validated.roomId,
      OrexRemoteCallTerminationReason.ended,
      occurredAt: disposition.occurredAt,
      ringEventId: validated.ringEventId,
    );
  }

  /// Short-lived outcomes and replay tombstones are owned by a dedicated
  /// lifecycle component rather than by this orchestration service.
  final OrexCallDispositionRegistry _dispositions =
      OrexCallDispositionRegistry(maxExactAttempts: 256);
  final Map<String, DateTime> _persistedLeftAt = <String, DateTime>{};
  final Map<String, Set<String>> _persistedLeftMemberships =
      <String, Set<String>>{};
  final Map<String, String?> _persistedLeftRingEventIds = <String, String?>{};
  Future<void>? _suppressionRestore;
  bool _suppressionRestored = false;
  bool _disposed = false;
  final Map<String, _OutgoingRing> _ringEventIds = <String, _OutgoingRing>{};
  final Map<String, String?> _incomingRingEventIds = <String, String?>{};
  final Set<String> _outgoingRingPendingRooms = <String>{};
  final Map<String, List<_DeferredRemoteDisposition>>
  _deferredRemoteDispositions = <String, List<_DeferredRemoteDisposition>>{};
  String? _activeRingEventId;
  final Set<String> _seenIncomingRingEventIds = <String>{};
  static const int _maxRememberedIncomingRingEvents = 256;
  static const int _maxRememberedExactCallAttempts = 256;
  final Set<String> _startupExistingCallRoomIds = <String>{};
  final Map<String, _PendingIncomingRing> _pendingFreshRingRooms =
      <String, _PendingIncomingRing>{};
  Timer? _staleMembershipCleanupTimer;
  Future<void>? _staleMembershipCleanupInFlight;
  final Set<String> _pendingMembershipCleanupRooms = <String>{};

  static const _leftCallsPrefsKey = 'orex_voip_left_calls_v1';
  static const _maxPersistedLeftAge = Duration(days: 7);

  void _recordRejected(String roomId) => _dispositions.recordRejected(roomId);

  DateTime? _eventTimestamp(Object? raw) =>
      _dispositions.parseTimestamp(raw);

  void _recordCallDisposition(
    String roomId, {
    DateTime? occurredAt,
    String? ringEventId,
    Duration? cleanupAfter = const Duration(minutes: 2),
  }) =>
      _dispositions.record(
        roomId,
        occurredAt: occurredAt,
        ringEventId: ringEventId,
        cleanupAfter: cleanupAfter,
      );

  Future<void> _restorePersistedLeftCalls() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_leftCallsPrefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final now = DateTime.now();
          for (final entry in decoded.entries) {
            final roomId = entry.key.toString().trim();
            final value = entry.value;
            final milliseconds = value is Map
                ? switch (value['left_at']) {
                    int raw => raw,
                    num raw => raw.toInt(),
                    String raw => int.tryParse(raw),
                    _ => null,
                  }
                : switch (value) {
                    int raw => raw,
                    num raw => raw.toInt(),
                    String raw => int.tryParse(raw),
                    _ => null,
                  };
            if (roomId.isEmpty || milliseconds == null || milliseconds <= 0) {
              continue;
            }
            final leftAt = DateTime.fromMillisecondsSinceEpoch(milliseconds);
            final age = now.difference(leftAt);
            if (age.isNegative || age > _maxPersistedLeftAge) continue;
            final memberships = <String>{};
            final rawMemberships = value is Map ? value['memberships'] : null;
            if (rawMemberships is List) {
              for (final raw in rawMemberships) {
                final signature = raw?.toString().trim() ?? '';
                if (signature.isNotEmpty) memberships.add(signature);
              }
            }
            final rawRingEventId = value is Map
                ? value['orex_ring_event_id']?.toString().trim()
                : null;
            final ringEventId = rawRingEventId == null || rawRingEventId.isEmpty
                ? null
                : rawRingEventId;
            _persistedLeftAt[roomId] = leftAt;
            _persistedLeftMemberships[roomId] = memberships;
            _persistedLeftRingEventIds[roomId] = ringEventId;
            _recordCallDisposition(
              roomId,
              occurredAt: leftAt,
              ringEventId: ringEventId,
              cleanupAfter: null,
            );
            _suppressCall(roomId, ringEventId);
          }
        }
      }
    } catch (e) {
      OrexLog.d('Voip', 'restore left-call suppress state failed', e);
    } finally {
      _suppressionRestored = true;
      if (!_disposed) {
        final pendingRings = _pendingFreshRingRooms.values.toList(
          growable: false,
        );
        _pendingFreshRingRooms.clear();
        for (final pending in pendingRings) {
          _presentFreshIncomingRing(
            pending.room,
            pending.occurredAt,
            pending.ringEventId,
          );
        }
        _scan(markExistingAsSeen: true);
      }
    }
  }

  Future<void> _persistLeftCalls() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, Object?>{
        for (final entry in _persistedLeftAt.entries)
          entry.key: <String, Object?>{
            'left_at': entry.value.millisecondsSinceEpoch,
            'memberships':
                (_persistedLeftMemberships[entry.key] ?? const <String>{})
                    .toList(growable: false),
            if (_persistedLeftRingEventIds[entry.key] != null)
              'orex_ring_event_id': _persistedLeftRingEventIds[entry.key],
          },
      };
      if (payload.isEmpty) {
        await prefs.remove(_leftCallsPrefsKey);
      } else {
        await prefs.setString(_leftCallsPrefsKey, jsonEncode(payload));
      }
    } catch (e) {
      OrexLog.d('Voip', 'persist left-call suppress state failed', e);
    }
  }

  void _clearPersistedLeftCall(String roomId) {
    final removedAt = _persistedLeftAt.remove(roomId);
    final removedMemberships = _persistedLeftMemberships.remove(roomId);
    final removedRingEventId = _persistedLeftRingEventIds.remove(roomId);
    if (removedAt == null &&
        removedMemberships == null &&
        removedRingEventId == null) {
      return;
    }
    unawaited(_persistLeftCalls());
  }

  Set<String> _remoteCallMembershipSignatures(Room room) {
    final myId = client.userID;
    return room
        .getCallMembershipsFromRoom(voip)
        .values
        .expand((memberships) => memberships)
        .where(
          (membership) => !membership.isExpired && membership.userId != myId,
        )
        .map(
          (membership) => <Object?>[
            membership.userId,
            membership.deviceId,
            membership.callId,
            membership.membershipId,
          ].join('\u001f'),
        )
        .toSet();
  }

  void _handleRemoteTermination(
    String roomId,
    OrexRemoteCallTerminationReason reason, {
    DateTime? occurredAt,
    String? ringEventId,
  }) {
    // Keep the original ring event id until CallController has forwarded an
    // exact `handled` cancellation to the peer's sibling devices. Removing it
    // here made reject/busy lose the only token capable of stopping a killed
    // tablet/secondary phone. cancelOutstandingRing() consumes it single-flight.
    _tombstoneAndDismissCallAttempt(
      OrexCallInstance(roomId: roomId, ringEventId: ringEventId),
      occurredAt: occurredAt,
    );
    _remoteTerminations.add(
      OrexRemoteCallTermination(
        roomId: roomId,
        reason: reason,
        ringEventId: ringEventId,
      ),
    );
  }

  /// Собеседник отклонил звонок в этой комнате (недавно).
  bool wasRejected(String roomId) => _dispositions.wasRejected(roomId);

  void clearRejected(String roomId) => _dispositions.clearRejected(roomId);

  void _recordBusy(String roomId) => _dispositions.recordBusy(roomId);

  bool wasBusy(String roomId) => _dispositions.wasBusy(roomId);

  void clearBusy(String roomId) => _dispositions.clearBusy(roomId);

  /// Сообщить инициатору, что пользователь явно принял звонок.
  Future<void> notifyAccepted(OrexCallInstance instance) =>
      _signaling.sendDisposition(instance, _acceptedEventType);

  /// Сообщить инициатору (другим участникам комнаты), что мы отклонили звонок.
  Future<void> notifyRejected(OrexCallInstance instance) =>
      _signaling.sendDisposition(instance, _rejectedEventType);

  Future<void> notifyBusy(OrexCallInstance instance) =>
      _signaling.sendDisposition(instance, _busyEventType);

  /// Явно завершить личный звонок на удалённых устройствах.
  ///
  /// MatrixRTC membership остаётся источником присутствия в звонке, но его
  /// удаление приходит через sync не мгновенно. Это событие — быстрый control
  /// plane, чтобы удалённая сторона сразу прекратила ringtone/UI.
  Future<void> notifyEnded(OrexCallInstance instance) async {
    final roomId = instance.roomId;
    final room = client.getRoomById(roomId);
    if (room == null || !isPersonalCallRoom(room)) return;
    final outgoingRing = _ringEventIds[roomId];
    if (outgoingRing != null &&
        orexCallInstanceIdsMatch(outgoingRing.eventId, instance.ringEventId)) {
      _ringEventIds.remove(roomId);
    }
    await Future.wait<void>([
      _signaling.sendDisposition(instance, _endedEventType),
      if (outgoingRing != null &&
          orexCallInstanceIdsMatch(outgoingRing.eventId, instance.ringEventId))
        _signaling.sendCancellation(
          room,
          ringEventId: outgoingRing.eventId,
          action: 'ended',
        ).then((sent) {
          if (!sent &&
              !_ringEventIds.containsKey(roomId) &&
              isCurrentCallInstance(instance)) {
            _ringEventIds[roomId] = outgoingRing;
          }
        }),
    ]);
  }

  /// Cancels only the outstanding incoming-ring presentation on the peer's
  /// devices. The caller invokes this after one peer device accepted/rejected,
  /// so killed sibling devices receive an exact FCM cancellation from the
  /// original ring sender without ending the accepted media call.
  Future<void> cancelOutstandingRing(OrexCallInstance instance) async {
    final roomId = instance.roomId;
    final room = client.getRoomById(roomId);
    if (room == null || !isPersonalCallRoom(room)) return;
    final outgoingRing = _ringEventIds[roomId];
    if (outgoingRing == null ||
        !orexCallInstanceIdsMatch(outgoingRing.eventId, instance.ringEventId)) {
      return;
    }
    _ringEventIds.remove(roomId);
    final sent = await _signaling.sendCancellation(
      room,
      ringEventId: outgoingRing.eventId,
      action: 'handled',
    );
    if (!sent &&
        !_ringEventIds.containsKey(roomId) &&
        isCurrentCallInstance(instance)) {
      _ringEventIds[roomId] = outgoingRing;
    }
  }

  final Client client;
  late final PersonalCallSignaling _signaling;
  late final VoIP voip;

  StreamSubscription? _syncSub;
  StreamSubscription<Event>? _timelineSub;
  StreamSubscription<ToDeviceEvent>? _toDeviceSub;
  final StreamController<OrexIncomingCall> _incoming =
      StreamController<OrexIncomingCall>.broadcast();
  final StreamController<OrexIncomingCallDismissal> _dismiss =
      StreamController<OrexIncomingCallDismissal>.broadcast();
  final StreamController<OrexRemoteCallAccepted> _remoteAccepted =
      StreamController<OrexRemoteCallAccepted>.broadcast();
  final StreamController<OrexRemoteCallTermination> _remoteTerminations =
      StreamController<OrexRemoteCallTermination>.broadcast();
  final StreamController<OrexCallInstancePromotion> _instancePromotions =
      StreamController<OrexCallInstancePromotion>.broadcast();

  // MatrixRTC membership can briefly disappear/reappear during sync while the
  // SDK rewrites `com.famedly.call.member`. Do not close an incoming dialog or
  // clear local suppress state on the first "no call" frame; wait for a stable
  // no-call state instead.
  static const Duration _endedDebounceDelay = Duration(milliseconds: 1800);

  final Map<String, Timer> _endedDebounceTimers = <String, Timer>{};
  final Map<String, _ShownIncomingRing> _shownAttempts =
      <String, _ShownIncomingRing>{};
  final Set<String> _legacySuppressedRooms = <String>{};
  final Set<String> _exactFallbackSuppressedRooms = <String>{};
  final Map<String, DateTime> _suppressedExactAttempts = <String, DateTime>{};
  final Set<String> _emittedPromotionAttempts = <String>{};
  _CallKeyShareState? _keyShareState;
  Completer<void>? _enterCompletion;
  Object? _enterRequestOwner;
  String? _enterRequestRoomId;
  String? _enterRequestRingEventId;
  int _enterGeneration = 0;
  Future<void> _shutdownComplete = Future<void>.value();

  /// Входящие звонки: roomId комнаты, где идёт звонок, в который мы не вошли.
  Stream<OrexIncomingCall> get onIncomingCall => _incoming.stream;

  Stream<OrexCallInstancePromotion> get onCallInstancePromotion =>
      _instancePromotions.stream;

  /// Уже обнаруженные входящие, которые могли попасть в broadcast stream до
  /// готовности Navigator/UI. Main replays этот список после первого кадра,
  /// иначе звонок можно было потерять до открытия любого чата.
  List<OrexIncomingCall> visibleIncomingCalls() => _shownAttempts.entries
      .map((entry) {
        final room = client.getRoomById(entry.key);
        return room == null
            ? null
            : OrexIncomingCall(
                room: room,
                ringEventId: entry.value.ringEventId,
              );
      })
      .whereType<OrexIncomingCall>()
      .toList(growable: false);

  List<Room> visibleIncomingRooms() => visibleIncomingCalls()
      .map((incoming) => incoming.room)
      .toList(growable: false);

  /// Комнаты, по которым надо ЗАКРЫТЬ открытый входящий (звонок кончился или
  /// обработан на другом устройстве).
  Stream<OrexIncomingCallDismissal> get onDismissIncoming => _dismiss.stream;

  Stream<OrexRemoteCallAccepted> get onRemoteCallAccepted =>
      _remoteAccepted.stream;

  Stream<OrexRemoteCallTermination> get onRemoteCallTermination =>
      _remoteTerminations.stream;

  /// Текущий звонок, в который мы вошли (опубликовали своё членство).
  GroupCallSession? active;
  Object? _activeOwner;

  bool _hasCurrentCallInstance(String roomId) =>
      active?.room.id == roomId ||
      (_enterRequestOwner != null && _enterRequestRoomId == roomId) ||
      _incomingRingEventIds.containsKey(roomId) ||
      _shownAttempts.containsKey(roomId);

  String? _currentRingEventId(String roomId) {
    if (active?.room.id == roomId && _activeRingEventId != null) {
      return _activeRingEventId;
    }
    if (_enterRequestOwner != null &&
        _enterRequestRoomId == roomId &&
        _enterRequestRingEventId != null) {
      return _enterRequestRingEventId;
    }
    final incomingRingEventId = _incomingRingEventIds[roomId];
    if (incomingRingEventId != null) return incomingRingEventId;
    final shownRingEventId = _shownAttempts[roomId]?.ringEventId;
    if (shownRingEventId != null) return shownRingEventId;
    return null;
  }

  String? incomingRingEventId(String roomId) => _incomingRingEventIds[roomId];

  String? activeRingEventId(String roomId) =>
      active?.room.id == roomId ? _activeRingEventId : null;

  bool isCurrentCallInstance(OrexCallInstance instance) =>
      _hasCurrentCallInstance(instance.roomId) &&
      orexCallInstanceIdsMatch(
        _currentRingEventId(instance.roomId),
        instance.ringEventId,
      );

  /// Whether this exact incoming attempt still owns a visible ringing route.
  /// This is stricter than [isCurrentCallInstance]: handled attempts retain
  /// their identity tombstone while their UI must stay closed.
  bool isIncomingCallVisible(OrexCallInstance instance) {
    final shown = _shownAttempts[instance.roomId];
    return shown != null &&
        orexCallInstanceIdsMatch(shown.ringEventId, instance.ringEventId);
  }

  /// Applies a trusted exact identity hint (for example, an Android push
  /// action) to an already-current tokenless call. This is deliberately
  /// one-way: an exact A can never be rewritten to B.
  bool promoteCallInstance(OrexCallInstance instance) {
    final ringEventId = instance.ringEventId;
    if (ringEventId == null) return false;
    return _promoteLegacyCallInstance(instance.roomId, ringEventId);
  }

  String _exactAttemptKey(String roomId, String ringEventId) =>
      '$roomId\u001f$ringEventId';

  void _trimExactAttemptMap(Map<String, DateTime> attempts) {
    while (attempts.length > _maxRememberedExactCallAttempts) {
      attempts.remove(attempts.keys.first);
    }
  }

  bool _suppressCall(String roomId, String? ringEventId) {
    if (ringEventId == null) {
      _exactFallbackSuppressedRooms.remove(roomId);
      return _legacySuppressedRooms.add(roomId);
    }
    // Membership-only scans do not carry the exact ring id. Keep a room-level
    // fallback shield alongside the exact tombstone so the same handled call
    // cannot be presented again as a legacy attempt.
    _legacySuppressedRooms.add(roomId);
    _exactFallbackSuppressedRooms.add(roomId);
    final key = _exactAttemptKey(roomId, ringEventId);
    if (_suppressedExactAttempts.containsKey(key)) return false;
    _suppressedExactAttempts[key] = DateTime.now();
    _trimExactAttemptMap(_suppressedExactAttempts);
    return true;
  }

  bool _hasSuppressedCallInRoom(String roomId) {
    if (_legacySuppressedRooms.contains(roomId)) return true;
    final prefix = '$roomId\u001f';
    return _suppressedExactAttempts.keys.any((key) => key.startsWith(prefix));
  }

  bool _hasExactCallDisposition(String roomId, String ringEventId) =>
      _dispositions.hasExact(roomId, ringEventId);

  bool _hasExactCallSuppression(String roomId, String ringEventId) =>
      _suppressedExactAttempts.containsKey(
        _exactAttemptKey(roomId, ringEventId),
      );

  bool _isCallSuppressed(String roomId, String? ringEventId) {
    if (ringEventId == null) return _legacySuppressedRooms.contains(roomId);
    if (_hasExactCallSuppression(roomId, ringEventId)) return true;
    return _legacySuppressedRooms.contains(roomId);
  }

  void _clearCallSuppression(String roomId) {
    _legacySuppressedRooms.remove(roomId);
    _exactFallbackSuppressedRooms.remove(roomId);
  }

  _ShownIncomingRing? _removeShownAttempt(OrexCallInstance instance) {
    final shown = _shownAttempts[instance.roomId];
    if (shown == null ||
        !orexCallInstanceIdsMatch(shown.ringEventId, instance.ringEventId)) {
      return null;
    }
    return _shownAttempts.remove(instance.roomId);
  }

  void _removeIncomingAttempt(OrexCallInstance instance) {
    if (!_incomingRingEventIds.containsKey(instance.roomId) ||
        !orexCallInstanceIdsMatch(
          _incomingRingEventIds[instance.roomId],
          instance.ringEventId,
        )) {
      return;
    }
    _incomingRingEventIds.remove(instance.roomId);
  }

  bool _promoteLegacyCallInstance(
    String roomId,
    String ringEventId, {
    DateTime? occurredAt,
  }) {
    final exactRingEventId = ringEventId.trim();
    if (exactRingEventId.isEmpty) return false;

    final activeInRoom = active?.room.id == roomId;
    final enterInRoom =
        _enterRequestOwner != null && _enterRequestRoomId == roomId;
    final hasIncoming = _incomingRingEventIds.containsKey(roomId);
    final shown = _shownAttempts[roomId];
    final strongCurrentIds = <String>[
      if (activeInRoom && _activeRingEventId != null) _activeRingEventId!,
      if (enterInRoom && _enterRequestRingEventId != null)
        _enterRequestRingEventId!,
      if (hasIncoming && _incomingRingEventIds[roomId] != null)
        _incomingRingEventIds[roomId]!,
      if (shown?.ringEventId != null) shown!.ringEventId!,
    ];
    if (strongCurrentIds.any((current) => current != exactRingEventId)) {
      return false;
    }

    final promoteActive = activeInRoom && _activeRingEventId == null;
    final promoteEnter = enterInRoom && _enterRequestRingEventId == null;
    final promoteIncoming =
        hasIncoming && _incomingRingEventIds[roomId] == null;
    final promoteShown = shown != null && shown.ringEventId == null;
    final hasRuntimePromotion =
        promoteActive || promoteEnter || promoteIncoming || promoteShown;
    final hasLegacySuppression =
        _legacySuppressedRooms.contains(roomId) &&
        !_exactFallbackSuppressedRooms.contains(roomId);
    final legacyDispositionAt = _dispositions.legacyTimestamp(roomId);
    final hasPersistedLegacyAttempt =
        _persistedLeftAt.containsKey(roomId) &&
        _persistedLeftRingEventIds[roomId] == null;
    final storedAttemptBoundary =
        legacyDispositionAt ?? _persistedLeftAt[roomId];
    final storedAttemptMatches = orexShouldPromoteStoredLegacyCallInstance(
      exactAttemptAt: occurredAt,
      legacyDispositionAt: storedAttemptBoundary,
    );
    final hasStoredLegacyAttempt =
        hasLegacySuppression ||
        legacyDispositionAt != null ||
        hasPersistedLegacyAttempt;
    if (!hasRuntimePromotion &&
        (!hasStoredLegacyAttempt || !storedAttemptMatches)) {
      return false;
    }

    if (promoteActive) _activeRingEventId = exactRingEventId;
    if (promoteEnter) _enterRequestRingEventId = exactRingEventId;
    if (promoteIncoming) {
      _incomingRingEventIds[roomId] = exactRingEventId;
    }
    if (promoteShown) {
      _shownAttempts[roomId] = _ShownIncomingRing(
        exactRingEventId,
        occurredAt ?? shown.occurredAt,
      );
    }
    if (_legacySuppressedRooms.remove(roomId)) {
      _suppressCall(roomId, exactRingEventId);
    }
    if (legacyDispositionAt != null) {
      _dispositions.promoteLegacy(
        roomId,
        exactRingEventId,
        cleanupAfter: _persistedLeftAt.containsKey(roomId)
            ? null
            : const Duration(minutes: 2),
      );
    }
    if (hasPersistedLegacyAttempt) {
      _persistedLeftRingEventIds[roomId] = exactRingEventId;
      unawaited(_persistLeftCalls());
    }

    if (hasRuntimePromotion) {
      final exactKey = _exactAttemptKey(roomId, exactRingEventId);
      if (_emittedPromotionAttempts.add(exactKey)) {
        while (_emittedPromotionAttempts.length >
            _maxRememberedExactCallAttempts) {
          _emittedPromotionAttempts.remove(_emittedPromotionAttempts.first);
        }
        if (!_disposed) {
          _instancePromotions.add(
            OrexCallInstancePromotion(
              previous: OrexCallInstance(roomId: roomId),
              current: OrexCallInstance(
                roomId: roomId,
                ringEventId: exactRingEventId,
              ),
            ),
          );
          notifyListeners();
        }
      }
    }
    OrexLog.d(
      'Voip',
      'promoted legacy call attempt room=$roomId ring=$exactRingEventId',
    );
    return true;
  }

  bool get inCall => active != null;

  Future<void> get shutdownComplete => _shutdownComplete;

  void _releaseKeyProviderLease(_CallKeyShareState state) {
    final lease = state.keyProviderLease;
    state.keyProviderLease = null;
    if (lease == null) return;
    final backend = state.groupCall.backend;
    final barriers = <Future<void>>[];
    if (backend is OrexLiveKitBackend) barriers.add(backend.fullyDrained);
    final mediaDrain = state.mediaOperationsDrained;
    if (mediaDrain != null) barriers.add(mediaDrain);
    e2eeKeyProvider.releaseSession(lease, after: barriers);
  }

  Future<void> _shareLocalMediaKeyWithNewParticipants(
    _CallKeyShareState state,
    List<CallParticipant> remoteParticipants,
  ) async {
    final groupCall = state.groupCall;
    final backend = groupCall.backend;
    if (backend is! OrexLiveKitBackend) {
      throw StateError('Unscoped MatrixRTC LiveKit backend is not allowed');
    }
    final remoteIds = remoteParticipants
        .map((participant) => participant.id)
        .toSet();
    state.sharedParticipantIds.retainAll(remoteIds);
    final keyRevision = backend.localKeyRevision;
    final pendingIds = orexPendingMediaKeyShareTargets(
      remoteParticipantIds: remoteIds,
      sharedParticipantIds: state.sharedParticipantIds,
      sharedLocalKeyRevision: state.sharedLocalKeyRevision,
      currentLocalKeyRevision: keyRevision,
    );
    if (pendingIds.isEmpty) {
      if (state.sharedLocalKeyRevision != keyRevision) {
        state.sharedParticipantIds.clear();
        state.sharedLocalKeyRevision = keyRevision;
      }
      return;
    }
    final pendingParticipants = remoteParticipants
        .where((participant) => pendingIds.contains(participant.id))
        .toList(growable: false);

    await backend.shareCurrentKeyWith(groupCall, pendingParticipants);
    if (state.active &&
        identical(_keyShareState, state) &&
        backend.localKeyRevision == keyRevision) {
      if (state.sharedLocalKeyRevision != keyRevision) {
        state.sharedParticipantIds.clear();
        state.sharedLocalKeyRevision = keyRevision;
      }
      state.sharedParticipantIds.addAll(pendingIds);
    }
  }

  /// Resynchronise MatrixRTC media keys for participants that joined before
  /// the current LiveKit room became ready. MatrixRTC deliberately keeps key
  /// exchange on the Matrix to-device plane, so late subscribers must request
  /// keys explicitly instead of restarting local audio/video publications.
  Future<void> ensureActiveCallEncryptionKeys({
    required int expectedRemoteParticipants,
    Set<String> forceRemoteParticipantIds = const <String>{},
    Duration timeout = const Duration(seconds: 3),
    int maxAttempts = 4,
  }) async {
    final groupCall = active;
    if (groupCall == null) return;
    final state = _keyShareState;
    if (state == null || !identical(state.groupCall, groupCall)) return;

    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      var completed = false;
      try {
        await state.run(() async {
          await groupCall.onMemberStateChanged();
          if (!state.active ||
              !identical(_keyShareState, state) ||
              !identical(active, groupCall)) {
            return;
          }

          final participants = groupCall.participants.toList(growable: false);
          final localParticipants = participants
              .where((participant) => participant.isLocal)
              .toList(growable: false);
          final remoteParticipants = participants
              .where((participant) => !participant.isLocal)
              .toList(growable: false);
          await _shareLocalMediaKeyWithNewParticipants(
            state,
            remoteParticipants,
          );
          if (!state.active || !identical(_keyShareState, state)) return;

          final knownRemoteMemberships = _callMembers(
            groupCall.room,
          ).where((userId) => userId != client.userID).length;
          final minimumRemoteParticipants =
              knownRemoteMemberships > expectedRemoteParticipants
              ? knownRemoteMemberships
              : expectedRemoteParticipants;
          if (localParticipants.isEmpty) {
            throw StateError(
              'MatrixRTC local participant is not ready for media encryption',
            );
          }
          if (remoteParticipants.length < minimumRemoteParticipants) {
            throw StateError(
              'MatrixRTC membership lag: expected $minimumRemoteParticipants '
              'remote participant(s), saw ${remoteParticipants.length}',
            );
          }

          final activeRemoteIds = remoteParticipants
              .map((participant) => participant.id)
              .toSet();
          final forcedIds = forceRemoteParticipantIds.intersection(
            activeRemoteIds,
          );
          final missingLocal = localParticipants
              .where((participant) => !e2eeKeyProvider.hasKeyFor(participant))
              .toList(growable: false);
          final missingRemote = remoteParticipants
              .where((participant) => !e2eeKeyProvider.hasKeyFor(participant))
              .toList(growable: false);
          final forcedRemote = remoteParticipants
              .where((participant) => forcedIds.contains(participant.id))
              .toList(growable: false);
          final forcedRevisions = <String, int>{
            for (final participant in forcedRemote)
              participant.id: e2eeKeyProvider.keyRevisionFor(participant.id),
          };
          final missing = <CallParticipant>[...missingLocal, ...missingRemote];
          if (missing.isEmpty && forcedRemote.isEmpty) {
            completed = true;
            return;
          }

          final requestParticipants = <CallParticipant>{
            ...missingRemote,
            ...forcedRemote,
          }.toList(growable: false);
          if (requestParticipants.isNotEmpty) {
            await groupCall.backend.requestEncrytionKey(
              groupCall,
              requestParticipants,
            );
          }
          final readiness = await Future.wait<bool>([
            e2eeKeyProvider.waitForKeys(missing, timeout: timeout),
            e2eeKeyProvider.waitForKeyUpdates(
              forcedRevisions,
              timeout: timeout,
            ),
          ]);
          if (readiness.every((ready) => ready)) {
            completed = true;
            return;
          }
          throw StateError(
            'Timed out waiting for ${missingLocal.length} local and '
            '${missingRemote.length} remote MatrixRTC media key(s); '
            '${forcedRemote.length} forced refresh(es)',
          );
        });
        if (!state.active || !identical(_keyShareState, state)) return;
        if (completed) return;
      } catch (error) {
        lastError = error;
      }

      if (attempt + 1 < maxAttempts) {
        await Future<void>.delayed(Duration(milliseconds: 350 * (attempt + 1)));
      }
    }

    OrexLog.d(
      'Voip',
      'MatrixRTC media key refresh failed room=${groupCall.room.id}',
      lastError,
    );
    throw StateError('Не удалось получить ключи защищённого медиапотока');
  }

  bool _roomHasCall(Room room) {
    if (room.hasActiveGroupCall(voip, ignoreDirectChats: false)) return true;
    // На некоторых sync-пакетах SDK уже видит свежий call membership, но
    // `hasActiveGroupCall()` ещё возвращает false. Для входящих нам важнее
    // фактические неистёкшие участники звонка, иначе окно может закрыться сразу
    // после старта рингтона.
    return _callMembers(room).isNotEmpty;
  }

  Iterable<String> _callMembers(Room room) sync* {
    final seen = <String>{};
    for (final id
        in room
            .getCallMembershipsFromRoom(voip)
            .values
            .expand((e) => e)
            .where((m) => !m.isExpired)
            .map((m) => m.userId)) {
      if (seen.add(id)) yield id;
    }

    // Fallback for cold-start / not-yet-opened rooms: on Android the room tile
    // can already receive an EventTypes.GroupCallMember timeline/state update
    // (preview becomes "Звонок"), while matrix SDK call-membership helpers still
    // return an empty list until a timeline is opened. Treat a fresh remote
    // GroupCallMember lastEvent as an incoming direct-call signal so the phone
    // rings without forcing the user to open the chat first.
    final fallbackCaller = _fallbackCallerFromLastEvent(room);
    if (fallbackCaller != null && seen.add(fallbackCaller)) {
      yield fallbackCaller;
    }
  }

  String? _fallbackCallerFromLastEvent(Room room) {
    final event = room.lastEvent;
    if (event == null || event.type != EventTypes.GroupCallMember) return null;
    final terminatedAt = _dispositions.legacyTimestamp(room.id);
    if (terminatedAt != null && !event.originServerTs.isAfter(terminatedAt)) {
      return null;
    }
    if (event.redacted || event.senderId == client.userID) return null;
    if (!_groupCallMemberEventLooksActive(event)) return null;
    return event.senderId;
  }

  static const Duration _timelineCallFallbackTtl = Duration(seconds: 60);

  bool _groupCallMemberEventLooksActive(Event event) {
    final now = DateTime.now();
    if (now.difference(event.originServerTs) > _timelineCallFallbackTtl) {
      return false;
    }

    final memberships = event.content['memberships'];
    if (memberships is! List) return true;
    if (memberships.isEmpty) return false;

    var sawMembership = false;
    for (final raw in memberships) {
      if (raw is! Map) continue;
      sawMembership = true;
      if (_membershipContentLooksActive(raw, event.originServerTs, now)) {
        return true;
      }
    }
    return !sawMembership;
  }

  bool _membershipContentLooksActive(Map raw, DateTime eventTs, DateTime now) {
    final expiresTs = _readInt(raw['expires_ts'] ?? raw['expiresTs']);
    if (expiresTs != null) {
      final absolute = DateTime.fromMillisecondsSinceEpoch(expiresTs);
      return absolute.isAfter(now);
    }

    final expires = _readInt(raw['expires']);
    if (expires == null) return true;
    if (expires <= 0) return false;

    final duration = expires < 24 * 60 * 60
        ? Duration(seconds: expires)
        : Duration(milliseconds: expires);
    return eventTs.add(duration).isAfter(now);
  }

  int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// Сканируем все комнаты на активные звонки.
  void _scan({bool markExistingAsSeen = false}) {
    for (final room in client.rooms) {
      final freshExplicitRing = _consumeFreshIncomingRing(room);
      final hasFreshExplicitRing = freshExplicitRing != null;
      if (!_roomHasCall(room)) {
        if (hasFreshExplicitRing) {
          _cancelRoomCallEnded(room.id);
          _considerIncomingRoom(
            room,
            markExistingAsSeen: false,
            freshExplicitRingAt: freshExplicitRing.occurredAt,
            freshExplicitRingEventId: freshExplicitRing.ringEventId,
          );
        } else {
          _scheduleRoomCallEnded(room.id);
        }
        continue;
      }
      _cancelRoomCallEnded(room.id);
      final existedAtStartup =
          markExistingAsSeen && _startupExistingCallRoomIds.remove(room.id);
      _considerIncomingRoom(
        room,
        markExistingAsSeen: orexShouldMarkStartupCallAsSeen(
          existedAtStartup: existedAtStartup,
          hasFreshExplicitRing: hasFreshExplicitRing,
        ),
        freshExplicitRingAt: freshExplicitRing?.occurredAt,
        freshExplicitRingEventId: freshExplicitRing?.ringEventId,
      );
    }
  }

  void _seedStartupIncomingState() {
    for (final room in client.rooms) {
      if (_roomHasCall(room)) _startupExistingCallRoomIds.add(room.id);
      final event = _freshIncomingRingEvent(room);
      if (event != null) _rememberIncomingRingEventId(event.eventId);
    }
  }

  void _handleTimelineEvent(Event event) {
    if (_disposed || event.senderId == client.userID) return;
    final notificationType = event
        .tryParseRtcNotificationContent()
        ?.notificationType;
    if (notificationType == null) return;
    final age = DateTime.now().difference(event.originServerTs);
    if (age > _timelineCallFallbackTtl) return;

    if (notificationType == RtcNotificationType.notification) {
      final action = orexParseWakeCancellationAction(
        event.content['orex_call_action'],
      );
      final dispositionType = switch (action) {
        OrexWakeCancellationAction.handled => _handledEventType,
        OrexWakeCancellationAction.ended => _endedEventType,
        null => null,
      };
      final ringEventId = _ringEventIdFromContent(event.content);
      if (dispositionType == null || ringEventId == null) return;
      _applyWakeCancellation(
        _DeferredRemoteDisposition(
          type: dispositionType,
          roomId: event.room.id,
          sender: event.senderId,
          ringEventId: ringEventId,
          occurredAt: event.originServerTs,
        ),
      );
      return;
    }
    if (notificationType != RtcNotificationType.ring) return;
    if (!orexShouldPresentExplicitRing(
      roomHasActiveCall: _roomHasCall(event.room),
      eventAge: age,
    )) {
      final staleEventId = event.eventId.trim();
      if (staleEventId.isNotEmpty) {
        _recordCallDisposition(
          event.room.id,
          occurredAt: event.originServerTs,
          ringEventId: staleEventId,
        );
        _suppressCall(event.room.id, staleEventId);
      }
      OrexLog.d(
        'Voip',
        'ignored delayed ring without active membership '
            'room=${event.room.id} age=${age.inSeconds}s',
      );
      return;
    }

    final eventId = event.eventId.trim();
    if (eventId.isEmpty || !_rememberIncomingRingEventId(eventId)) return;

    if (!_suppressionRestored) {
      _pendingFreshRingRooms[event.room.id] = _PendingIncomingRing(
        event.room,
        event.originServerTs,
        eventId,
      );
      return;
    }
    _presentFreshIncomingRing(event.room, event.originServerTs, eventId);
  }

  void _presentFreshIncomingRing(
    Room room,
    DateTime occurredAt,
    String ringEventId,
  ) {
    _cancelRoomCallEnded(room.id);
    _considerIncomingRoom(
      room,
      markExistingAsSeen: false,
      freshExplicitRingAt: occurredAt,
      freshExplicitRingEventId: ringEventId,
    );
  }

  _FreshIncomingRing? _consumeFreshIncomingRing(Room room) {
    final event = _freshIncomingRingEvent(room);
    if (event == null || !_rememberIncomingRingEventId(event.eventId)) {
      return null;
    }
    return _FreshIncomingRing(event.originServerTs, event.eventId);
  }

  bool _rememberIncomingRingEventId(String eventId) {
    if (!_seenIncomingRingEventIds.add(eventId)) return false;
    while (_seenIncomingRingEventIds.length >
        _maxRememberedIncomingRingEvents) {
      _seenIncomingRingEventIds.remove(_seenIncomingRingEventIds.first);
    }
    return true;
  }

  Event? _freshIncomingRingEvent(Room room) {
    final event = room.lastEvent;
    if (event == null || event.senderId == client.userID) return null;
    if (event.tryParseRtcNotificationContent()?.notificationType !=
        RtcNotificationType.ring) {
      return null;
    }
    final age = DateTime.now().difference(event.originServerTs);
    if (age > _timelineCallFallbackTtl ||
        !orexShouldPresentExplicitRing(
          roomHasActiveCall: _roomHasCall(room),
          eventAge: age,
        )) {
      return null;
    }
    final eventId = event.eventId.trim();
    return eventId.isEmpty ? null : event;
  }

  bool _explicitlyNonPersonalRoom(Room room) {
    if (room.isSpace) return true;
    final kind = room
        .getState('ru.orex.room.kind')
        ?.content['kind']
        ?.toString()
        .trim();
    return kind == 'channel' || kind == 'supergroup';
  }

  /// Личный ли это звонок с точки зрения продуктовой логики Orex.
  /// Используется и входящим рингтоном, и Android Telecom, чтобы групповые
  /// голосовые каналы никогда не превращались в системный телефонный вызов.
  bool isPersonalCallRoom(Room room) => _shouldRingForRoom(room);

  bool _shouldRingForRoom(Room room) {
    if (room.isDirectChat) return true;
    if (_explicitlyNonPersonalRoom(room)) return false;

    // На некоторых аккаунтах Matrix DM-флаг может ещё не приехать, пока чат
    // ни разу не открывали на устройстве. Для входящего звонка считаем такую
    // комнату личной, если в ней всего два joined-участника.
    final joined = room
        .getParticipants([Membership.join])
        .map((u) => u.id)
        .where((id) => id.isNotEmpty)
        .toSet();
    if (joined.length == 2 && joined.contains(client.userID)) return true;

    // Если member-list неполный, но активный звонок пришёл ровно от одного
    // удалённого участника и комната явно не канал/супергруппа — тоже звоним.
    final remoteCallMembers = _callMembers(
      room,
    ).where((id) => id != client.userID).toSet();
    return joined.length <= 2 && remoteCallMembers.length == 1;
  }

  void _considerIncomingRoom(
    Room room, {
    required bool markExistingAsSeen,
    DateTime? freshExplicitRingAt,
    String? freshExplicitRingEventId,
  }) {
    final hasFreshExplicitRing = freshExplicitRingAt != null;
    final ringEventId = freshExplicitRingEventId;
    final myId = client.userID;
    if (ringEventId != null &&
        (_hasExactCallDisposition(room.id, ringEventId) ||
            _hasExactCallSuppression(room.id, ringEventId))) {
      return;
    }
    if (ringEventId != null &&
        _promoteLegacyCallInstance(
          room.id,
          ringEventId,
          occurredAt: freshExplicitRingAt,
        )) {
      return;
    }
    final retainedIncomingRingEventId = _incomingRingEventIds[room.id];
    if (ringEventId == null &&
        retainedIncomingRingEventId != null &&
        (_hasExactCallDisposition(room.id, retainedIncomingRingEventId) ||
            _hasExactCallSuppression(room.id, retainedIncomingRingEventId))) {
      return;
    }
    if (_enterRequestOwner != null && _enterRequestRoomId == room.id) {
      if (orexIsDifferentExactCallAttempt(
            previousRingEventId: _enterRequestRingEventId,
            nextRingEventId: ringEventId,
          ) &&
          _suppressCall(room.id, ringEventId)) {
        _recordCallDisposition(room.id, ringEventId: ringEventId);
        unawaited(
          notifyBusy(
            OrexCallInstance(roomId: room.id, ringEventId: ringEventId),
          ),
        );
      }
      return;
    }
    final currentCall = active;
    if (currentCall != null) {
      if (currentCall.room.id == room.id) {
        if (orexIsDifferentExactCallAttempt(
              previousRingEventId: _activeRingEventId,
              nextRingEventId: ringEventId,
            ) &&
            _suppressCall(room.id, ringEventId)) {
          _recordCallDisposition(room.id, ringEventId: ringEventId);
          unawaited(
            notifyBusy(
              OrexCallInstance(roomId: room.id, ringEventId: ringEventId),
            ),
          );
        }
        return;
      }
      // Orex supports one personal media session at a time. Never stack a
      // second incoming UI on top of an active call; answer the second attempt
      // once with an explicit busy disposition instead.
      if (_shouldRingForRoom(room) && _suppressCall(room.id, ringEventId)) {
        OrexLog.d(
          'Voip',
          'incoming call rejected as busy while another call is active room=${room.id}',
        );
        _recordCallDisposition(room.id, ringEventId: ringEventId);
        unawaited(
          notifyBusy(
            OrexCallInstance(roomId: room.id, ringEventId: ringEventId),
          ),
        );
      }
      return;
    }
    final shown = _shownAttempts[room.id];
    if (shown != null) {
      if (!orexShouldSupersedeShownIncomingCall(
        shownRingEventId: shown.ringEventId,
        shownAt: shown.occurredAt,
        candidateRingEventId: ringEventId,
        candidateAt: freshExplicitRingAt,
      )) {
        return;
      }
      final previous = OrexCallInstance(
        roomId: room.id,
        ringEventId: shown.ringEventId,
      );
      _shownAttempts[room.id] = _ShownIncomingRing(
        ringEventId,
        freshExplicitRingAt,
      );
      _incomingRingEventIds[room.id] = ringEventId;
      _dismiss.add(
        OrexIncomingCallDismissal(
          roomId: previous.roomId,
          ringEventId: previous.ringEventId,
        ),
      );
      _incoming.add(OrexIncomingCall(room: room, ringEventId: ringEventId));
      return;
    }
    if (_isCallSuppressed(room.id, ringEventId)) {
      if (ringEventId != null &&
          (_hasExactCallDisposition(room.id, ringEventId) ||
              _hasExactCallSuppression(room.id, ringEventId))) {
        return;
      }
      final resumed = _resumeAfterNewRemoteCall(
        room,
        freshExplicitRingAt: freshExplicitRingAt,
        freshExplicitRingEventId: ringEventId,
      );
      if (!resumed) {
        final mayBypassStartupSuppress =
            hasFreshExplicitRing &&
            !_persistedLeftAt.containsKey(room.id) &&
            !_dispositions.hasLegacy(room.id);
        if (!mayBypassStartupSuppress) return;
        _clearCallSuppression(room.id);
      }
    }
    final others = _callMembers(room).where((id) => id != myId).toSet();
    if (others.isEmpty && !hasFreshExplicitRing) {
      return; // только моё членство — не входящий
    }
    if (!_shouldRingForRoom(room)) {
      // В группах, каналах и чатах супергруппы звонок — это голосовой канал:
      // не показываем системный входящий вызов всем участникам. Комната всё
      // равно помечается активной, поэтому UI покажет «Идёт звонок · Войти».
      _suppressCall(room.id, ringEventId);
      return;
    }
    if (markExistingAsSeen && !hasFreshExplicitRing) {
      _suppressCall(
        room.id,
        ringEventId,
      ); // активен на старте → не звоним (покажет панель «войти»)
      return;
    }
    OrexLog.d(
      'Voip',
      'incoming direct call room=${room.id} '
          'from=${others.isEmpty ? 'explicit-ring' : others.join(',')}',
    );
    _shownAttempts[room.id] = _ShownIncomingRing(
      ringEventId,
      freshExplicitRingAt,
    );
    _incomingRingEventIds[room.id] = ringEventId;
    _incoming.add(OrexIncomingCall(room: room, ringEventId: ringEventId));
  }

  bool _resumeAfterNewRemoteCall(
    Room room, {
    DateTime? freshExplicitRingAt,
    String? freshExplicitRingEventId,
  }) {
    if (freshExplicitRingEventId != null) {
      if (_hasExactCallDisposition(room.id, freshExplicitRingEventId) ||
          _hasExactCallSuppression(room.id, freshExplicitRingEventId)) {
        return false;
      }
      _dispositions.clearLegacy(room.id);
      _clearCallSuppression(room.id);
      _clearPersistedLeftCall(room.id);
      return true;
    }

    final terminatedAt =
        _dispositions.legacyTimestamp(room.id) ?? _persistedLeftAt[room.id];
    if (terminatedAt == null) return false;

    final hasFreshRing = orexIsFreshRingAfterLeave(
      ringAt: freshExplicitRingAt,
      leftAt: terminatedAt,
    );
    final persistedMemberships = _persistedLeftMemberships[room.id];
    if (persistedMemberships != null) {
      final currentMemberships = _remoteCallMembershipSignatures(room);
      final isNewCall = orexIsNewCallInstanceAfterPersistedLeave(
        previousMemberships: persistedMemberships,
        currentMemberships: currentMemberships,
        hasFreshRing: hasFreshRing,
      );
      if (!isNewCall) return false;
    } else if (!hasFreshRing) {
      // Legacy disposition state has no exact membership baseline. Do not infer
      // a new call from a periodic MatrixRTC membership refresh; only a fresh
      // explicit ring may clear it.
      return false;
    }

    _dispositions.clearLegacy(room.id);
    _clearCallSuppression(room.id);
    _clearPersistedLeftCall(room.id);
    return true;
  }

  void _cancelRoomCallEnded(String roomId) {
    _endedDebounceTimers.remove(roomId)?.cancel();
  }

  void _scheduleRoomCallEnded(String roomId) {
    if (!_shownAttempts.containsKey(roomId) &&
        !_hasSuppressedCallInRoom(roomId)) {
      return;
    }
    if (_endedDebounceTimers.containsKey(roomId)) return;
    _endedDebounceTimers[roomId] = Timer(_endedDebounceDelay, () {
      _endedDebounceTimers.remove(roomId);
      final room = client.getRoomById(roomId);
      if (room != null && _roomHasCall(room)) return;
      _finishRoomCallEnded(roomId);
    });
  }

  void _finishRoomCallEnded(String roomId) {
    final shown = _shownAttempts[roomId];
    final removed = shown == null
        ? null
        : _removeShownAttempt(
            OrexCallInstance(roomId: roomId, ringEventId: shown.ringEventId),
          );
    if (removed != null) {
      _dismiss.add(
        OrexIncomingCallDismissal(
          roomId: roomId,
          ringEventId: removed.ringEventId,
        ),
      );
    }
    if (_incomingRingEventIds.containsKey(roomId)) {
      _removeIncomingAttempt(
        OrexCallInstance(
          roomId: roomId,
          ringEventId: _incomingRingEventIds[roomId],
        ),
      );
    }
    // Persisted leave-state suppresses one continuing MatrixRTC call instance.
    // A transient empty membership frame after our own leave must not erase the
    // tombstone. A new membership fingerprint or a genuinely fresh explicit
    // ring clears it in _resumeAfterNewRemoteCall().
    if (_persistedLeftAt.containsKey(roomId)) return;
    _clearCallSuppression(roomId);
    _dispositions.clearLegacy(roomId);
  }

  void _handleIncomingGroupCall(GroupCallSession groupCall) {
    final room = groupCall.room;
    if (!_roomHasCall(room)) return;
    _cancelRoomCallEnded(room.id);
    _considerIncomingRoom(room, markExistingAsSeen: false);
  }

  void _handleGroupCallEnded(GroupCallSession groupCall) {
    _scheduleRoomCallEnded(groupCall.room.id);
  }

  /// Я вышел из звонка — не «перезванивать» по тому же продолжающемуся звонку.
  Future<void> markLeft(OrexCallInstance instance) async {
    final roomId = instance.roomId;
    _cancelRoomCallEnded(roomId);
    final leftAt = DateTime.now();
    final room = client.getRoomById(roomId);
    _persistedLeftAt[roomId] = leftAt;
    _persistedLeftMemberships[roomId] = room == null
        ? <String>{}
        : _remoteCallMembershipSignatures(room);
    _persistedLeftRingEventIds[roomId] = instance.ringEventId;
    _recordCallDisposition(
      roomId,
      occurredAt: leftAt,
      ringEventId: instance.ringEventId,
      cleanupAfter: null,
    );
    _suppressCall(roomId, instance.ringEventId);
    final removed = _removeShownAttempt(instance);
    if (removed != null) {
      _dismiss.add(
        OrexIncomingCallDismissal(
          roomId: roomId,
          ringEventId: removed.ringEventId,
        ),
      );
    }
    await _persistLeftCalls();
  }

  /// Закрыть локальный экран входящего при действии из Android system UI.
  /// Обычный accept/decline из Flutter не использует этот метод, потому что его
  /// экран сам управляет навигацией после завершения асинхронного действия.
  void dismissIncomingFromSystem(OrexCallInstance instance) {
    promoteCallInstance(instance);
    if (!isCurrentCallInstance(instance)) return;
    final roomId = instance.roomId;
    _suppressCall(roomId, instance.ringEventId);
    final removed = _removeShownAttempt(instance);
    if (removed != null) {
      _dismiss.add(
        OrexIncomingCallDismissal(
          roomId: roomId,
          ringEventId: removed.ringEventId,
          cancelsPendingAccept: false,
        ),
      );
    }
  }

  /// Пометить обработанным (принят/отклонён) и сообщить другим своим устройствам.
  Future<void> markCallHandled(OrexCallInstance instance) async {
    final roomId = instance.roomId;
    promoteCallInstance(instance);
    if (isCurrentCallInstance(instance)) {
      _suppressCall(roomId, instance.ringEventId);
      _removeShownAttempt(instance);
      _recordCallDisposition(
        roomId,
        ringEventId: instance.ringEventId,
        cleanupAfter: null,
      );
    }
    await _signaling.sendHandled(instance);
  }

  /// Войти в звонок комнаты: публикуем своё членство (сигналинг) и возвращаем
  /// сессию. Медиа подключается отдельно (CallSession через livekit_client).
  ///
  /// Для нового личного звонка [ring] дополнительно отправляет targeted
  /// MSC4075 RTC notification после успешной публикации membership. Это
  /// отдельный Matrix event, который push rules могут доставить устройствам
  /// собеседника даже когда его обычный `/sync` не запущен.
  Future<GroupCallSession> enterCall(
    String roomId, {
    required Object owner,
    bool ring = false,
    bool video = false,
    String? expectedRingEventId,
  }) async {
    if (!ring && expectedRingEventId != null) {
      promoteCallInstance(
        OrexCallInstance(roomId: roomId, ringEventId: expectedRingEventId),
      );
    }
    final enterGeneration = ++_enterGeneration;
    _enterRequestOwner = owner;
    _enterRequestRoomId = roomId;
    _enterRequestRingEventId = expectedRingEventId;
    while (_enterCompletion != null) {
      final previousEnter = _enterCompletion!;
      try {
        await previousEnter.future.timeout(const Duration(seconds: 12));
      } on TimeoutException {
        // A transport/plugin Future may never settle after connectivity loss.
        // The generation/owner checks make its eventual continuation stale, so
        // release only the serialization slot and allow a fresh call attempt.
        if (identical(_enterCompletion, previousEnter)) {
          _enterCompletion = null;
        }
        if (!previousEnter.isCompleted) previousEnter.complete();
        OrexLog.d(
          'Voip',
          'detached stuck previous MatrixRTC enter before room=$roomId',
        );
      }
      if (enterGeneration != _enterGeneration ||
          !identical(_enterRequestOwner, owner)) {
        if (identical(_enterRequestOwner, owner)) _enterRequestOwner = null;
        throw StateError('MatrixRTC call enter was cancelled');
      }
    }
    if (enterGeneration != _enterGeneration ||
        !identical(_enterRequestOwner, owner)) {
      if (identical(_enterRequestOwner, owner)) _enterRequestOwner = null;
      throw StateError('MatrixRTC call enter was cancelled');
    }
    final enterCompletion = Completer<void>();
    _enterCompletion = enterCompletion;
    try {
      return await _enterCallSerialized(
        roomId,
        owner: owner,
        ring: ring,
        video: video,
        expectedRingEventId: expectedRingEventId,
        enterGeneration: enterGeneration,
      );
    } finally {
      if (!enterCompletion.isCompleted) enterCompletion.complete();
      if (identical(_enterCompletion, enterCompletion)) {
        _enterCompletion = null;
      }
      if (identical(_enterRequestOwner, owner)) {
        _enterRequestOwner = null;
        _enterRequestRoomId = null;
        _enterRequestRingEventId = null;
      }
    }
  }

  Future<GroupCallSession> _enterCallSerialized(
    String roomId, {
    required Object owner,
    required bool ring,
    required bool video,
    required String? expectedRingEventId,
    required int enterGeneration,
  }) async {
    final room = client.getRoomById(roomId);
    if (room == null) {
      throw StateError('Комната $roomId не найдена');
    }
    if (!orexCanEnterCallRoom(
      roomEncrypted: room.encrypted,
      allowUnencryptedCalls: OrexConfig.allowUnencryptedCalls,
    )) {
      throw StateError(
        'Звонок заблокирован: Matrix-комната не защищена сквозным шифрованием',
      );
    }

    final incomingRingEventId = ring ? null : expectedRingEventId;
    if (!ring &&
        _incomingRingEventIds.containsKey(roomId) &&
        !orexCallInstanceIdsMatch(
          _incomingRingEventIds[roomId],
          expectedRingEventId,
        )) {
      throw StateError('Incoming call attempt changed before MatrixRTC enter');
    }

    // Tear down any process-local SDK owner left by an interrupted attempt
    // before rotating keys and creating the replacement membership.
    await _cleanupStaleRoomState(room, operationName: 'pre-enter');
    if (enterGeneration != _enterGeneration) {
      throw StateError('MatrixRTC call enter was cancelled');
    }

    // Explicitly entering a room supersedes an old local-leave tombstone.
    // If the user leaves again, markLeft() records the current remote
    // membership fingerprint as the baseline for the continuing call.
    _clearPersistedLeftCall(roomId);
    _dispositions.clearLegacy(roomId);
    _clearCallSuppression(roomId);

    // Matrix's membershipID is the call-instance cachebuster. Rotate it for
    // every local join so delayed to-device keys from an older call in the same
    // room cannot authenticate as keys for this one.
    voip.currentSessionId = client.generateUniqueTransactionId();
    final backend = OrexLiveKitBackend(
      livekitServiceUrl: OrexConfig.jwtServiceUri.toString(),
      livekitAlias: roomId,
      membershipEpoch: voip.currentSessionId,
      // MatrixRTC distributes the same per-participant keys consumed by the
      // LiveKit BaseKeyProvider in CallSession.
      e2eeEnabled: true,
    );

    var gc = await voip.fetchOrCreateGroupCall(
      roomId,
      room,
      backend,
      'm.call',
      'm.room',
      preShareKey: false,
    );

    // Sessions discovered from room state are created by Matrix's JSON factory
    // with the base LiveKitBackend. Replace only an unentered session so every
    // E2EE callback is routed through the cancellable Orex backend.
    if (!identical(gc.backend, backend)) {
      if (gc.state != GroupCallState.localCallFeedUninitialized &&
          gc.state != GroupCallState.localCallFeedInitialized) {
        throw StateError(
          'Cannot replace an already-entered MatrixRTC backend for $roomId',
        );
      }
      gc = GroupCallSession(
        client: client,
        voip: voip,
        room: room,
        backend: backend,
        groupCallId: gc.groupCallId,
        application: gc.application,
        scope: gc.scope,
      );
      voip.setGroupCallById(gc);
    }

    if (enterGeneration != _enterGeneration) {
      await backend.dispose(gc);
      voip.groupCalls.removeWhere((_, value) => identical(value, gc));
      throw StateError('MatrixRTC call enter was cancelled');
    }

    final keyState = _CallKeyShareState(gc, owner);
    _keyShareState?.invalidate();
    _keyShareState = keyState;

    try {
      keyState.keyProviderLease = e2eeKeyProvider.activatePreparedSession();
      await backend.prepareLocalKey(gc);
      if (enterGeneration != _enterGeneration || !keyState.active) {
        throw StateError('MatrixRTC call enter was cancelled');
      }
      await OrexMatrixRequestGate.shared.run<void>(
        operationName: 'matrixrtc-enter',
        coalesceKey: 'matrixrtc-enter:$roomId:${voip.currentSessionId}',
        maxAttempts: 2,
        operation: gc.enter,
      );
      if (enterGeneration != _enterGeneration || !keyState.active) {
        throw StateError('MatrixRTC call enter was cancelled');
      }
    } catch (e) {
      keyState.invalidate();
      if (identical(_keyShareState, keyState)) _keyShareState = null;
      OrexLog.d(
        'Voip',
        'enter call failed room=$roomId call=${gc.groupCallId}',
        e,
      );
      try {
        await OrexMatrixRequestGate.shared.run<void>(
          operationName: 'matrixrtc-rollback-leave',
          coalesceKey: 'matrixrtc-leave:$roomId:${gc.groupCallId}',
          operation: gc.leave,
        );
      } catch (leaveError) {
        OrexLog.d(
          'Voip',
          'rollback leave failed room=$roomId call=${gc.groupCallId}',
          leaveError,
        );
      }
      // GroupCallSession.leave() can fail before it reaches backend.dispose().
      // Always invalidate delayed key callbacks before releasing the native
      // provider lease; OrexLiveKitBackend.dispose() is idempotent.
      try {
        await backend.dispose(gc);
      } catch (disposeError) {
        OrexLog.d(
          'Voip',
          'rollback backend cleanup failed room=$roomId call=${gc.groupCallId}',
          disposeError,
        );
      }
      try {
        await OrexMatrixRequestGate.shared.run<void>(
          operationName: 'matrixrtc-rollback-membership-cleanup',
          coalesceKey: 'membership-cleanup:$roomId:${gc.groupCallId}',
          operation: () =>
              room.removeFamedlyCallMemberEvent(gc.groupCallId, voip),
        );
        _pendingMembershipCleanupRooms.remove(roomId);
      } catch (removeError) {
        _pendingMembershipCleanupRooms.add(roomId);
        OrexLog.d(
          'Voip',
          'rollback membership cleanup failed room=$roomId call=${gc.groupCallId}',
          removeError,
        );
        _scheduleStaleMembershipCleanup();
      }
      voip.groupCalls.removeWhere((_, value) => identical(value, gc));
      _releaseKeyProviderLease(keyState);
      rethrow;
    }
    final resolvedIncomingRingEventId = ring
        ? null
        : identical(_enterRequestOwner, owner) && _enterRequestRoomId == roomId
        ? _enterRequestRingEventId
        : incomingRingEventId;
    active = gc;
    _activeOwner = owner;
    _activeRingEventId = resolvedIncomingRingEventId;
    if (!ring) {
      _removeIncomingAttempt(
        OrexCallInstance(
          roomId: roomId,
          ringEventId: resolvedIncomingRingEventId,
        ),
      );
    }
    notifyListeners();
    try {
      await keyState.run(() async {
        await gc.onMemberStateChanged();
        if (!keyState.active || !identical(active, gc)) return;
        final remoteParticipants = gc.participants
            .where((participant) => !participant.isLocal)
            .toList(growable: false);
        await _shareLocalMediaKeyWithNewParticipants(
          keyState,
          remoteParticipants,
        );
      });
    } catch (error) {
      // Device membership and Olm DeviceKeys may arrive one sync apart. Media
      // stays fail-closed and CallSession's bounded reconciliation retries.
      OrexLog.d('Voip', 'initial media-key share deferred room=$roomId', error);
    }
    if (enterGeneration != _enterGeneration ||
        !keyState.active ||
        !identical(active, gc)) {
      throw StateError('MatrixRTC call enter was cancelled');
    }
    if (ring) {
      _outgoingRingPendingRooms.add(room.id);
      var ringCompleted = false;
      try {
        final ringEventId = await _sendPersonalCallRing(room, video: video);
        final stillCurrent =
            enterGeneration == _enterGeneration &&
            keyState.active &&
            identical(active, gc);
        if (ringEventId != null && stillCurrent) {
          _promoteLegacyCallInstance(
            room.id,
            ringEventId,
            occurredAt: DateTime.now(),
          );
          if (orexCallInstanceIdsMatch(_activeRingEventId, ringEventId)) {
            _ringEventIds[room.id] = _OutgoingRing(ringEventId);
          }
        } else if (ringEventId != null) {
          // The remote push may already be in flight. Publish both the exact
          // ring-event cancellation and the encrypted ended signal so a local
          // hang-up during sendMessage cannot create a phantom call.
          await Future.wait<void>([
            _signaling.sendDisposition(
              OrexCallInstance(roomId: room.id, ringEventId: ringEventId),
              _endedEventType,
            ),
            _signaling.sendCancellation(
              room,
              ringEventId: ringEventId,
              action: 'ended',
            ).then<void>((_) {}),
          ]);
        }
        ringCompleted = stillCurrent;
        if (!stillCurrent) {
          throw StateError('MatrixRTC call enter was cancelled');
        }
      } finally {
        _outgoingRingPendingRooms.remove(room.id);
        if (ringCompleted) {
          _drainDeferredRemoteDispositions(room.id);
        } else {
          _deferredRemoteDispositions.remove(room.id);
        }
      }
    }
    return gc;
  }

  Future<String?> _sendPersonalCallRing(
    Room room, {
    required bool video,
  }) async {
    if (!isPersonalCallRoom(room)) return null;
    final eventId = await _signaling.sendRing(room, video: video);
    if (eventId != null) {
      OrexLog.d('Voip', 'Wakeable RTC ring sent room=${room.id}');
    }
    return eventId;
  }

  /// Выйти из текущего звонка: убираем своё членство из state комнаты.
  Future<void> leaveCurrent({
    required Object owner,
    Future<lk.BaseKeyProvider>? preparedKeyProvider,
    Future<void>? mediaOperationsDrained,
  }) async {
    if (preparedKeyProvider != null) {
      e2eeKeyProvider.discardPreparedSession(preparedKeyProvider);
    }
    final currentKeyState = _keyShareState;
    final ownsPendingEnter = identical(_enterRequestOwner, owner);
    final ownsActiveCall = identical(_activeOwner, owner);
    final ownsKeyState = identical(currentKeyState?.owner, owner);
    if (!ownsPendingEnter && !ownsActiveCall && !ownsKeyState) return;

    _enterGeneration++;
    final gc = ownsActiveCall ? active : null;
    final activeInstance = gc == null
        ? null
        : OrexCallInstance(roomId: gc.room.id, ringEventId: _activeRingEventId);
    if (ownsActiveCall) {
      active = null;
      _activeOwner = null;
      _activeRingEventId = null;
    }
    final keyState = ownsKeyState ? currentKeyState : null;
    if (ownsKeyState) _keyShareState = null;
    if (keyState != null) {
      keyState.mediaOperationsDrained = mediaOperationsDrained;
      keyState.invalidate();
      final backend = keyState.groupCall.backend;
      if (backend is OrexLiveKitBackend) {
        // Invalidate timers/callbacks synchronously, before the first Matrix
        // membership await below. This also makes fullyDrained a stable barrier
        // before the provider lease is handed to asynchronous cleanup.
        unawaited(backend.dispose(keyState.groupCall));
      }
      _releaseKeyProviderLease(keyState);
    }
    notifyListeners();
    if (gc == null) {
      // enterCall may still be awaiting Matrix state publication. Invalidate its
      // backend immediately; the serialized enter wrapper performs membership
      // rollback when that await settles. Provider cleanup is already waiting
      // on both the backend and media barriers above.
      return;
    }

    // Detach process-local ownership before any remote state write. If the
    // homeserver or plugin stalls, Matrix SDK must not observe the membership
    // removal while still owning an entered GroupCallSession and force-join it.
    voip.groupCalls.removeWhere((_, value) => identical(value, gc));

    try {
      try {
        await markLeft(activeInstance!);
      } catch (e) {
        OrexLog.d('Voip', 'mark-left persistence failed', e);
      }
      final result = await const OrexCallCleanupCoordinator().cleanup(
        sessions: [
          OrexCallCleanupSession(
            label: gc.groupCallId,
            leave: () => OrexMatrixRequestGate.shared.run<void>(
              operationName: 'matrixrtc-leave',
              coalesceKey: 'matrixrtc-leave:${gc.room.id}:${gc.groupCallId}',
              maxAttempts: 1,
              operationTimeout: const Duration(seconds: 10),
              operation: gc.leave,
            ),
            disposeBackend: () async {
              final backend = gc.backend;
              if (backend is OrexLiveKitBackend) await backend.dispose(gc);
            },
          ),
        ],
        removeMembership: () => OrexMatrixRequestGate.shared.run<void>(
          operationName: 'matrixrtc-membership-cleanup',
          coalesceKey:
              'membership-cleanup:${gc.room.id}:${gc.groupCallId}',
          maxAttempts: 1,
          operationTimeout: const Duration(seconds: 10),
          operation: () => gc.room.removeFamedlyCallMemberEvent(
            gc.groupCallId,
            voip,
          ),
        ),
      );
      for (final failure in result.failures) {
        OrexLog.d(
          'Voip',
          'leave cleanup step failed room=${gc.room.id} step=${failure.step}',
          failure.error,
        );
      }
      if (result.membershipRemoved) {
        _pendingMembershipCleanupRooms.remove(gc.room.id);
      } else {
        _pendingMembershipCleanupRooms.add(gc.room.id);
        _scheduleStaleMembershipCleanup();
      }
    } finally {
      if (keyState != null) _releaseKeyProviderLease(keyState);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _syncSub?.cancel();
    _timelineSub?.cancel();
    _toDeviceSub?.cancel();
    _staleMembershipCleanupTimer?.cancel();
    _pendingMembershipCleanupRooms.clear();
    _dispositions.dispose();
    _persistedLeftRingEventIds.clear();
    _ringEventIds.clear();
    _incomingRingEventIds.clear();
    _outgoingRingPendingRooms.clear();
    _deferredRemoteDispositions.clear();
    _shownAttempts.clear();
    _legacySuppressedRooms.clear();
    _exactFallbackSuppressedRooms.clear();
    _suppressedExactAttempts.clear();
    _emittedPromotionAttempts.clear();
    _activeRingEventId = null;
    for (final timer in _endedDebounceTimers.values) {
      timer.cancel();
    }
    _endedDebounceTimers.clear();
    _incoming.close();
    _dismiss.close();
    _remoteAccepted.close();
    _remoteTerminations.close();
    _instancePromotions.close();
    _shutdownComplete = e2eeKeyProvider.dispose();
    unawaited(_shutdownComplete);
    super.dispose();
  }
}

/// Делегат WebRTC для SDK. Для LiveKit-бэкенда (SFU) почти все методы —
/// заглушки: реальное медиа обслуживает livekit_client. Но интерфейс требует
/// рабочие `mediaDevices`/`createPeerConnection` (их SDK трогает в конструкторе
/// и для 1:1 mesh-звонков), поэтому отдаём их из flutter_webrtc.
class _OrexCallDelegate implements WebRTCDelegate {
  _OrexCallDelegate(this.service);
  final VoipService service;

  @override
  MediaDevices get mediaDevices => rtc.navigator.mediaDevices;

  @override
  Future<RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration, [
    Map<String, dynamic> constraints = const {},
  ]) => rtc.createPeerConnection(configuration, constraints);

  @override
  bool get isWeb => kIsWeb;

  /// Не принимаем второй звонок поверх уже активного.
  @override
  bool get canHandleNewCall => service.active == null;

  /// MatrixRTC key signaling and LiveKit frame crypto share one provider.
  @override
  EncryptionKeyProvider get keyProvider => service.e2eeKeyProvider;

  @override
  Future<void> playRingtone() async {}

  @override
  Future<void> stopRingtone() async {}

  // --- 1:1 mesh-звонки не используем (только групповые на LiveKit) ---
  @override
  Future<void> registerListeners(CallSession session) async {}

  @override
  Future<void> handleNewCall(CallSession session) async {}

  @override
  Future<void> handleCallEnded(CallSession session) async {}

  @override
  Future<void> handleMissedCall(CallSession session) async {}

  // --- Групповые звонки: вход/выход обрабатываем сами через VoipService ---
  @override
  Future<void> handleNewGroupCall(GroupCallSession groupCall) async {
    service._handleIncomingGroupCall(groupCall);
  }

  @override
  Future<void> handleGroupCallEnded(GroupCallSession groupCall) async {
    service._handleGroupCallEnded(groupCall);
  }
}

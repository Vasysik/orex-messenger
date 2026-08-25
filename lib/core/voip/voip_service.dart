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

part 'voip_service_types.dart';
part 'voip_service_incoming_flow.dart';
part 'voip_service_membership_flow.dart';
part 'voip_service_delegate.dart';

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
  /// Bridge for library-part flow extensions. `ChangeNotifier.notifyListeners`
  /// is protected, so extension methods cannot call it directly even though
  /// they are part of this library. Keep the protected call inside the
  /// ChangeNotifier subclass and expose only a private library helper.
  void _notifyFlowListeners() => notifyListeners();

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

  /// Stops best-effort /sync cleanup from crossing an account boundary.
  ///
  /// Call teardown owns its exact active membership separately; this only
  /// cancels background discovery of stale memberships and invalidates an
  /// already-running unawaited scan.
  void pauseStaleMembershipCleanupForAccountTransition() {
    if (_disposed) return;
    _accountTransitionInProgress = true;
    _staleMembershipCleanupGeneration++;
    _staleMembershipCleanupTimer?.cancel();
    _staleMembershipCleanupTimer = null;
    _pendingMembershipCleanupRooms.clear();
  }

  /// Re-enables cleanup for the same still-authenticated account after an
  /// explicit logout failed before Matrix revoked its credentials.
  void resumeStaleMembershipCleanupAfterFailedAccountTransition() {
    if (_disposed || !client.isLogged()) return;
    _accountTransitionInProgress = false;
    _scheduleStaleMembershipCleanup();
  }

  /// A new successful login starts a new cleanup generation on its first sync.
  /// Do not schedule immediately: the client can still hold old cached rooms
  /// while the new account's initial sync is being applied.
  void resumeStaleMembershipCleanupForLoggedInAccount() {
    if (_disposed || !client.isLogged()) return;
    _accountTransitionInProgress = false;
  }

  bool _isStaleMembershipCleanupCurrent(_StaleMembershipCleanupScope scope) =>
      orexShouldContinueStaleMembershipCleanup(
        disposed: _disposed,
        accountTransitionInProgress: _accountTransitionInProgress,
        scheduledGeneration: scope.generation,
        currentGeneration: _staleMembershipCleanupGeneration,
        loggedIn: client.isLogged(),
        scheduledUserId: scope.userId,
        currentUserId: client.userID?.trim(),
        scheduledDeviceId: scope.deviceId,
        currentDeviceId: client.deviceID?.trim(),
      );

  /// Cleanup is serialized with call ownership. Removing Matrix state while a
  /// cached SDK GroupCallSession is still entered makes Matrix immediately
  /// force-join it again, producing the phantom loop seen in the logs.
  void _scheduleStaleMembershipCleanup() {
    final userId = client.userID?.trim();
    final deviceId = client.deviceID?.trim();
    if (_disposed ||
        _accountTransitionInProgress ||
        _staleMembershipCleanupInFlight != null ||
        !client.isLogged() ||
        userId == null ||
        userId.isEmpty ||
        deviceId == null ||
        deviceId.isEmpty) {
      return;
    }
    final scope = _StaleMembershipCleanupScope(
      generation: _staleMembershipCleanupGeneration,
      userId: userId,
      deviceId: deviceId,
    );
    late final Future<void> operation;
    operation =
        (() async {
          try {
            await _cleanupOwnStaleMemberships(scope);
          } catch (error) {
            // This task is deliberately unawaited from /sync. Do not turn a
            // session-expiry/logout race into an unhandled asynchronous exception.
            if (_isStaleMembershipCleanupCurrent(scope)) {
              OrexLog.d(
                'Voip',
                'background stale membership cleanup failed',
                error,
              );
            }
          }
        })().whenComplete(() {
          if (identical(_staleMembershipCleanupInFlight, operation)) {
            _staleMembershipCleanupInFlight = null;
          }
        });
    _staleMembershipCleanupInFlight = operation;
    unawaited(operation);
  }

  /// Удаляем своё членство в звонках, в которых мы на самом деле не находимся.
  Future<void> _cleanupOwnStaleMemberships(
    _StaleMembershipCleanupScope scope,
  ) async {
    if (!_isStaleMembershipCleanupCurrent(scope)) return;
    final roomIds = <String>{
      ..._pendingMembershipCleanupRooms,
      for (final room in client.rooms)
        if (_callMembers(room).contains(scope.userId)) room.id,
    };
    for (final roomId in roomIds) {
      if (!_isStaleMembershipCleanupCurrent(scope)) return;
      final room = client.getRoomById(roomId);
      if (room == null) continue;
      await _cleanupStaleRoomState(
        room,
        operationName: 'startup',
        staleMembershipCleanupScope: scope,
      );
    }
  }

  Future<void> _cleanupStaleRoomState(
    Room room, {
    required String operationName,
    _StaleMembershipCleanupScope? staleMembershipCleanupScope,
  }) => _VoipServiceMembershipFlow(this)._cleanupStaleRoomStateBody(
    room,
    operationName: operationName,
    staleMembershipCleanupScope: staleMembershipCleanupScope,
  );

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
      _promoteLegacyCallInstance(roomId, ringEventId, occurredAt: handledAt);
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

  void _applyRemoteDisposition(_DeferredRemoteDisposition disposition) =>
      _VoipServiceIncomingFlow(this)._applyRemoteDispositionBody(disposition);

  /// Short-lived outcomes and replay tombstones are owned by a dedicated
  /// lifecycle component rather than by this orchestration service.
  final OrexCallDispositionRegistry _dispositions = OrexCallDispositionRegistry(
    maxExactAttempts: 256,
  );
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
  bool _accountTransitionInProgress = false;
  int _staleMembershipCleanupGeneration = 0;

  static const _leftCallsPrefsKey = 'orex_voip_left_calls_v1';
  static const _maxPersistedLeftAge = Duration(days: 7);

  void _recordRejected(String roomId) => _dispositions.recordRejected(roomId);

  DateTime? _eventTimestamp(Object? raw) => _dispositions.parseTimestamp(raw);

  void _recordCallDisposition(
    String roomId, {
    DateTime? occurredAt,
    String? ringEventId,
    Duration? cleanupAfter = const Duration(minutes: 2),
  }) => _dispositions.record(
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
      _sendDispositionBestEffort(instance, _acceptedEventType);

  /// Сообщить инициатору (другим участникам комнаты), что мы отклонили звонок.
  Future<void> notifyRejected(OrexCallInstance instance) =>
      _sendDispositionBestEffort(instance, _rejectedEventType);

  Future<void> notifyBusy(OrexCallInstance instance) =>
      _sendDispositionBestEffort(instance, _busyEventType);

  Future<void> _sendDispositionBestEffort(
    OrexCallInstance instance,
    String eventType,
  ) async {
    try {
      await _signaling.sendDisposition(instance, eventType);
    } catch (error) {
      // Dispositions are an acceleration/control plane, not the local call
      // state owner. On web and during room-migration tests an unencrypted room
      // can reject plaintext call control; letting that exception escape breaks
      // all subsequent incoming/outgoing presentation.
      OrexLog.d(
        'Voip',
        'call disposition skipped event=$eventType room=${instance.roomId}',
        error,
      );
    }
  }

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
      _sendDispositionBestEffort(instance, _endedEventType),
      if (outgoingRing != null &&
          orexCallInstanceIdsMatch(outgoingRing.eventId, instance.ringEventId))
        _signaling
            .sendCancellation(
              room,
              ringEventId: outgoingRing.eventId,
              action: 'ended',
            )
            .then((sent) {
              if (!sent &&
                  !_ringEventIds.containsKey(roomId) &&
                  isCurrentCallInstance(instance)) {
                _ringEventIds[roomId] = outgoingRing;
              }
            })
            .catchError((Object error) {
              OrexLog.d(
                'Voip',
                'call cancellation skipped room=$roomId',
                error,
              );
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
  final Map<GroupCallSession, Future<void>> _groupCallCleanupTails =
      <GroupCallSession, Future<void>>{};

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

  /// Reserves an incoming attempt for an explicit native Answer action.
  ///
  /// A cold Flutter process can receive the action before its first Matrix
  /// sync has populated [_incomingRingEventIds].  Merely dismissing the native
  /// incoming surface in that state creates a tombstone, then CallController
  /// rejects its own answer because it cannot find a current attempt.  Seed a
  /// non-presented incoming identity instead: it is enough to establish
  /// ownership, does not emit Flutter UI/ringtone, and is removed once
  /// [enterCall] owns the active session.
  bool claimIncomingCallFromNativeAction(OrexCallInstance instance) {
    final roomId = instance.roomId.trim();
    if (roomId.isEmpty) return false;
    final ringEventId = instance.ringEventId?.trim();
    final normalized = OrexCallInstance(
      roomId: roomId,
      ringEventId: ringEventId?.isEmpty == true ? null : ringEventId,
    );

    // Upgrade a pre-existing tokenless incoming/enter/active state first.
    if (normalized.ringEventId != null) promoteCallInstance(normalized);

    final incomingPresent = _incomingRingEventIds.containsKey(roomId);
    final incomingRingEventId = _incomingRingEventIds[roomId];
    final shownRingEventId = _shownAttempts[roomId]?.ringEventId;
    final activeInRoom = active?.room.id == roomId;
    final activeRingEventId = activeInRoom ? _activeRingEventId : null;
    final enteringInRoom =
        _enterRequestOwner != null && _enterRequestRoomId == roomId;
    final enteringRingEventId = enteringInRoom
        ? _enterRequestRingEventId
        : null;
    final exactAttemptIsAlreadyOwned =
        (activeInRoom &&
            orexCallInstanceIdsMatch(
              activeRingEventId,
              normalized.ringEventId,
            )) ||
        (enteringInRoom &&
            orexCallInstanceIdsMatch(
              enteringRingEventId,
              normalized.ringEventId,
            ));
    if (!orexCanClaimNativeIncomingAttempt(
      actionRingEventId: normalized.ringEventId,
      knownRingEventIds: <String?>[
        if (incomingPresent) incomingRingEventId,
        shownRingEventId,
        activeRingEventId,
        enteringRingEventId,
      ],
    )) {
      OrexLog.d(
        'Voip',
        'ignored native Answer for a different call attempt '
            'room=$roomId ring=${normalized.ringEventId}',
      );
      return false;
    }
    final exactRingEventId = normalized.ringEventId;
    if (exactRingEventId != null &&
        (_hasExactCallDisposition(roomId, exactRingEventId) ||
            _hasExactCallSuppression(roomId, exactRingEventId)) &&
        !exactAttemptIsAlreadyOwned) {
      // A notification PendingIntent can outlive its ring UI. Do not let an
      // old Answer resurrect a call another device already handled or ended.
      // An exact active/entering attempt is deliberately left alone: a
      // duplicate native action for it is a harmless no-op.
      OrexLog.d(
        'Voip',
        'ignored native Answer for a tombstoned call attempt '
            'room=$roomId ring=$exactRingEventId',
      );
      return false;
    }

    if ((!incomingPresent && !activeInRoom && !enteringInRoom) ||
        (incomingRingEventId == null && normalized.ringEventId != null)) {
      _incomingRingEventIds[roomId] = normalized.ringEventId;
    }
    if (shownRingEventId == null &&
        normalized.ringEventId != null &&
        _shownAttempts.containsKey(roomId)) {
      final shown = _shownAttempts[roomId]!;
      _shownAttempts[roomId] = _ShownIncomingRing(
        normalized.ringEventId,
        shown.occurredAt,
      );
    }
    _removeShownAttempt(normalized);
    OrexLog.d(
      'Voip',
      'reserved incoming call from native Answer room=$roomId '
          'ring=${normalized.ringEventId}',
    );
    return true;
  }

  /// Releases a native Answer reservation that failed before [enterCall]
  /// produced an active session. Exact identity matching prevents a late
  /// failure from touching a newer redial in the same room.
  void releaseIncomingCallFromNativeAction(OrexCallInstance instance) {
    _removeIncomingAttempt(instance);
  }

  /// Releases only the incoming ownership of an attempt that was explicitly
  /// rejected. The handled/rejected tombstones remain intact, so the same
  /// ring cannot re-open incoming UI, while a later manual `Join` is free to
  /// enter a still-running MatrixRTC call in this room.
  void releaseRejectedIncomingAttempt(OrexCallInstance instance) {
    _tombstoneTrustedIncomingAction(instance);
    _removeShownAttempt(instance);
    _removeIncomingAttempt(instance);
  }

  /// A native action can arrive before Matrix sync has materialized the ring.
  /// Preserve its exact identity first, otherwise that later sync can reopen
  /// the Flutter incoming UI (and restart its ringtone) while answer is live.
  void _tombstoneTrustedIncomingAction(OrexCallInstance instance) {
    final ringEventId = instance.ringEventId?.trim();
    if (ringEventId == null || ringEventId.isEmpty) return;
    _suppressCall(instance.roomId, ringEventId);
    _recordCallDisposition(instance.roomId, ringEventId: ringEventId);
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
  }) => _VoipServiceIncomingFlow(this)._promoteLegacyCallInstanceBody(
    roomId,
    ringEventId,
    occurredAt: occurredAt,
  );

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
    List<CallParticipant> remoteParticipants, {
    Set<String> forceReplayParticipantIds = const <String>{},
  }) async {
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
      forceReplayParticipantIds: forceReplayParticipantIds,
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
  }) => _VoipServiceMembershipFlow(this)._ensureActiveCallEncryptionKeysBody(
    expectedRemoteParticipants: expectedRemoteParticipants,
    forceRemoteParticipantIds: forceRemoteParticipantIds,
    timeout: timeout,
    maxAttempts: maxAttempts,
  );

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

  /// Explicitly re-checks incoming calls after login/runtime activation.
  /// Desktop lifecycle delivery must not depend on making an outgoing call first.
  void refreshIncomingCalls() {
    if (_disposed || _accountTransitionInProgress || !_suppressionRestored) {
      return;
    }
    _scan();
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

  void _handleTimelineEvent(Event event) =>
      _VoipServiceIncomingFlow(this)._handleTimelineEventBody(event);

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
  }) => _VoipServiceIncomingFlow(this)._considerIncomingRoomBody(
    room,
    markExistingAsSeen: markExistingAsSeen,
    freshExplicitRingAt: freshExplicitRingAt,
    freshExplicitRingEventId: freshExplicitRingEventId,
  );

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
    _tombstoneTrustedIncomingAction(instance);
    if (!isCurrentCallInstance(instance)) return;
    final roomId = instance.roomId;
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
    promoteCallInstance(instance);
    _tombstoneTrustedIncomingAction(instance);
    if (isCurrentCallInstance(instance)) {
      _removeShownAttempt(instance);
    }
    await _signaling.sendHandled(instance);
  }

  List<CallMembership> _activeRemoteMemberships(Room room) {
    final memberships = room
        .getCallMembershipsFromRoom(voip)
        .values
        .expand((value) => value)
        .where(
          (membership) =>
              !membership.isExpired && membership.userId != client.userID,
        )
        .toList(growable: false);
    memberships.sort((a, b) => b.expiresTs.compareTo(a.expiresTs));
    return memberships;
  }

  String _resolveMatrixRtcCallId(
    Room room, {
    required String? expectedRingEventId,
  }) => orexSelectMatrixRtcCallId(
    roomId: room.id,
    expectedRingEventId: expectedRingEventId,
    remoteCallIds: _activeRemoteMemberships(
      room,
    ).map((membership) => membership.callId),
  );

  void _detachGroupCallSession(GroupCallSession groupCall) {
    if (groupCall.state != GroupCallState.ended) {
      groupCall.setState(GroupCallState.leaving);
    }
    voip.groupCalls.removeWhere((_, value) => identical(value, groupCall));
    if (voip.currentGroupCID?.roomId == groupCall.room.id &&
        voip.currentGroupCID?.callId == groupCall.groupCallId) {
      voip.currentGroupCID = null;
    }
    final current = active;
    if (voip.currentGroupCID == null &&
        current != null &&
        !identical(current, groupCall) &&
        current.state == GroupCallState.entered) {
      // A timed-out old enter may finish after the replacement and overwrite
      // the SDK-global currentGroupCID with its stale generation. Restore the
      // actual active owner after detaching the old session.
      for (final entry in voip.groupCalls.entries) {
        if (identical(entry.value, current)) {
          voip.currentGroupCID = entry.key;
          break;
        }
      }
    }
  }

  Future<void> _queueGroupCallCleanup(
    GroupCallSession groupCall, {
    required String operationName,
    bool repeatAfterExisting = false,
    _StaleMembershipCleanupScope? staleMembershipCleanupScope,
  }) {
    // State/registry ownership is released synchronously, even when an older
    // cleanup for this session is still waiting on the network. This prevents
    // Matrix SDK onMemberStateChanged() from force-rejoining the old call.
    _detachGroupCallSession(groupCall);
    final existing = _groupCallCleanupTails[groupCall];
    if (existing != null && !repeatAfterExisting) return existing;
    final previous = existing ?? Future<void>.value();
    late final Future<void> next;
    next = previous
        .catchError((Object _, StackTrace _) {})
        .then<void>(
          (_) => _cleanupGroupCallSession(
            groupCall,
            operationName,
            staleMembershipCleanupScope: staleMembershipCleanupScope,
          ),
        )
        .whenComplete(() {
          if (identical(_groupCallCleanupTails[groupCall], next)) {
            _groupCallCleanupTails.remove(groupCall);
          }
        });
    _groupCallCleanupTails[groupCall] = next;
    return next;
  }

  Future<void> _cleanupGroupCallSession(
    GroupCallSession groupCall,
    String operationName, {
    _StaleMembershipCleanupScope? staleMembershipCleanupScope,
  }) async {
    final room = groupCall.room;
    final callId = groupCall.groupCallId;
    _detachGroupCallSession(groupCall);

    final result = await const OrexCallCleanupCoordinator().cleanup(
      sessions: [
        OrexCallCleanupSession(
          label: callId,
          // Cancels the SDK membership-renewal timer synchronously before the
          // request is awaited. A timed-out gc.leave() cannot provide this
          // guarantee and may continue mutating the session in the background.
          leave: groupCall.removeMemberStateEvent,
          disposeBackend: () async {
            try {
              final backend = groupCall.backend;
              if (backend is OrexLiveKitBackend) {
                await backend.dispose(groupCall);
              }
            } finally {
              groupCall.setState(GroupCallState.ended);
            }
          },
        ),
      ],
      removeMembership: () async {
        final canContinue =
            staleMembershipCleanupScope == null ||
            _isStaleMembershipCleanupCurrent(staleMembershipCleanupScope);
        if (!canContinue) return;
        await OrexMatrixRequestGate.shared.run<void>(
          operationName: '$operationName-membership-cleanup',
          coalesceKey: 'membership-cleanup:${room.id}:$callId',
          maxAttempts: 1,
          operationTimeout: const Duration(seconds: 8),
          operation: () async {
            final canContinue =
                staleMembershipCleanupScope == null ||
                _isStaleMembershipCleanupCurrent(staleMembershipCleanupScope);
            if (!canContinue) return;
            await room.removeFamedlyCallMemberEvent(callId, voip);
          },
        );
      },
      stepTimeout: const Duration(seconds: 8),
    );
    for (final failure in result.failures) {
      OrexLog.d(
        'Voip',
        '$operationName cleanup step failed room=${room.id} '
            'call=$callId step=${failure.step}',
        failure.error,
      );
    }
    final canContinue =
        staleMembershipCleanupScope == null ||
        _isStaleMembershipCleanupCurrent(staleMembershipCleanupScope);
    if (!canContinue) return;
    if (result.membershipRemoved) {
      _pendingMembershipCleanupRooms.remove(room.id);
    } else {
      _pendingMembershipCleanupRooms.add(room.id);
      _scheduleStaleMembershipCleanup();
    }
  }

  Future<void> _cancelSentRing(
    Room room,
    String ringEventId, {
    required String action,
  }) async {
    final instance = OrexCallInstance(
      roomId: room.id,
      ringEventId: ringEventId,
    );
    try {
      await Future.wait<void>([
        _signaling.sendDisposition(instance, _endedEventType),
        _signaling
            .sendCancellation(room, ringEventId: ringEventId, action: action)
            .then<void>((_) {}),
      ]).timeout(const Duration(seconds: 6));
    } catch (error) {
      OrexLog.d(
        'Voip',
        'failed to cancel sent ring room=${room.id} ring=$ringEventId',
        error,
      );
    }
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
  }) => _VoipServiceMembershipFlow(this)._enterCallSerializedBody(
    roomId,
    owner: owner,
    ring: ring,
    video: video,
    expectedRingEventId: expectedRingEventId,
    enterGeneration: enterGeneration,
  );

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
    final groupCall = ownsActiveCall
        ? active
        : ownsKeyState
        ? currentKeyState?.groupCall
        : null;
    final ringEventId = ownsActiveCall
        ? _activeRingEventId
        : ownsPendingEnter
        ? _enterRequestRingEventId
        : null;
    final instance = groupCall == null
        ? null
        : OrexCallInstance(roomId: groupCall.room.id, ringEventId: ringEventId);

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
      _releaseKeyProviderLease(keyState);
    }
    notifyListeners();

    if (instance != null) {
      try {
        await markLeft(instance).timeout(const Duration(seconds: 4));
      } catch (error) {
        OrexLog.d('Voip', 'mark-left persistence failed', error);
      }
    }
    if (groupCall == null) return;

    try {
      await _queueGroupCallCleanup(
        groupCall,
        operationName: 'matrixrtc-leave',
      ).timeout(const Duration(seconds: 12));
    } on TimeoutException catch (error) {
      OrexLog.d(
        'Voip',
        'MatrixRTC leave continues asynchronously '
            'room=${groupCall.room.id} call=${groupCall.groupCallId}',
        error,
      );
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

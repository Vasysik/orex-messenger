import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Типы делегата (MediaDevices/RTCPeerConnection) берём из webrtc_interface —
// именно их ожидает WebRTCDelegate. У flutter_webrtc есть устаревший
// одноимённый MediaDevices, поэтому flutter_webrtc импортируем под префиксом.
import 'package:webrtc_interface/webrtc_interface.dart';

import '../config/orex_config.dart';
import '../logging/orex_logger.dart';
import 'call_ring_targets.dart';
import 'livekit_e2ee_key_provider.dart';

enum OrexRemoteCallTerminationReason { ended, rejected, busy }

@visibleForTesting
bool orexShouldMarkStartupCallAsSeen({
  required bool existedAtStartup,
  required bool hasFreshExplicitRing,
}) => existedAtStartup && !hasFreshExplicitRing;

@visibleForTesting
bool orexShouldResumePersistedCallAfterRing({
  required bool hasFreshExplicitRing,
}) => hasFreshExplicitRing;

class OrexRemoteCallTermination {
  const OrexRemoteCallTermination({
    required this.roomId,
    required this.reason,
  });

  final String roomId;
  final OrexRemoteCallTerminationReason reason;
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
    voip = VoIP(client, _OrexCallDelegate(this));
    // Входящие ловим СКАНИРОВАНИЕМ комнат на каждом sync (надёжнее, чем
    // voip.onIncomingGroupCall: не зависит от того, открывали ли мы чат, и не
    // «перезванивает» по уже существующему звонку при перезагрузке).
    // Snapshot calls and ring events already present in the startup cache. A
    // A ring that arrives while persisted suppress state is being restored must
    // still be treated as new; without this baseline the final startup scan marked all
    // visible calls as historical and swallowed genuine foreground calls.
    _seedStartupIncomingState();
    // A ring event can be followed immediately by MatrixRTC membership state,
    // so room.lastEvent is not a reliable transport for foreground incoming
    // presentation. Observe the decrypted timeline directly and feed the exact
    // ring event into the same deduplicated scanner path.
    _timelineSub = client.onTimelineEvent.stream.listen(_handleTimelineEvent);
    _suppressionRestore = _restorePersistedLeftCalls();
    _syncSub = client.onSync.stream.listen((_) {
      if (_suppressionRestored) _scan();
    });
    _toDeviceSub = client.onToDeviceEvent.stream.listen((ev) {
      // «Обработано на другом моём устройстве» (принят/отклонён) → закрыть входящий.
      if (ev.type == _handledEventType && ev.sender == client.userID) {
        final originDeviceId = ev.content['origin_device_id']
            ?.toString()
            .trim();
        final currentDeviceId = client.deviceID?.trim();
        if (originDeviceId != null &&
            originDeviceId.isNotEmpty &&
            currentDeviceId != null &&
            currentDeviceId.isNotEmpty &&
            originDeviceId == currentDeviceId) {
          return;
        }
        final roomId = ev.content['room_id']?.toString().trim();
        if (roomId != null && roomId.isNotEmpty) {
          _recordCallDisposition(
            roomId,
            occurredAt: _eventTimestamp(ev.content['handled_at_ms']),
          );
          _cancelRoomCallEnded(roomId);
          _suppress.add(roomId);
          _shown.remove(roomId);
          _dismiss.add(roomId);
        }
      }
      // Явные remote-disposition события закрывают звонок немедленно. Нельзя
      // ждать, пока MatrixRTC membership протухнет или stale lastEvent fallback
      // перестанет выглядеть активным.
      if (ev.type == _acceptedEventType ||
          ev.type == _rejectedEventType ||
          ev.type == _busyEventType ||
          ev.type == _endedEventType) {
        final roomId = _validatedRemoteDispositionRoomId(ev);
        if (roomId == null) return;
        final dispositionAt = _eventTimestamp(ev.content['disposition_at_ms']);
        if (ev.type == _acceptedEventType) {
          _remoteAccepted.add(roomId);
        } else if (ev.type == _rejectedEventType) {
          _recordRejected(roomId);
          _handleRemoteTermination(
            roomId,
            OrexRemoteCallTerminationReason.rejected,
            occurredAt: dispositionAt,
          );
        } else if (ev.type == _busyEventType) {
          _recordBusy(roomId);
          _handleRemoteTermination(
            roomId,
            OrexRemoteCallTerminationReason.busy,
            occurredAt: dispositionAt,
          );
        } else {
          _handleRemoteTermination(
            roomId,
            OrexRemoteCallTerminationReason.ended,
            occurredAt: dispositionAt,
          );
        }
      }
    });
    // Первичный scan запускается после восстановления persisted suppress.
    // Иначе продолжающийся звонок, из которого пользователь уже вышел до
    // process restart, успевает снова превратиться во "входящий".
    unawaited(_suppressionRestore);
    // Чистим СВОИ зависшие членства (после перезагрузки/закрытия вкладки во
    // время звонка) — иначе другой аккаунт видит нас «в звонке» (фантом).
    _staleMembershipCleanupTimer = Timer(
      const Duration(seconds: 4),
      _cleanupOwnStaleMemberships,
    );
  }

  /// Удаляем своё членство в звонках, в которых мы на самом деле не находимся.
  Future<void> _cleanupOwnStaleMemberships() async {
    final myId = client.userID;
    for (final room in client.rooms) {
      if (!_callMembers(room).contains(myId)) continue;
      if (active != null && active!.room.id == room.id) {
        continue; // реально в звонке
      }
      try {
        await room.removeFamedlyCallMemberEvent(room.id, voip);
        OrexLog.d('Voip', 'removed phantom call membership room=${room.id}');
      } catch (e) {
        OrexLog.d('Voip', 'cleanup stale membership failed', e);
      }
    }
  }

  static const _handledEventType = 'com.orex.call.handled';
  static const _acceptedEventType = 'com.orex.call.accepted';
  static const _rejectedEventType = 'com.orex.call.rejected';
  static const _busyEventType = 'com.orex.call.busy';
  static const _endedEventType = 'com.orex.call.ended';

  String? _validatedRemoteDispositionRoomId(ToDeviceEvent event) {
    final roomId = event.content['room_id']?.toString().trim();
    final sender = event.sender.trim();
    if (roomId == null || roomId.isEmpty || sender.isEmpty) return null;
    final room = client.getRoomById(roomId);
    if (room == null || !isPersonalCallRoom(room) || sender == client.userID) {
      OrexLog.d(
        'Voip',
        'ignored remote disposition type=${event.type} room=$roomId sender=$sender',
      );
      return null;
    }
    final joinedPeer = room
        .getParticipants([Membership.join])
        .any((user) => user.id == sender);
    if (!joinedPeer && room.directChatMatrixID != sender) {
      OrexLog.d(
        'Voip',
        'ignored non-peer disposition type=${event.type} room=$roomId sender=$sender',
      );
      return null;
    }
    return roomId;
  }

  /// roomId → когда собеседник отклонил звонок (для текста итогового сообщения).
  final Map<String, DateTime> _rejected = {};
  final Map<String, Timer> _rejectedCleanupTimers = <String, Timer>{};
  final Map<String, DateTime> _busy = {};
  final Map<String, Timer> _busyCleanupTimers = <String, Timer>{};
  final Map<String, DateTime> _callDispositionAt = <String, DateTime>{};
  final Map<String, Timer> _callDispositionCleanupTimers = <String, Timer>{};
  final Map<String, DateTime> _persistedLeftAt = <String, DateTime>{};
  Future<void>? _suppressionRestore;
  bool _suppressionRestored = false;
  bool _disposed = false;
  final Map<String, String> _ringEventIds = <String, String>{};
  final Set<String> _seenIncomingRingEventIds = <String>{};
  static const int _maxRememberedIncomingRingEvents = 256;
  final Set<String> _startupExistingCallRoomIds = <String>{};
  final Map<String, Room> _pendingFreshRingRooms = <String, Room>{};
  Timer? _staleMembershipCleanupTimer;

  static const _leftCallsPrefsKey = 'orex_voip_left_calls_v1';
  static const _maxPersistedLeftAge = Duration(days: 7);

  void _recordRejected(String roomId) {
    _rejected[roomId] = DateTime.now();
    _rejectedCleanupTimers.remove(roomId)?.cancel();
    _rejectedCleanupTimers[roomId] = Timer(const Duration(seconds: 60), () {
      _rejectedCleanupTimers.remove(roomId);
      _rejected.remove(roomId);
    });
  }

  DateTime? _eventTimestamp(Object? raw) {
    final milliseconds = switch (raw) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value),
      _ => null,
    };
    if (milliseconds == null || milliseconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }

  void _recordCallDisposition(
    String roomId, {
    DateTime? occurredAt,
    Duration? cleanupAfter = const Duration(minutes: 2),
  }) {
    final timestamp = occurredAt ?? DateTime.now();
    final current = _callDispositionAt[roomId];
    if (current != null && !timestamp.isAfter(current)) return;

    _callDispositionAt[roomId] = timestamp;
    _callDispositionCleanupTimers.remove(roomId)?.cancel();
    if (cleanupAfter == null) return;
    _callDispositionCleanupTimers[roomId] = Timer(cleanupAfter, () {
      _callDispositionCleanupTimers.remove(roomId);
      if (_callDispositionAt[roomId] == timestamp) {
        _callDispositionAt.remove(roomId);
      }
    });
  }

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
            _persistedLeftAt[roomId] = leftAt;
            _recordCallDisposition(
              roomId,
              occurredAt: leftAt,
              cleanupAfter: null,
            );
            _suppress.add(roomId);
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
        for (final room in pendingRings) {
          _presentFreshIncomingRing(room);
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
    if (_persistedLeftAt.remove(roomId) == null) return;
    unawaited(_persistLeftCalls());
  }

  void _handleRemoteTermination(
    String roomId,
    OrexRemoteCallTerminationReason reason, {
    DateTime? occurredAt,
  }) {
    // Keep the original ring event id until CallController has forwarded an
    // exact `handled` cancellation to the peer's sibling devices. Removing it
    // here made reject/busy lose the only token capable of stopping a killed
    // tablet/secondary phone. cancelOutstandingRing() consumes it single-flight.
    _recordCallDisposition(roomId, occurredAt: occurredAt);
    _cancelRoomCallEnded(roomId);
    _suppress.add(roomId);
    _shown.remove(roomId);
    _dismiss.add(roomId);
    _remoteTerminations.add(
      OrexRemoteCallTermination(roomId: roomId, reason: reason),
    );
  }

  /// Собеседник отклонил звонок в этой комнате (недавно).
  bool wasRejected(String roomId) => _rejected.containsKey(roomId);

  void clearRejected(String roomId) {
    _rejectedCleanupTimers.remove(roomId)?.cancel();
    _rejected.remove(roomId);
  }

  void _recordBusy(String roomId) {
    _busy[roomId] = DateTime.now();
    _busyCleanupTimers.remove(roomId)?.cancel();
    _busyCleanupTimers[roomId] = Timer(const Duration(seconds: 60), () {
      _busyCleanupTimers.remove(roomId);
      _busy.remove(roomId);
    });
  }

  bool wasBusy(String roomId) => _busy.containsKey(roomId);

  void clearBusy(String roomId) {
    _busyCleanupTimers.remove(roomId)?.cancel();
    _busy.remove(roomId);
  }

  /// Сообщить инициатору, что пользователь явно принял звонок.
  Future<void> notifyAccepted(String roomId) =>
      _notifyRemoteDisposition(roomId, _acceptedEventType);

  /// Сообщить инициатору (другим участникам комнаты), что мы отклонили звонок.
  Future<void> notifyRejected(String roomId) =>
      _notifyRemoteDisposition(roomId, _rejectedEventType);

  Future<void> notifyBusy(String roomId) =>
      _notifyRemoteDisposition(roomId, _busyEventType);

  /// Явно завершить личный звонок на удалённых устройствах.
  ///
  /// MatrixRTC membership остаётся источником присутствия в звонке, но его
  /// удаление приходит через sync не мгновенно. Это событие — быстрый control
  /// plane, чтобы удалённая сторона сразу прекратила ringtone/UI.
  Future<void> notifyEnded(String roomId) async {
    final room = client.getRoomById(roomId);
    if (room == null || !isPersonalCallRoom(room)) return;
    final ringEventId = _ringEventIds.remove(roomId);
    await Future.wait<void>([
      _notifyRemoteDisposition(roomId, _endedEventType),
      if (ringEventId != null)
        _sendPersonalCallCancellation(
          room,
          ringEventId: ringEventId,
          action: 'ended',
        ).then((sent) {
          if (!sent && !_ringEventIds.containsKey(roomId)) {
            _ringEventIds[roomId] = ringEventId;
          }
        }),
    ]);
  }

  /// Cancels only the outstanding incoming-ring presentation on the peer's
  /// devices. The caller invokes this after one peer device accepted/rejected,
  /// so killed sibling devices receive an exact FCM cancellation from the
  /// original ring sender without ending the accepted media call.
  Future<void> cancelOutstandingRing(String roomId) async {
    final room = client.getRoomById(roomId);
    if (room == null || !isPersonalCallRoom(room)) return;
    final ringEventId = _ringEventIds.remove(roomId);
    if (ringEventId == null) return;
    final sent = await _sendPersonalCallCancellation(
      room,
      ringEventId: ringEventId,
      action: 'handled',
    );
    if (!sent && !_ringEventIds.containsKey(roomId)) {
      _ringEventIds[roomId] = ringEventId;
    }
  }

  Future<bool> _sendPersonalCallCancellation(
    Room room, {
    required String ringEventId,
    required String action,
  }) async {
    final targets = orexResolveCallRingTargets(
      localUserId: client.userID,
      joinedUserIds: room
          .getParticipants([Membership.join])
          .map((user) => user.id),
      directChatMatrixId: room.directChatMatrixID,
    );
    if (targets.isEmpty) return false;
    final notification = RtcNotificationContent.create(
      type: RtcNotificationType.notification,
      lifetime: const Duration(seconds: 30),
    );
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await client.sendMessage(
          room.id,
          RtcNotificationContent.eventType,
          client.generateUniqueTransactionId(),
          <String, Object?>{
            ...notification.toJson(),
            'm.mentions': {
              'user_ids': targets.toList(growable: false),
            },
            'orex_call_action': action,
            'orex_ring_event_id': ringEventId,
          },
        );
        return true;
      } catch (error) {
        lastError = error;
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 650));
        }
      }
    }
    // The to-device disposition remains the primary control plane for a live
    // process. This event is the wake-up path for killed sibling devices.
    OrexLog.d(
      'Voip',
      'RTC ring cancellation failed room=${room.id}',
      lastError,
    );
    return false;
  }

  Future<void> _notifyRemoteDisposition(
    String roomId,
    String eventType,
  ) async {
    final room = client.getRoomById(roomId);
    if (room == null) return;
    final others = orexResolveCallRingTargets(
      localUserId: client.userID,
      joinedUserIds: room
          .getParticipants([Membership.join])
          .map((user) => user.id),
      directChatMatrixId: room.directChatMatrixID,
    );
    if (others.isEmpty) return;
    final dispositionAtMs = DateTime.now().millisecondsSinceEpoch;
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await client.sendToDevice(
          eventType,
          client.generateUniqueTransactionId(),
          {
            for (final u in others)
              u: {
                '*': {
                  'room_id': roomId,
                  'call_id': roomId,
                  'disposition_at_ms': dispositionAtMs,
                },
              },
          },
        );
        return;
      } catch (error) {
        lastError = error;
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 650));
        }
      }
    }
    OrexLog.d(
      'Voip',
      'remote disposition failed type=$eventType room=$roomId',
      lastError,
    );
  }

  final Client client;
  late final VoIP voip;

  StreamSubscription? _syncSub;
  StreamSubscription<Event>? _timelineSub;
  StreamSubscription<ToDeviceEvent>? _toDeviceSub;
  final StreamController<Room> _incoming = StreamController<Room>.broadcast();
  final StreamController<String> _dismiss =
      StreamController<String>.broadcast();
  final StreamController<String> _remoteAccepted =
      StreamController<String>.broadcast();
  final StreamController<OrexRemoteCallTermination> _remoteTerminations =
      StreamController<OrexRemoteCallTermination>.broadcast();

  // MatrixRTC membership can briefly disappear/reappear during sync while the
  // SDK rewrites `com.famedly.call.member`. Do not close an incoming dialog or
  // clear local suppress state on the first "no call" frame; wait for a stable
  // no-call state instead.
  static const Duration _endedDebounceDelay = Duration(milliseconds: 1800);

  final Set<String> _shown =
      <String>{}; // по этим комнатам сейчас показан входящий
  final Set<String> _suppress =
      <String>{}; // не звонить: вышли / было при старте / обработано
  final Map<String, Timer> _endedDebounceTimers = <String, Timer>{};

  /// Входящие звонки: roomId комнаты, где идёт звонок, в который мы не вошли.
  Stream<Room> get onIncomingCall => _incoming.stream;

  /// Уже обнаруженные входящие, которые могли попасть в broadcast stream до
  /// готовности Navigator/UI. Main replays этот список после первого кадра,
  /// иначе звонок можно было потерять до открытия любого чата.
  List<Room> visibleIncomingRooms() =>
      _shown.map(client.getRoomById).whereType<Room>().toList(growable: false);

  /// Комнаты, по которым надо ЗАКРЫТЬ открытый входящий (звонок кончился или
  /// обработан на другом устройстве).
  Stream<String> get onDismissIncoming => _dismiss.stream;

  Stream<String> get onRemoteCallAccepted => _remoteAccepted.stream;

  Stream<OrexRemoteCallTermination> get onRemoteCallTermination =>
      _remoteTerminations.stream;

  /// Текущий звонок, в который мы вошли (опубликовали своё членство).
  GroupCallSession? active;

  bool get inCall => active != null;

  /// Resynchronise MatrixRTC media keys for participants that joined before
  /// the current LiveKit room became ready. MatrixRTC deliberately keeps key
  /// exchange on the Matrix to-device plane, so late subscribers must request
  /// keys explicitly instead of restarting local audio/video publications.
  Future<void> ensureActiveCallEncryptionKeys({
    required int expectedRemoteParticipants,
    Duration timeout = const Duration(seconds: 3),
    int maxAttempts = 4,
  }) async {
    final groupCall = active;
    if (groupCall == null) return;

    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        await groupCall.onMemberStateChanged();
        if (!identical(active, groupCall)) return;

        final remoteParticipants = groupCall.participants
            .where((participant) => !participant.isLocal)
            .toList(growable: false);
        final knownRemoteMemberships = _callMembers(groupCall.room)
            .where((userId) => userId != client.userID)
            .length;
        final minimumRemoteParticipants =
            knownRemoteMemberships > expectedRemoteParticipants
            ? knownRemoteMemberships
            : expectedRemoteParticipants;
        if (remoteParticipants.length < minimumRemoteParticipants) {
          lastError = StateError(
            'MatrixRTC membership lag: expected $minimumRemoteParticipants '
            'remote participant(s), saw ${remoteParticipants.length}',
          );
        } else {
          final missing = remoteParticipants
              .where((participant) => !e2eeKeyProvider.hasKeyFor(participant))
              .toList(growable: false);
          if (missing.isEmpty) return;

          await groupCall.requestEncrytionKey(missing);
          if (await e2eeKeyProvider.waitForKeys(missing, timeout: timeout)) {
            return;
          }
          lastError = StateError(
            'Timed out waiting for ${missing.length} MatrixRTC media key(s)',
          );
        }
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
    throw StateError(
      'Не удалось получить ключи защищённого медиапотока',
    );
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
    final terminatedAt = _callDispositionAt[room.id];
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
      final hasFreshExplicitRing = _consumeFreshIncomingRing(room);
      if (!_roomHasCall(room)) {
        if (hasFreshExplicitRing) {
          _cancelRoomCallEnded(room.id);
          _considerIncomingRoom(
            room,
            markExistingAsSeen: false,
            hasFreshExplicitRing: true,
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
        hasFreshExplicitRing: hasFreshExplicitRing,
      );
    }
  }

  void _seedStartupIncomingState() {
    for (final room in client.rooms) {
      if (_roomHasCall(room)) _startupExistingCallRoomIds.add(room.id);
      final eventId = _incomingRingEventId(room);
      if (eventId != null) _rememberIncomingRingEventId(eventId);
    }
  }

  void _handleTimelineEvent(Event event) {
    if (_disposed || event.senderId == client.userID) return;
    if (event.tryParseRtcNotificationContent()?.notificationType !=
        RtcNotificationType.ring) {
      return;
    }
    final age = DateTime.now().difference(event.originServerTs);
    if (age > _timelineCallFallbackTtl) return;

    final eventId = event.eventId.trim();
    if (eventId.isEmpty || !_rememberIncomingRingEventId(eventId)) return;

    if (!_suppressionRestored) {
      _pendingFreshRingRooms[event.room.id] = event.room;
      return;
    }
    _presentFreshIncomingRing(event.room);
  }

  void _presentFreshIncomingRing(Room room) {
    _cancelRoomCallEnded(room.id);
    _considerIncomingRoom(
      room,
      markExistingAsSeen: false,
      hasFreshExplicitRing: true,
    );
  }

  bool _consumeFreshIncomingRing(Room room) {
    final eventId = _incomingRingEventId(room);
    return eventId != null && _rememberIncomingRingEventId(eventId);
  }

  bool _rememberIncomingRingEventId(String eventId) {
    if (!_seenIncomingRingEventIds.add(eventId)) return false;
    while (_seenIncomingRingEventIds.length > _maxRememberedIncomingRingEvents) {
      _seenIncomingRingEventIds.remove(_seenIncomingRingEventIds.first);
    }
    return true;
  }

  String? _incomingRingEventId(Room room) {
    final event = room.lastEvent;
    if (event == null || event.senderId == client.userID) return null;
    if (event.tryParseRtcNotificationContent()?.notificationType !=
        RtcNotificationType.ring) {
      return null;
    }
    final eventId = event.eventId.trim();
    return eventId.isEmpty ? null : eventId;
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
    bool hasFreshExplicitRing = false,
  }) {
    final myId = client.userID;
    final currentCall = active;
    if (currentCall != null) {
      if (currentCall.room.id == room.id) return;
      // Orex supports one personal media session at a time. Never stack a
      // second incoming UI on top of an active call; answer the second attempt
      // once with an explicit busy disposition instead.
      if (_shouldRingForRoom(room) && _suppress.add(room.id)) {
        OrexLog.d(
          'Voip',
          'incoming call rejected as busy while another call is active room=${room.id}',
        );
        unawaited(notifyBusy(room.id));
      }
      return;
    }
    if (_shown.contains(room.id)) return;
    if (hasFreshExplicitRing && !_persistedLeftAt.containsKey(room.id)) {
      _suppress.remove(room.id);
    }
    if (_suppress.contains(room.id) &&
        !_resumeAfterNewRemoteCall(
          room,
          hasFreshExplicitRing: hasFreshExplicitRing,
        )) {
      return;
    }
    final others = _callMembers(room).where((id) => id != myId).toSet();
    if (others.isEmpty && !hasFreshExplicitRing) {
      return; // только моё членство — не входящий
    }
    if (!_shouldRingForRoom(room)) {
      // В группах, каналах и чатах супергруппы звонок — это голосовой канал:
      // не показываем системный входящий вызов всем участникам. Комната всё
      // равно помечается активной, поэтому UI покажет «Идёт звонок · Войти».
      _suppress.add(room.id);
      return;
    }
    if (markExistingAsSeen && !hasFreshExplicitRing) {
      _suppress.add(
        room.id,
      ); // активен на старте → не звоним (покажет панель «войти»)
      return;
    }
    OrexLog.d(
      'Voip',
      'incoming direct call room=${room.id} '
          'from=${others.isEmpty ? 'explicit-ring' : others.join(',')}',
    );
    _shown.add(room.id);
    _incoming.add(room);
  }

  bool _resumeAfterNewRemoteCall(
    Room room, {
    bool hasFreshExplicitRing = false,
  }) {
    final terminatedAt = _callDispositionAt[room.id];
    if (terminatedAt == null) return false;
    if (!orexShouldResumePersistedCallAfterRing(
      hasFreshExplicitRing: hasFreshExplicitRing,
    )) {
      return false;
    }

    _callDispositionCleanupTimers.remove(room.id)?.cancel();
    _callDispositionAt.remove(room.id);
    _suppress.remove(room.id);
    _clearPersistedLeftCall(room.id);
    return true;
  }

  void _cancelRoomCallEnded(String roomId) {
    _endedDebounceTimers.remove(roomId)?.cancel();
  }

  void _scheduleRoomCallEnded(String roomId) {
    if (!_shown.contains(roomId) && !_suppress.contains(roomId)) return;
    if (_endedDebounceTimers.containsKey(roomId)) return;
    _endedDebounceTimers[roomId] = Timer(_endedDebounceDelay, () {
      _endedDebounceTimers.remove(roomId);
      final room = client.getRoomById(roomId);
      if (room != null && _roomHasCall(room)) return;
      _finishRoomCallEnded(roomId);
    });
  }

  void _finishRoomCallEnded(String roomId) {
    final wasShown = _shown.remove(roomId);
    if (wasShown) _dismiss.add(roomId);
    // Persisted leave-state suppresses the continuing MatrixRTC room call.
    // Membership refreshes are not a new invitation, so a transient empty
    // frame after our own leave must not erase the tombstone. Only a fresh
    // explicit ring clears it in _resumeAfterNewRemoteCall().
    if (_persistedLeftAt.containsKey(roomId)) return;
    _suppress.remove(roomId);
    _callDispositionCleanupTimers.remove(roomId)?.cancel();
    _callDispositionAt.remove(roomId);
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
  Future<void> markLeft(String roomId) async {
    _cancelRoomCallEnded(roomId);
    final leftAt = DateTime.now();
    _persistedLeftAt[roomId] = leftAt;
    _recordCallDisposition(
      roomId,
      occurredAt: leftAt,
      cleanupAfter: null,
    );
    _suppress.add(roomId);
    if (_shown.remove(roomId)) _dismiss.add(roomId);
    await _persistLeftCalls();
  }

  /// Закрыть локальный экран входящего при действии из Android system UI.
  /// Обычный accept/decline из Flutter не использует этот метод, потому что его
  /// экран сам управляет навигацией после завершения асинхронного действия.
  void dismissIncomingFromSystem(String roomId) {
    _suppress.add(roomId);
    if (_shown.remove(roomId)) _dismiss.add(roomId);
  }

  /// Пометить обработанным (принят/отклонён) и сообщить другим своим устройствам.
  Future<void> markCallHandled(String roomId, String callId) async {
    _suppress.add(roomId);
    _shown.remove(roomId);
    final handledAtMs = DateTime.now().millisecondsSinceEpoch;
    final handledContent = <String, dynamic>{
      'room_id': roomId,
      'call_id': callId,
      'handled_at_ms': handledAtMs,
    };
    final currentDeviceId = client.deviceID?.trim();
    if (currentDeviceId != null && currentDeviceId.isNotEmpty) {
      handledContent['origin_device_id'] = currentDeviceId;
    }

    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await client.sendToDevice(
          _handledEventType,
          client.generateUniqueTransactionId(),
          {
            client.userID!: {
              '*': handledContent,
            },
          },
        );
        return;
      } catch (error) {
        lastError = error;
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 650));
        }
      }
    }
    OrexLog.d(
      'Voip',
      'mark call handled failed room=$roomId call=$callId',
      lastError,
    );
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
    bool ring = false,
    bool video = false,
  }) async {
    final room = client.getRoomById(roomId);
    if (room == null) {
      throw StateError('Комната $roomId не найдена');
    }

    // Explicitly entering a room supersedes an old local-leave tombstone.
    // If the user leaves again, the continuing room call stays suppressed
    // until a genuinely new explicit ring event arrives.
    _clearPersistedLeftCall(roomId);
    _callDispositionCleanupTimers.remove(roomId)?.cancel();
    _callDispositionAt.remove(roomId);
    _suppress.remove(roomId);

    final backend = LiveKitBackend(
      livekitServiceUrl: OrexConfig.jwtServiceUri.toString(),
      livekitAlias: roomId,
      // MatrixRTC distributes the same per-participant keys consumed by the
      // LiveKit BaseKeyProvider in CallSession.
      e2eeEnabled: true,
    );

    final gc = await voip.fetchOrCreateGroupCall(
      roomId,
      room,
      backend,
      'm.call',
      'm.room',
      preShareKey: true,
    );

    // The provider is shared across the app process, while MatrixRTC media
    // keys rotate across leave/rejoin cycles. Reset only readiness observations
    // before entering; gc.enter() delivers/pre-shares the current keys through
    // onSetEncryptionKey.
    e2eeKeyProvider.resetObservedKeys();

    try {
      await gc.enter();
    } catch (e) {
      OrexLog.d(
        'Voip',
        'enter call failed room=$roomId call=${gc.groupCallId}',
        e,
      );
      try {
        await gc.leave();
      } catch (leaveError) {
        OrexLog.d(
          'Voip',
          'rollback leave failed room=$roomId call=${gc.groupCallId}',
          leaveError,
        );
      }
      try {
        await room.removeFamedlyCallMemberEvent(gc.groupCallId, voip);
      } catch (removeError) {
        OrexLog.d(
          'Voip',
          'rollback membership cleanup failed room=$roomId call=${gc.groupCallId}',
          removeError,
        );
      }
      voip.groupCalls.removeWhere(
        (k, v) => k.roomId == room.id && k.callId == gc.groupCallId,
      );
      rethrow;
    }
    active = gc;
    notifyListeners();
    if (ring) {
      await _sendPersonalCallRing(room, video: video);
    }
    return gc;
  }

  Future<void> _sendPersonalCallRing(Room room, {required bool video}) async {
    if (!isPersonalCallRoom(room)) return;

    final targets = orexResolveCallRingTargets(
      localUserId: client.userID,
      joinedUserIds: room
          .getParticipants([Membership.join])
          .map((user) => user.id),
      directChatMatrixId: room.directChatMatrixID,
    );
    if (targets.isEmpty) {
      OrexLog.d('Voip', 'ring skipped: no remote target room=${room.id}');
      return;
    }

    try {
      // Критичный Android wake-up сигнал отправляем как открытый MatrixRTC
      // envelope. Обычный Room.sendRtcNotification() проходит через sendEvent()
      // и в E2EE-комнате превращается в m.room.encrypted; тогда убитое Android-
      // приложение не может понять из FCM payload, что это именно звонок, без
      // запуска второго FlutterEngine и расшифровки БД. Здесь нет текста,
      // ключей или медиаданных — только короткоживущий ring-сигнал MSC4075.
      final notification = RtcNotificationContent.create(
        type: RtcNotificationType.ring,
        lifetime: const Duration(seconds: 45),
      );
      final content = <String, Object?>{
        ...notification.toJson(),
        'm.mentions': {
          'user_ids': targets.toList(growable: false),
        },
        'm.call.intent': video ? 'video' : 'audio',
      };
      final eventId = await client.sendMessage(
        room.id,
        RtcNotificationContent.eventType,
        client.generateUniqueTransactionId(),
        content,
      );
      _ringEventIds[room.id] = eventId;
      OrexLog.d(
        'Voip',
        'Wakeable RTC ring sent room=${room.id} targets=${targets.length}',
      );
    } catch (error) {
      // Ring delivery is an attention signal. The MatrixRTC membership above
      // remains the source of truth, so a transient push/ring failure must not
      // tear down a call that is otherwise already valid.
      OrexLog.d('Voip', 'RTC ring send failed room=${room.id}', error);
    }
  }

  /// Выйти из текущего звонка: убираем своё членство из state комнаты.
  Future<void> leaveCurrent() async {
    final gc = active;
    active = null;
    notifyListeners();
    if (gc != null) {
      // Не «перезванивать» по тому же продолжающемуся звонку комнаты.
      await markLeft(gc.room.id);
      try {
        await gc.leave();
      } catch (e) {
        OrexLog.d('Voip', 'leave current failed', e);
      }
      // Подстраховка: гарантированно убираем своё членство (если leave() не
      // справился) — иначе остаёмся «фантомом» в звонке для остальных.
      try {
        await gc.room.removeFamedlyCallMemberEvent(gc.groupCallId, voip);
      } catch (e) {
        OrexLog.d(
          'Voip',
          'membership cleanup after leave failed room=${gc.room.id} call=${gc.groupCallId}',
          e,
        );
      }
      // И чистим локальную карту, чтобы будущие звонки не глохли (VoipId не
      // экспортируется — фильтруем по полям ключа).
      voip.groupCalls.removeWhere(
        (k, v) => k.roomId == gc.room.id && k.callId == gc.groupCallId,
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
    for (final timer in _rejectedCleanupTimers.values) {
      timer.cancel();
    }
    _rejectedCleanupTimers.clear();
    for (final timer in _busyCleanupTimers.values) {
      timer.cancel();
    }
    _busyCleanupTimers.clear();
    for (final timer in _callDispositionCleanupTimers.values) {
      timer.cancel();
    }
    _callDispositionCleanupTimers.clear();
    _callDispositionAt.clear();
    _ringEventIds.clear();
    for (final timer in _endedDebounceTimers.values) {
      timer.cancel();
    }
    _endedDebounceTimers.clear();
    _incoming.close();
    _dismiss.close();
    _remoteAccepted.close();
    _remoteTerminations.close();
    unawaited(e2eeKeyProvider.dispose());
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

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart';
// Типы делегата (MediaDevices/RTCPeerConnection) берём из webrtc_interface —
// именно их ожидает WebRTCDelegate. У flutter_webrtc есть устаревший
// одноимённый MediaDevices, поэтому flutter_webrtc импортируем под префиксом.
import 'package:webrtc_interface/webrtc_interface.dart';

import '../config/orex_config.dart';
import '../logging/orex_logger.dart';
import 'call_ring_targets.dart';

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
  VoipService(this.client) {
    voip = VoIP(client, _OrexCallDelegate(this));
    // Входящие ловим СКАНИРОВАНИЕМ комнат на каждом sync (надёжнее, чем
    // voip.onIncomingGroupCall: не зависит от того, открывали ли мы чат, и не
    // «перезванивает» по уже существующему звонку при перезагрузке).
    _syncSub = client.onSync.stream.listen((_) => _scan());
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
        final roomId = ev.content['room_id'] as String?;
        if (roomId != null) {
          _suppress.add(roomId);
          _shown.remove(roomId);
          _dismiss.add(roomId);
        }
      }
      // «Собеседник отклонил звонок» → запомним, чтобы инициатор написал
      // «Отклонённый вызов» вместо «Пропущенный».
      if (ev.type == _rejectedEventType) {
        final roomId = ev.content['room_id'] as String?;
        if (roomId != null) {
          _rejected[roomId] = DateTime.now();
          _rejectedCleanupTimers.remove(roomId)?.cancel();
          _rejectedCleanupTimers[roomId] = Timer(
            const Duration(seconds: 60),
            () {
              _rejectedCleanupTimers.remove(roomId);
              _rejected.remove(roomId);
            },
          );
        }
      }
    });
    // Первичный проход только по локальному кэшу: уже активные до запуска
    // звонки помечаем виденными. Новые звонки из следующих /sync больше не
    // глушим таймером — иначе на телефоне можно было не увидеть входящий,
    // если чат ещё не открывали или приложение только поднялось.
    _scan(markExistingAsSeen: true);
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
  static const _rejectedEventType = 'com.orex.call.rejected';

  /// roomId → когда собеседник отклонил звонок (для текста итогового сообщения).
  final Map<String, DateTime> _rejected = {};
  final Map<String, Timer> _rejectedCleanupTimers = <String, Timer>{};
  Timer? _staleMembershipCleanupTimer;

  /// Собеседник отклонил звонок в этой комнате (недавно).
  bool wasRejected(String roomId) => _rejected.containsKey(roomId);

  void clearRejected(String roomId) {
    _rejectedCleanupTimers.remove(roomId)?.cancel();
    _rejected.remove(roomId);
  }

  /// Сообщить инициатору (другим участникам комнаты), что мы отклонили звонок.
  Future<void> notifyRejected(String roomId) async {
    final room = client.getRoomById(roomId);
    if (room == null) return;
    final others = room
        .getParticipants([Membership.join])
        .map((u) => u.id)
        .where((id) => id != client.userID)
        .toSet();
    if (others.isEmpty) return;
    try {
      await client.sendToDevice(
        _rejectedEventType,
        client.generateUniqueTransactionId(),
        {
          for (final u in others)
            u: {
              '*': {'room_id': roomId},
            },
        },
      );
    } catch (e) {
      OrexLog.d('Voip', 'notify rejected failed room=$roomId', e);
    }
  }

  final Client client;
  late final VoIP voip;

  StreamSubscription? _syncSub;
  StreamSubscription<ToDeviceEvent>? _toDeviceSub;
  final StreamController<Room> _incoming = StreamController<Room>.broadcast();
  final StreamController<String> _dismiss =
      StreamController<String>.broadcast();

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

  /// Текущий звонок, в который мы вошли (опубликовали своё членство).
  GroupCallSession? active;

  bool get inCall => active != null;

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
    if (event.redacted || event.senderId == client.userID) return null;
    if (!_groupCallMemberEventLooksActive(event)) return null;
    return event.senderId;
  }

  static const Duration _timelineCallFallbackTtl = Duration(seconds: 90);

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
      if (!_roomHasCall(room)) {
        _scheduleRoomCallEnded(room.id);
        continue;
      }
      _cancelRoomCallEnded(room.id);
      _considerIncomingRoom(room, markExistingAsSeen: markExistingAsSeen);
    }
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

  void _considerIncomingRoom(Room room, {required bool markExistingAsSeen}) {
    final myId = client.userID;
    if (active != null && active!.room.id == room.id) return; // я в звонке
    if (_shown.contains(room.id) || _suppress.contains(room.id)) return;
    final others = _callMembers(room).where((id) => id != myId).toSet();
    if (others.isEmpty) return; // только моё членство — не входящий
    if (!_shouldRingForRoom(room)) {
      // В группах, каналах и чатах супергруппы звонок — это голосовой канал:
      // не показываем системный входящий вызов всем участникам. Комната всё
      // равно помечается активной, поэтому UI покажет «Идёт звонок · Войти».
      _suppress.add(room.id);
      return;
    }
    if (markExistingAsSeen) {
      _suppress.add(
        room.id,
      ); // активен на старте → не звоним (покажет панель «войти»)
      return;
    }
    OrexLog.d(
      'Voip',
      'incoming direct call room=${room.id} from=${others.join(',')}',
    );
    _shown.add(room.id);
    _incoming.add(room);
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
    // Снимать suppress можно только когда звонок реально закончился. Если мы
    // вышли, а собеседник остался внутри, это всё ещё тот же звонок — не нужно
    // превращать его обратно во входящий вызов.
    _suppress.remove(roomId);
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
  void markLeft(String roomId) {
    _cancelRoomCallEnded(roomId);
    _suppress.add(roomId);
    if (_shown.remove(roomId)) _dismiss.add(roomId);
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
    final handledContent = <String, dynamic>{
      'room_id': roomId,
      'call_id': callId,
    };
    final currentDeviceId = client.deviceID?.trim();
    if (currentDeviceId != null && currentDeviceId.isNotEmpty) {
      handledContent['origin_device_id'] = currentDeviceId;
    }
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
    } catch (e) {
      OrexLog.d(
        'Voip',
        'mark call handled failed room=$roomId call=$callId',
        e,
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
  Future<GroupCallSession> enterCall(String roomId, {bool ring = false}) async {
    final room = client.getRoomById(roomId);
    if (room == null) {
      throw StateError('Комната $roomId не найдена');
    }

    final backend = LiveKitBackend(
      livekitServiceUrl: OrexConfig.jwtServiceUri.toString(),
      livekitAlias: roomId,
      // Orex does not provide a MatrixRTC/LiveKit media key provider yet, so
      // calls must not be advertised as media-E2EE capable.
      e2eeEnabled: false,
    );

    final gc = await voip.fetchOrCreateGroupCall(
      roomId,
      room,
      backend,
      'm.call',
      'm.room',
      preShareKey: false,
    );

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
      await _sendPersonalCallRing(room);
    }
    return gc;
  }

  Future<void> _sendPersonalCallRing(Room room) async {
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
      await room.sendRtcNotification(
        type: RtcNotificationType.ring,
        userIds: targets.toList(growable: false),
        lifetime: const Duration(seconds: 45),
      );
      OrexLog.d(
        'Voip',
        'RTC ring sent room=${room.id} targets=${targets.length}',
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
      markLeft(gc.room.id); // не «перезванивать» по этому же звонку
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
    _syncSub?.cancel();
    _toDeviceSub?.cancel();
    _staleMembershipCleanupTimer?.cancel();
    for (final timer in _rejectedCleanupTimers.values) {
      timer.cancel();
    }
    _rejectedCleanupTimers.clear();
    for (final timer in _endedDebounceTimers.values) {
      timer.cancel();
    }
    _endedDebounceTimers.clear();
    _incoming.close();
    _dismiss.close();
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

  /// E2EE звонка пока выключено — ключей не предоставляем.
  @override
  EncryptionKeyProvider? get keyProvider => null;

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

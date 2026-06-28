import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart';
// Типы делегата (MediaDevices/RTCPeerConnection) берём из webrtc_interface —
// именно их ожидает WebRTCDelegate. У flutter_webrtc есть устаревший
// одноимённый MediaDevices, поэтому flutter_webrtc импортируем под префиксом.
import 'package:webrtc_interface/webrtc_interface.dart';

import 'config.dart';

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
          Future.delayed(
              const Duration(seconds: 60), () => _rejected.remove(roomId));
        }
      }
    });
    _scan(); // первичное (по кэшу) — звонки, активные на старте, помечаем виденными
    // Грейс 3 c: всё, что активно сразу после запуска/перезагрузки (включая
    // звонок, из которого мы только что вышли), НЕ звонит — покажется панелью.
    Future.delayed(const Duration(seconds: 3), () => _ready = true);
    // Чистим СВОИ зависшие членства (после перезагрузки/закрытия вкладки во
    // время звонка) — иначе другой аккаунт видит нас «в звонке» (фантом).
    Future.delayed(
        const Duration(seconds: 4), _cleanupOwnStaleMemberships);
  }

  /// Удаляем своё членство в звонках, в которых мы на самом деле не находимся.
  Future<void> _cleanupOwnStaleMemberships() async {
    final myId = client.userID;
    for (final room in client.rooms) {
      if (!_callMembers(room).contains(myId)) continue;
      if (active != null && active!.room.id == room.id) continue; // реально в звонке
      try {
        await room.removeFamedlyCallMemberEvent(room.id, voip);
        debugPrint('Removed phantom call membership in ${room.id}');
      } catch (e) {
        debugPrint('cleanup stale membership failed: $e');
      }
    }
  }

  static const _handledEventType = 'com.orex.call.handled';
  static const _rejectedEventType = 'com.orex.call.rejected';

  /// roomId → когда собеседник отклонил звонок (для текста итогового сообщения).
  final Map<String, DateTime> _rejected = {};

  /// Собеседник отклонил звонок в этой комнате (недавно).
  bool wasRejected(String roomId) => _rejected.containsKey(roomId);

  void clearRejected(String roomId) => _rejected.remove(roomId);

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
      debugPrint('notifyRejected failed: $e');
    }
  }

  final Client client;
  late final VoIP voip;

  StreamSubscription? _syncSub;
  StreamSubscription<ToDeviceEvent>? _toDeviceSub;
  final StreamController<Room> _incoming = StreamController<Room>.broadcast();
  final StreamController<String> _dismiss =
      StreamController<String>.broadcast();

  bool _ready = false;
  final Set<String> _shown = <String>{}; // по этим комнатам сейчас показан входящий
  final Set<String> _suppress =
      <String>{}; // не звонить: вышли / было при старте / обработано

  /// Входящие звонки: roomId комнаты, где идёт звонок, в который мы не вошли.
  Stream<Room> get onIncomingCall => _incoming.stream;

  /// Комнаты, по которым надо ЗАКРЫТЬ открытый входящий (звонок кончился или
  /// обработан на другом устройстве).
  Stream<String> get onDismissIncoming => _dismiss.stream;

  /// Текущий звонок, в который мы вошли (опубликовали своё членство).
  GroupCallSession? active;

  bool get inCall => active != null;

  bool _roomHasCall(Room room) =>
      room.hasActiveGroupCall(voip, ignoreDirectChats: false);

  Iterable<String> _callMembers(Room room) => room
      .getCallMembershipsFromRoom(voip)
      .values
      .expand((e) => e)
      .where((m) => !m.isExpired)
      .map((m) => m.userId);

  /// Сканируем все комнаты на активные звонки.
  void _scan() {
    final firstScan = !_ready;
    final myId = client.userID;
    for (final room in client.rooms) {
      if (!_roomHasCall(room)) {
        // Звонок закончился — сбрасываем и закрываем открытый входящий.
        final wasTracked = _shown.remove(room.id) | _suppress.remove(room.id);
        if (wasTracked) _dismiss.add(room.id);
        continue;
      }
      if (active != null && active!.room.id == room.id) continue; // я в звонке
      if (_shown.contains(room.id) || _suppress.contains(room.id)) continue;
      final others = _callMembers(room).where((id) => id != myId);
      if (others.isEmpty) continue; // только моё членство — не входящий
      if (!room.isDirectChat) {
        // В группах, каналах и чатах супергруппы звонок — это голосовой канал:
        // не показываем системный входящий вызов всем участникам. Комната всё
        // равно помечается активной, поэтому UI покажет «Идёт звонок · Войти».
        _suppress.add(room.id);
        continue;
      }
      if (firstScan) {
        _suppress.add(room.id); // активен на старте → не звоним (покажет панель «войти»)
        continue;
      }
      _shown.add(room.id);
      _incoming.add(room);
    }
  }

  /// Я вышел из звонка — не «перезванивать» по тому же продолжающемуся звонку.
  void markLeft(String roomId) {
    _suppress.add(roomId);
    _shown.remove(roomId);
  }

  /// Пометить обработанным (принят/отклонён) и сообщить другим своим устройствам.
  Future<void> markCallHandled(String roomId, String callId) async {
    _suppress.add(roomId);
    _shown.remove(roomId);
    try {
      await client.sendToDevice(
        _handledEventType,
        client.generateUniqueTransactionId(),
        {
          client.userID!: {
            '*': {'room_id': roomId, 'call_id': callId},
          },
        },
      );
    } catch (e) {
      debugPrint('markCallHandled failed: $e');
    }
  }

  /// Войти в звонок комнаты: публикуем своё членство (сигналинг) и возвращаем
  /// сессию. Медиа подключается отдельно (CallSession через livekit_client).
  Future<GroupCallSession> enterCall(String roomId) async {
    final room = client.getRoomById(roomId);
    if (room == null) {
      throw StateError('Комната $roomId не найдена');
    }

    final backend = LiveKitBackend(
      livekitServiceUrl: OrexConfig.jwtServiceUri.toString(),
      livekitAlias: roomId,
      e2eeEnabled: true, 
    );

    final gc = await voip.fetchOrCreateGroupCall(
      roomId, 
      room,
      backend,
      'm.call',
      'm.room',
      preShareKey: false, 
    );

    await gc.enter(); 
    active = gc;
    notifyListeners();
    return gc;
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
        debugPrint('VoipService.leaveCurrent failed: $e');
      }
      // Подстраховка: гарантированно убираем своё членство (если leave() не
      // справился) — иначе остаёмся «фантомом» в звонке для остальных.
      try {
        await gc.room.removeFamedlyCallMemberEvent(gc.groupCallId, voip);
      } catch (_) {}
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
  ]) =>
      rtc.createPeerConnection(configuration, constraints);

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
  Future<void> handleNewGroupCall(GroupCallSession groupCall) async {}

  @override
  Future<void> handleGroupCallEnded(GroupCallSession groupCall) async {}
}

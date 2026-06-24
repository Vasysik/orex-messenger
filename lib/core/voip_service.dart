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
/// E2EE самого звонка (sframe-ключи) пока ВЫКЛЮЧЕН (`e2eeEnabled: false` +
/// `keyProvider == null`) — это следующий шаг к полному интеропу с Element Call.
class VoipService extends ChangeNotifier {
  VoipService(this.client) {
    voip = VoIP(client, _OrexCallDelegate(this));
    // onIncomingGroupCall — обычный (не broadcast) контроллер, поэтому слушаем
    // его ровно один раз здесь и ретранслируем наружу через broadcast-поток.
    _incomingSub = voip.onIncomingGroupCall.stream.listen(_onIncoming);
  }

  final Client client;
  late final VoIP voip;

  StreamSubscription<GroupCallSession>? _incomingSub;
  final StreamController<GroupCallSession> _incoming =
      StreamController<GroupCallSession>.broadcast();

  /// Входящие групповые звонки (кто-то опубликовал членство в комнате, где нас
  /// ещё нет в звонке). UI слушает это, чтобы показать экран входящего.
  Stream<GroupCallSession> get onIncomingCall => _incoming.stream;

  /// Текущий звонок, в который мы вошли (опубликовали своё членство).
  GroupCallSession? active;

  bool get inCall => active != null;

  void _onIncoming(GroupCallSession gc) {
    // Не звоним сами себе: если мы уже в звонке в этой комнате — игнор.
    if (active != null && active!.room.id == gc.room.id) return;
    _incoming.add(gc);
  }

  /// Войти в звонок комнаты: публикуем своё членство (сигналинг) и возвращаем
  /// сессию. Медиа подключается отдельно (CallSession через livekit_client).
  Future<GroupCallSession> enterCall(String roomId) async {
    final room = client.getRoomById(roomId);
    if (room == null) {
      throw StateError('Комната $roomId не найдена');
    }

    final backend = LiveKitBackend(
      // Тот же lk-jwt-service, что мы отдаём livekit_client за токеном.
      livekitServiceUrl: OrexConfig.jwtService,
      // Алиас LiveKit-комнаты = matrix roomId (как делает Element Call).
      livekitAlias: roomId,
      e2eeEnabled: false,
    );

    final gc = await voip.fetchOrCreateGroupCall(
      roomId, // call_id = roomId → звонок на всю комнату
      room,
      backend,
      'm.call',
      'm.room',
      preShareKey: false, // E2EE звонка выключен — ключи не рассылаем
    );

    await gc.enter(); // публикует com.famedly.call.member
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
      try {
        await gc.leave();
      } catch (e) {
        debugPrint('VoipService.leaveCurrent failed: $e');
      }
    }
  }

  @override
  void dispose() {
    _incomingSub?.cancel();
    _incoming.close();
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

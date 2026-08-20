part of 'voip_service.dart';

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

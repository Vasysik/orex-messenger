import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart';

/// Звонки через LiveKit в стиле Element Call / MatrixRTC.
///
/// Поток (как развёрнуто на vasys.ru):
///   1. Берём у Matrix OpenID-токен:
///      POST /_matrix/client/v3/user/{userId}/openid/request_token  (тело {})
///   2. Отдаём его lk-jwt-service: POST https://jwt.vasys.ru/sfu/get
///      body: { room, openid_token: {access_token, matrix_server_name}, device_id }
///      -> { url: "wss://lk.vasys.ru", jwt: "<token>" }
///   3. Подключаемся к LiveKit-комнате этим JWT.
///
/// ПРИМЕЧАНИЕ: стандартный lk-jwt-service ждёт OpenID-токен, а не сырой
/// access_token. Если ваш сервис настроен иначе — поправьте [_requestSfu].
/// Здесь Room из livekit_client идёт под префиксом `lk.`, чтобы не конфликтовать
/// с Matrix Room.
class CallService extends ChangeNotifier {
  CallService({
    required this.client,
    required this.jwtServiceUrl, // https://jwt.vasys.ru
  });

  final Client client;
  final Uri jwtServiceUrl;

  lk.Room? _room; // LiveKit Room
  lk.Room? get room => _room;
  bool get inCall => _room != null;

  /// Начать/присоединиться к звонку в данной Matrix-комнате.
  Future<void> joinCall(String matrixRoomId, {required bool video}) async {
    final creds = await _getLiveKitCredentials(matrixRoomId);

    final lkRoom = lk.Room(
      roomOptions: const lk.RoomOptions(adaptiveStream: true, dynacast: true),
    );

    await lkRoom.prepareConnection(creds.url, creds.jwt);
    await lkRoom.connect(creds.url, creds.jwt);
    await lkRoom.localParticipant?.setMicrophoneEnabled(true);
    if (video) {
      await lkRoom.localParticipant?.setCameraEnabled(true);
    }

    _room = lkRoom;
    lkRoom.addListener(notifyListeners);
    notifyListeners();
  }

  Future<void> hangUp() async {
    await _room?.disconnect();
    await _room?.dispose();
    _room = null;
    notifyListeners();
  }

  Future<void> toggleMic() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    await lp.setMicrophoneEnabled(!lp.isMicrophoneEnabled());
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    await lp.setCameraEnabled(!lp.isCameraEnabled());
    notifyListeners();
  }

  // --- Низкоуровневый протокол ---

  Future<_LkCreds> _getLiveKitCredentials(String matrixRoomId) async {
    final userId = client.userID!;
    final serverName = userId.split(':').last;

    // 1) OpenID-токен у homeserver. Сырой запрос — не зависим от версии SDK.
    final openIdResp = await client.request(
      RequestType.POST,
      '/client/v3/user/$userId/openid/request_token',
      data: <String, dynamic>{},
    );
    final accessToken = openIdResp['access_token'] as String;

    // 2) Запрос к lk-jwt-service.
    return _requestSfu(
      matrixRoomId: matrixRoomId,
      accessToken: accessToken,
      matrixServerName: serverName,
      deviceId: client.deviceID ?? '',
    );
  }

  Future<_LkCreds> _requestSfu({
    required String matrixRoomId,
    required String accessToken,
    required String matrixServerName,
    required String deviceId,
  }) async {
    final resp = await http.post(
      jwtServiceUrl.replace(path: '/sfu/get'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'room': matrixRoomId,
        'openid_token': {
          'access_token': accessToken,
          'matrix_server_name': matrixServerName,
        },
        'device_id': deviceId,
      }),
    );

    if (resp.statusCode != 200) {
      throw Exception('lk-jwt-service ${resp.statusCode}: ${resp.body}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return _LkCreds(url: json['url'] as String, jwt: json['jwt'] as String);
  }
}

class _LkCreds {
  _LkCreds({required this.url, required this.jwt});
  final String url; // wss://lk.vasys.ru
  final String jwt;
}

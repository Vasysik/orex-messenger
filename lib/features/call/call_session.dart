import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart';

import '../../core/config.dart';

enum CallStatus { connecting, connected, failed, ended }

/// Нативный звонок на стеке Element Call (MatrixRTC): мы используем ВАШ
/// LiveKit + lk-jwt-service и рисуем СВОЙ интерфейс — без встраивания
/// call.element.io.
///
/// Два клиента Orex, нажавшие звонок в одной Matrix-комнате, получают от
/// lk-jwt-service одну и ту же LiveKit-комнату (она выводится из roomId),
/// поэтому встречаются в одном звонке.
class CallSession extends ChangeNotifier {
  CallSession({required this.client, required this.matrixRoomId});

  final Client client;
  final String matrixRoomId;

  CallStatus status = CallStatus.connecting;
  String? error;
  lk.Room? _room;
  lk.Room? get room => _room;

  bool get micOn => _room?.localParticipant?.isMicrophoneEnabled() ?? false;
  bool get camOn => _room?.localParticipant?.isCameraEnabled() ?? false;

  List<lk.Participant> get participants => [
        if (_room?.localParticipant != null) _room!.localParticipant!,
        ...?_room?.remoteParticipants.values,
      ];

  Future<void> connect({required bool video}) async {
    status = CallStatus.connecting;
    error = null;
    notifyListeners();
    try {
      final creds = await _fetchCredentials();
      final room = lk.Room(
        roomOptions: const lk.RoomOptions(adaptiveStream: true, dynacast: true),
      );
      await room.prepareConnection(creds.url, creds.jwt);
      await room.connect(creds.url, creds.jwt);
      await room.localParticipant?.setMicrophoneEnabled(true);
      if (video) await room.localParticipant?.setCameraEnabled(true);

      _room = room;
      room.addListener(_onRoom);
      status = CallStatus.connected;
      notifyListeners();
    } catch (e) {
      error = '$e';
      status = CallStatus.failed;
      notifyListeners();
    }
  }

  void _onRoom() => notifyListeners();

  Future<void> toggleMic() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    await lp.setMicrophoneEnabled(!lp.isMicrophoneEnabled());
    notifyListeners();
  }

  Future<void> toggleCam() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    await lp.setCameraEnabled(!lp.isCameraEnabled());
    notifyListeners();
  }

  Future<void> hangUp() async {
    status = CallStatus.ended;
    await _room?.disconnect();
    await _room?.dispose();
    _room = null;
    notifyListeners();
  }

  // OpenID-токен Matrix -> lk-jwt-service /sfu/get -> {url, jwt}
  Future<_Creds> _fetchCredentials() async {
    final userId = client.userID!;

    final openId = await client.requestOpenIdToken(userId, <String, Object?>{});

    final resp = await http.post(
      Uri.parse(OrexConfig.jwtService).replace(path: '/sfu/get'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'room': matrixRoomId,
        'openid_token': {
          'access_token': openId.accessToken,
          'token_type': openId.tokenType,
          'matrix_server_name': openId.matrixServerName,
        },
        'device_id': client.deviceID ?? '',
      }),
    );
    if (resp.statusCode != 200) {
      throw Exception('lk-jwt-service ${resp.statusCode}: ${resp.body}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return _Creds(url: json['url'] as String, jwt: json['jwt'] as String);
  }

  @override
  void dispose() {
    _room?.removeListener(_onRoom);
    _room?.dispose();
    super.dispose();
  }
}

class _Creds {
  _Creds({required this.url, required this.jwt});
  final String url;
  final String jwt;
}

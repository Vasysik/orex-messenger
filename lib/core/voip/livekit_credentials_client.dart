import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import '../config/orex_config.dart';
import 'livekit_token_policy.dart';

typedef OrexHttpPost =
    Future<http.Response> Function(
      Uri url, {
      Map<String, String>? headers,
      Object? body,
      Encoding? encoding,
    });

final class OrexLiveKitCredentials {
  const OrexLiveKitCredentials({required this.url, required this.jwt});

  final String url;
  final String jwt;
}

final class OrexLiveKitCredentialsClient {
  const OrexLiveKitCredentialsClient({this.post});

  final OrexHttpPost? post;

  Future<OrexLiveKitCredentials> fetch({
    required Client client,
    required String matrixRoomId,
    required bool canPublishMedia,
    required bool listenOnly,
  }) async {
    final userId = client.userID!;
    final openId = await client.requestOpenIdToken(userId, <String, Object?>{});
    final httpPost = post ?? http.post;

    final response = await httpPost(
      OrexConfig.jwtServiceUri.replace(path: '/sfu/get'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'room': matrixRoomId,
        'openid_token': {
          'access_token': openId.accessToken,
          'token_type': openId.tokenType,
          'matrix_server_name': openId.matrixServerName,
        },
        'device_id': client.deviceID ?? '',
        'requested_livekit_grants': OrexLiveKitTokenPolicy.requestedGrants(
          canPublishMedia: canPublishMedia,
          listenOnly: listenOnly,
        ),
      }),
    ).timeout(const Duration(seconds: 12));

    return parseResponse(
      statusCode: response.statusCode,
      body: response.body,
      canPublishMedia: canPublishMedia,
    );
  }

  static OrexLiveKitCredentials parseResponse({
    required int statusCode,
    required String body,
    required bool canPublishMedia,
  }) {
    if (statusCode != 200) {
      throw Exception('lk-jwt-service $statusCode');
    }

    final json = jsonDecode(body) as Map<String, dynamic>;
    final url = json['url'] as String?;
    final jwt = json['jwt'] as String?;
    if (url == null || jwt == null || jwt.isEmpty) {
      throw StateError('lk-jwt-service вернул неполные credentials');
    }
    OrexLiveKitTokenPolicy.assertCompatibleWithRequestedGrants(
      jwt: jwt,
      canPublishMedia: canPublishMedia,
    );
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'wss' && uri.scheme != 'https')) {
      throw StateError('LiveKit URL должен быть wss:// или https://');
    }
    return OrexLiveKitCredentials(url: url, jwt: jwt);
  }
}

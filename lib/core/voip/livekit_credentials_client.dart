import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import '../config/orex_config.dart';

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
      body: jsonEncode(
        legacySfuGetRequestBody(
          matrixRoomId: matrixRoomId,
          accessToken: openId.accessToken,
          tokenType: openId.tokenType,
          matrixServerName: openId.matrixServerName,
          deviceId: client.deviceID ?? '',
        ),
      ),
    ).timeout(const Duration(seconds: 12));

    return parseResponse(statusCode: response.statusCode, body: response.body);
  }

  static Map<String, Object?> legacySfuGetRequestBody({
    required String matrixRoomId,
    required String accessToken,
    required String tokenType,
    required String matrixServerName,
    required String deviceId,
  }) {
    return {
      'room': matrixRoomId,
      'openid_token': {
        'access_token': accessToken,
        'token_type': tokenType,
        'matrix_server_name': matrixServerName,
      },
      'device_id': deviceId,
    };
  }

  static String safeErrorDetails(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map) return '';
      final details = <String>[];
      final errcode = json['errcode'];
      final requestId = json['request_id'] ?? json['requestId'];
      if (errcode is String && errcode.trim().isNotEmpty) {
        details.add('errcode=${errcode.trim()}');
      }
      if (requestId is String && requestId.trim().isNotEmpty) {
        details.add('request_id=${requestId.trim()}');
      }
      return details.isEmpty ? '' : ' (${details.join(', ')})';
    } catch (_) {
      return '';
    }
  }

  static OrexLiveKitCredentials parseResponse({
    required int statusCode,
    required String body,
  }) {
    if (statusCode != 200) {
      throw Exception('lk-jwt-service $statusCode${safeErrorDetails(body)}');
    }

    final json = jsonDecode(body) as Map<String, dynamic>;
    final url = json['url'] as String?;
    final jwt = json['jwt'] as String?;
    if (url == null || jwt == null || jwt.isEmpty) {
      throw StateError('lk-jwt-service вернул неполные credentials');
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'wss' && uri.scheme != 'https')) {
      throw StateError('LiveKit URL должен быть wss:// или https://');
    }
    return OrexLiveKitCredentials(url: url, jwt: jwt);
  }
}

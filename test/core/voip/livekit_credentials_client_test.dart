import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/livekit_credentials_client.dart';

void main() {
  group('OrexLiveKitCredentialsClient', () {
    test('parses valid credentials response', () {
      final credentials = OrexLiveKitCredentialsClient.parseResponse(
        statusCode: 200,
        body: jsonEncode({
          'url': 'wss://livekit.example.org',
          'jwt': _jwt(canPublish: false),
        }),
      );

      expect(credentials.url, 'wss://livekit.example.org');
      expect(credentials.jwt, isNotEmpty);
    });

    test('builds upstream-compatible legacy sfu request body', () {
      final body = OrexLiveKitCredentialsClient.legacySfuGetRequestBody(
        matrixRoomId: '!voice:example.org',
        accessToken: 'openid-token',
        tokenType: 'Bearer',
        matrixServerName: 'example.org',
        deviceId: 'DEVICE',
      );

      expect(body.keys, containsAll(['room', 'openid_token', 'device_id']));
      expect(body, isNot(contains('requested_livekit_grants')));
      expect(body['openid_token'], {
        'access_token': 'openid-token',
        'token_type': 'Bearer',
        'matrix_server_name': 'example.org',
      });
    });

    test('rejects non-success status without leaking response body', () {
      expect(
        () => OrexLiveKitCredentialsClient.parseResponse(
          statusCode: 500,
          body: '{"secret":"diagnostic"}',
        ),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            isNot(contains('diagnostic')),
          ),
        ),
      );
    });

    test('keeps safe non-success diagnostics', () {
      expect(
        () => OrexLiveKitCredentialsClient.parseResponse(
          statusCode: 400,
          body: jsonEncode({
            'errcode': 'M_BAD_JSON',
            'request_id': 'req-123',
            'secret': 'diagnostic',
          }),
        ),
        throwsA(
          isA<Exception>()
              .having(
                (error) => error.toString(),
                'message',
                contains('errcode=M_BAD_JSON'),
              )
              .having(
                (error) => error.toString(),
                'message',
                contains('request_id=req-123'),
              )
              .having(
                (error) => error.toString(),
                'message',
                isNot(contains('diagnostic')),
              ),
        ),
      );
    });

    test('rejects missing credentials fields', () {
      expect(
        () => OrexLiveKitCredentialsClient.parseResponse(
          statusCode: 200,
          body: jsonEncode({'url': 'wss://livekit.example.org'}),
        ),
        throwsStateError,
      );
    });

    test('rejects LiveKit host outside explicit allowlist', () {
      expect(
        () => OrexLiveKitCredentialsClient.parseResponse(
          statusCode: 200,
          body: jsonEncode({
            'url': 'wss://evil.example.org',
            'jwt': _jwt(canPublish: false),
          }),
          allowedHosts: const {'livekit.example.org'},
        ),
        throwsStateError,
      );
    });

    test('rejects credential-bearing LiveKit URL query strings', () {
      expect(
        () => OrexLiveKitCredentialsClient.parseResponse(
          statusCode: 200,
          body: jsonEncode({
            'url': 'wss://livekit.example.org?token=must-not-be-here',
            'jwt': _jwt(canPublish: false),
          }),
        ),
        throwsStateError,
      );
    });

    test('rejects insecure or malformed LiveKit URLs', () {
      expect(
        () => OrexLiveKitCredentialsClient.parseResponse(
          statusCode: 200,
          body: jsonEncode({
            'url': 'http://livekit.example.org',
            'jwt': _jwt(canPublish: false),
          }),
        ),
        throwsStateError,
      );
    });
  });
}

String _jwt({required bool canPublish}) {
  final header = _segment({'alg': 'none', 'typ': 'JWT'});
  final payload = _segment({
    'video': {'roomJoin': true, 'canPublish': canPublish},
  });
  return '$header.$payload.';
}

String _segment(Map<String, Object?> json) {
  return base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
}

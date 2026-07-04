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
        canPublishMedia: false,
      );

      expect(credentials.url, 'wss://livekit.example.org');
      expect(credentials.jwt, isNotEmpty);
    });

    test('rejects non-success status without leaking response body', () {
      expect(
        () => OrexLiveKitCredentialsClient.parseResponse(
          statusCode: 500,
          body: '{"secret":"diagnostic"}',
          canPublishMedia: true,
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

    test('rejects missing credentials fields', () {
      expect(
        () => OrexLiveKitCredentialsClient.parseResponse(
          statusCode: 200,
          body: jsonEncode({'url': 'wss://livekit.example.org'}),
          canPublishMedia: true,
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
          canPublishMedia: false,
        ),
        throwsStateError,
      );
    });

    test('rejects publish-capable token for listen-only request', () {
      expect(
        () => OrexLiveKitCredentialsClient.parseResponse(
          statusCode: 200,
          body: jsonEncode({
            'url': 'wss://livekit.example.org',
            'jwt': _jwt(canPublish: true),
          }),
          canPublishMedia: false,
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

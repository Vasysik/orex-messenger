import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/matrix/matrix_service.dart';

void main() {
  group('MAS metadata', () {
    test('accepts device authorization endpoints below configured /auth', () {
      final capabilities = orexParseMasCapabilities(
        <String, Object?>{
          'issuer': 'https://vasys.ru/auth',
          'token_endpoint': 'https://vasys.ru/auth/oauth2/token',
          'device_authorization_endpoint':
              'https://vasys.ru/auth/oauth2/device',
          'grant_types_supported': <String>[
            'authorization_code',
            'urn:ietf:params:oauth:grant-type:device_code',
          ],
        },
        configuredBase: Uri.parse('https://vasys.ru/auth'),
      );

      expect(capabilities.supportsDeviceAuthorization, isTrue);
      expect(
        capabilities.deviceAuthorizationEndpoint,
        Uri.parse('https://vasys.ru/auth/oauth2/device'),
      );
    });

    test('rejects endpoints outside configured /auth', () {
      expect(
        () => orexParseMasCapabilities(
          <String, Object?>{
            'issuer': 'https://vasys.ru/auth',
            'token_endpoint': 'https://evil.example/oauth2/token',
          },
          configuredBase: Uri.parse('https://vasys.ru/auth'),
        ),
        throwsA(isA<OrexAuthProtocolException>()),
      );
    });

    test('does not confuse a similar path prefix with /auth', () {
      expect(
        orexMasEndpointMatches(
          Uri.parse('https://vasys.ru/auth-evil/oauth2/token'),
          Uri.parse('https://vasys.ru/auth'),
        ),
        isFalse,
      );
    });
  });

  test('parses a device authorization bootstrap response', () {
    final createdAt = DateTime.utc(2026, 7, 22, 16);
    final session = orexParseDeviceAuthorizationSession(
      <String, Object?>{
        'device_code': 'secret-device-code',
        'user_code': 'OREX-1234',
        'verification_uri': 'https://vasys.ru/auth/link',
        'verification_uri_complete':
            'https://vasys.ru/auth/link?code=OREX-1234',
        'expires_in': 600,
        'interval': 5,
      },
      deviceId: 'OREXDEVICE',
      now: createdAt,
      configuredBase: Uri.parse('https://vasys.ru/auth'),
    );

    expect(session.userCode, 'OREX-1234');
    expect(
      session.qrUri,
      Uri.parse('https://vasys.ru/auth/link?code=OREX-1234'),
    );
    expect(session.expiresIn, const Duration(minutes: 10));
    expect(session.interval, const Duration(seconds: 5));
    expect(session.createdAt, createdAt);
  });

  test('rejects a QR confirmation URL outside configured MAS', () {
    expect(
      () => orexParseDeviceAuthorizationSession(
        <String, Object?>{
          'device_code': 'secret-device-code',
          'user_code': 'OREX-1234',
          'verification_uri': 'https://evil.example/link',
          'expires_in': 600,
        },
        deviceId: 'OREXDEVICE',
        now: DateTime.utc(2026, 7, 22, 16),
        configuredBase: Uri.parse('https://vasys.ru/auth'),
      ),
      throwsA(isA<OrexAuthProtocolException>()),
    );
  });
}

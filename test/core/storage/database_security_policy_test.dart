import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/config/orex_config.dart';
import 'package:orex_messenger/core/storage/database_security_policy.dart';

void main() {
  group('OrexDatabaseSecurityPolicy', () {
    test('allows encrypted cache in production', () {
      expect(
        () => OrexDatabaseSecurityPolicy.validateDesktopCache(
          environment: OrexEnvironment.production,
          encryptedAtRest: true,
          allowInsecureDesktopCache: false,
          platformName: 'windows',
        ),
        returnsNormally,
      );
    });

    test('rejects unencrypted desktop cache in production by default', () {
      expect(
        () => OrexDatabaseSecurityPolicy.validateDesktopCache(
          environment: OrexEnvironment.production,
          encryptedAtRest: false,
          allowInsecureDesktopCache: false,
          platformName: 'windows',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('OREX_ALLOW_INSECURE_DESKTOP_CACHE'),
          ),
        ),
      );
    });

    test('allows explicit production dogfooding override', () {
      expect(
        () => OrexDatabaseSecurityPolicy.validateDesktopCache(
          environment: OrexEnvironment.production,
          encryptedAtRest: false,
          allowInsecureDesktopCache: true,
          platformName: 'windows',
        ),
        returnsNormally,
      );
    });

    test('allows unencrypted cache outside production', () {
      expect(
        () => OrexDatabaseSecurityPolicy.validateDesktopCache(
          environment: OrexEnvironment.dev,
          encryptedAtRest: false,
          allowInsecureDesktopCache: false,
          platformName: 'linux',
        ),
        returnsNormally,
      );
    });
  });
}

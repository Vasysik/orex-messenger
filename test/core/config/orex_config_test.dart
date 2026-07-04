import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/config/orex_config.dart';

void main() {
  group('OrexEnvironment', () {
    test('accepts production and short environment aliases', () {
      expect(OrexEnvironment.parse('production'), OrexEnvironment.production);
      expect(OrexEnvironment.parse('prod'), OrexEnvironment.production);
      expect(OrexEnvironment.parse('dev'), OrexEnvironment.dev);
      expect(OrexEnvironment.parse('development'), OrexEnvironment.dev);
      expect(OrexEnvironment.parse('stage'), OrexEnvironment.staging);
      expect(OrexEnvironment.parse('staging'), OrexEnvironment.staging);
    });

    test('rejects unknown environment names', () {
      expect(() => OrexEnvironment.parse('qa'), throwsA(isA<StateError>()));
    });
  });

  group('OrexRuntimeConfig', () {
    test('uses production endpoints by default', () {
      final config = OrexRuntimeConfig.fromDefines();

      expect(config.environment, OrexEnvironment.production);
      expect(config.homeserver, OrexRuntimeConfig.productionHomeserver);
      expect(config.jwtService, OrexRuntimeConfig.productionJwtService);
      expect(config.homeserverUri, Uri.parse('https://vasys.ru'));
      expect(config.jwtServiceUri, Uri.parse('https://jwt.vasys.ru'));
      expect(config.homeserverHost, 'vasys.ru');
      expect(config.allowInsecureDesktopCache, isFalse);
    });

    test('allows explicit production endpoint overrides', () {
      final config = OrexRuntimeConfig.fromDefines(
        homeserver: 'https://matrix.example.org',
        jwtService: 'https://jwt.example.org',
        elementCallBase: 'https://call.example.org',
      );

      expect(config.homeserverUri.host, 'matrix.example.org');
      expect(config.jwtServiceUri.host, 'jwt.example.org');
      expect(config.elementCallBaseUri.host, 'call.example.org');
    });

    test('requires explicit endpoints outside production', () {
      expect(
        () => OrexRuntimeConfig.fromDefines(environmentName: 'dev'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('OREX_HOMESERVER'),
          ),
        ),
      );
      expect(
        () => OrexRuntimeConfig.fromDefines(
          environmentName: 'staging',
          homeserver: 'https://matrix.staging.example.org',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('OREX_JWT_SERVICE'),
          ),
        ),
      );
    });

    test('accepts explicit dev endpoints', () {
      final config = OrexRuntimeConfig.fromDefines(
        environmentName: 'dev',
        homeserver: 'https://matrix.dev.example.org',
        jwtService: 'https://jwt.dev.example.org',
      );

      expect(config.environment, OrexEnvironment.dev);
      expect(config.homeserverUri.host, 'matrix.dev.example.org');
      expect(config.jwtServiceUri.host, 'jwt.dev.example.org');
    });

    test('accepts explicit insecure desktop cache escape hatch', () {
      final config = OrexRuntimeConfig.fromDefines(
        allowInsecureDesktopCache: true,
      );

      expect(config.allowInsecureDesktopCache, isTrue);
    });

    test('rejects non-https endpoints', () {
      expect(
        () => OrexRuntimeConfig.fromDefines(
          homeserver: 'http://matrix.example.org',
          jwtService: 'https://jwt.example.org',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('OREX_HOMESERVER'),
          ),
        ),
      );
    });
  });
}

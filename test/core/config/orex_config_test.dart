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

    test('accepts a standard Matrix push gateway endpoint', () {
      final config = OrexRuntimeConfig.fromDefines(
        pushGateway: 'https://push.example.org/_matrix/push/v1/notify',
      );

      expect(
        config.pushGatewayUri,
        Uri.parse('https://push.example.org/_matrix/push/v1/notify'),
      );
    });

    test('keeps push disabled when gateway is not configured', () {
      final config = OrexRuntimeConfig.fromDefines();

      expect(config.pushGatewayUri, isNull);
    });

    test('rejects non-standard push gateway paths', () {
      expect(
        () => OrexRuntimeConfig.fromDefines(
          pushGateway: 'https://push.example.org/custom/notify',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('/_matrix/push/v1/notify'),
          ),
        ),
      );
    });

    test('rejects insecure push gateway endpoints', () {
      expect(
        () => OrexRuntimeConfig.fromDefines(
          pushGateway: 'http://push.example.org/_matrix/push/v1/notify',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('absolute https:// URL'),
          ),
        ),
      );
    });

    test('rejects credentials embedded in push gateway URLs', () {
      expect(
        () => OrexRuntimeConfig.fromDefines(
          pushGateway:
              'https://user:secret@push.example.org/_matrix/push/v1/notify',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects push gateway query strings and fragments', () {
      for (final endpoint in <String>[
        'https://push.example.org/_matrix/push/v1/notify?tenant=orex',
        'https://push.example.org/_matrix/push/v1/notify#fragment',
      ]) {
        expect(
          () => OrexRuntimeConfig.fromDefines(pushGateway: endpoint),
          throwsA(isA<StateError>()),
        );
      }
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

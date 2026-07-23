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
      expect(config.authUrl, OrexRuntimeConfig.productionAuthUrl);
      expect(config.jwtService, OrexRuntimeConfig.productionJwtService);
      expect(config.homeserverUri, Uri.parse('https://vasys.ru'));
      expect(config.authUri, Uri.parse('https://vasys.ru/auth'));
      expect(
        config.masDiscoveryUri,
        Uri.parse(
          'https://vasys.ru/auth/.well-known/openid-configuration',
        ),
      );
      expect(config.jwtServiceUri, Uri.parse('https://jwt.vasys.ru'));
      expect(
        config.pushGatewayUri,
        Uri.parse('http://sygnal:5000/_matrix/push/v1/notify'),
      );
      expect(config.homeserverHost, 'vasys.ru');
      expect(config.allowInsecureDesktopCache, isFalse);
      expect(config.allowUnencryptedCalls, isFalse);
      expect(config.debugLogs, isFalse);
    });

    test('allows explicit production endpoint overrides', () {
      final config = OrexRuntimeConfig.fromDefines(
        homeserver: 'https://matrix.example.org',
        authUrl: 'https://id.example.org/auth',
        oidcClientId: 'orex-native',
        jwtService: 'https://jwt.example.org',
        elementCallBase: 'https://call.example.org',
      );

      expect(config.homeserverUri.host, 'matrix.example.org');
      expect(config.authUri.host, 'id.example.org');
      expect(config.oidcClientId, 'orex-native');
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
            contains('OREX_AUTH_URL'),
          ),
        ),
      );
      expect(
        () => OrexRuntimeConfig.fromDefines(
          environmentName: 'staging',
          homeserver: 'https://matrix.staging.example.org',
          authUrl: 'https://id.staging.example.org/auth',
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
        authUrl: 'https://id.dev.example.org/auth',
        jwtService: 'https://jwt.dev.example.org',
      );

      expect(config.environment, OrexEnvironment.dev);
      expect(config.homeserverUri.host, 'matrix.dev.example.org');
      expect(config.authUri.host, 'id.dev.example.org');
      expect(config.jwtServiceUri.host, 'jwt.dev.example.org');
    });

    test('rejects unsafe MAS endpoints', () {
      for (final endpoint in <String>[
        'http://vasys.ru/auth',
        'https://user:secret@vasys.ru/auth',
        'https://vasys.ru/auth?tenant=orex',
        'https://vasys.ru/auth#callback',
      ]) {
        expect(
          () => OrexRuntimeConfig.fromDefines(authUrl: endpoint),
          throwsA(isA<StateError>()),
        );
      }
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

    test('keeps push disabled outside production when gateway is omitted', () {
      final config = OrexRuntimeConfig.fromDefines(
        environmentName: 'dev',
        homeserver: 'https://matrix.dev.example.org',
        authUrl: 'https://id.dev.example.org/auth',
        jwtService: 'https://jwt.dev.example.org',
      );

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

    test('allows only the built-in internal HTTP gateway in production', () {
      final production = OrexRuntimeConfig.fromDefines();
      expect(
        production.pushGatewayUri,
        Uri.parse(OrexRuntimeConfig.productionPushGateway),
      );

      expect(
        () => OrexRuntimeConfig.fromDefines(
          environmentName: 'dev',
          homeserver: 'https://matrix.dev.example.org',
          authUrl: 'https://id.dev.example.org/auth',
          jwtService: 'https://jwt.dev.example.org',
          pushGateway: OrexRuntimeConfig.productionPushGateway,
        ),
        throwsA(isA<StateError>()),
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

    test('allows unencrypted calls only through an explicit escape hatch', () {
      final config = OrexRuntimeConfig.fromDefines(
        allowUnencryptedCalls: true,
      );

      expect(config.allowUnencryptedCalls, isTrue);
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

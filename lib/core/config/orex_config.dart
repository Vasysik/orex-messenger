enum OrexEnvironment {
  dev,
  staging,
  production;

  bool get isProduction => this == OrexEnvironment.production;

  static OrexEnvironment parse(String raw) {
    final value = raw.trim().toLowerCase();
    return switch (value) {
      '' || 'prod' || 'production' => OrexEnvironment.production,
      'dev' || 'development' => OrexEnvironment.dev,
      'stage' || 'staging' => OrexEnvironment.staging,
      _ => throw StateError(
        'OREX_ENV must be one of: dev, staging, production',
      ),
    };
  }
}

/// Runtime configuration resolved from dart-defines.
///
/// Production keeps the public Orex defaults. Dev/staging must provide explicit
/// endpoints, so a local or pre-release build cannot silently talk to prod.
class OrexRuntimeConfig {
  const OrexRuntimeConfig({
    required this.environment,
    required this.homeserver,
    required this.jwtService,
    required this.elementCallBase,
    required this.pushGateway,
    required this.requireVodozemac,
    required this.debugLogs,
    required this.allowInsecureDesktopCache,
  });

  static const productionHomeserver = 'https://vasys.ru';
  static const productionJwtService = 'https://jwt.vasys.ru';
  static const productionPushGateway =
      'http://sygnal:5000/_matrix/push/v1/notify';
  static const defaultElementCallBase = 'https://call.element.io';

  final OrexEnvironment environment;
  final String homeserver;
  final String jwtService;
  final String elementCallBase;
  final String pushGateway;
  final bool requireVodozemac;
  final bool debugLogs;
  final bool allowInsecureDesktopCache;

  factory OrexRuntimeConfig.fromDefines({
    String environmentName = 'production',
    String homeserver = '',
    String jwtService = '',
    String elementCallBase = '',
    String pushGateway = '',
    bool requireVodozemac = true,
    bool debugLogs = true,
    bool allowInsecureDesktopCache = false,
  }) {
    final environment = OrexEnvironment.parse(environmentName);
    final resolvedHomeserver = _definedOrDefault(
      homeserver,
      environment.isProduction ? productionHomeserver : '',
    );
    final resolvedJwtService = _definedOrDefault(
      jwtService,
      environment.isProduction ? productionJwtService : '',
    );
    final resolvedPushGateway = _definedOrDefault(
      pushGateway,
      environment.isProduction ? productionPushGateway : '',
    );

    return OrexRuntimeConfig(
      environment: environment,
      homeserver: resolvedHomeserver,
      jwtService: resolvedJwtService,
      elementCallBase: _definedOrDefault(
        elementCallBase,
        defaultElementCallBase,
      ),
      pushGateway: resolvedPushGateway,
      requireVodozemac: requireVodozemac,
      debugLogs: debugLogs,
      allowInsecureDesktopCache: allowInsecureDesktopCache,
    )..validateSecurity();
  }

  Uri get homeserverUri => _httpsUri(homeserver, 'OREX_HOMESERVER');

  Uri get jwtServiceUri => _httpsUri(jwtService, 'OREX_JWT_SERVICE');

  Uri get elementCallBaseUri =>
      _httpsUri(elementCallBase, 'OREX_ELEMENT_CALL_BASE');

  Uri? get pushGatewayUri {
    final value = pushGateway.trim();
    if (value.isEmpty) return null;
    final uri = Uri.parse(value);
    final isProductionInternalGateway =
        environment.isProduction && value == productionPushGateway;
    if (!isProductionInternalGateway &&
        (uri.scheme != 'https' || uri.host.isEmpty)) {
      throw StateError(
        'OREX_PUSH_GATEWAY must be an absolute https:// URL, except for the '
        'built-in production Docker endpoint',
      );
    }
    if (isProductionInternalGateway &&
        (uri.scheme != 'http' || uri.host != 'sygnal' || uri.port != 5000)) {
      throw StateError('Invalid built-in Orex production push gateway');
    }
    if (uri.userInfo.isNotEmpty ||
        uri.path != '/_matrix/push/v1/notify' ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw StateError(
        'OREX_PUSH_GATEWAY must be credential-free and use exactly '
        '/_matrix/push/v1/notify',
      );
    }
    return uri;
  }

  String get homeserverHost => homeserverUri.host;

  void validateSecurity() {
    if (!environment.isProduction) {
      _requireExplicitEndpoint(homeserver, 'OREX_HOMESERVER');
      _requireExplicitEndpoint(jwtService, 'OREX_JWT_SERVICE');
    }
    homeserverUri;
    jwtServiceUri;
    elementCallBaseUri;
    pushGatewayUri;
  }

  static String _definedOrDefault(String value, String fallback) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? fallback : trimmed;
  }

  static void _requireExplicitEndpoint(String value, String name) {
    if (value.trim().isEmpty) {
      throw StateError('$name is required when OREX_ENV is not production');
    }
  }

  static Uri _httpsUri(String value, String name) {
    final uri = Uri.parse(value);
    if (uri.scheme != 'https' || uri.host.isEmpty) {
      throw StateError('$name must be an absolute https:// URL');
    }
    return uri;
  }
}

/// Адреса и security-политика бэкенда Orex.
class OrexConfig {
  OrexConfig._();

  static const _environmentName = String.fromEnvironment(
    'OREX_ENV',
    defaultValue: 'production',
  );
  static const _homeserver = String.fromEnvironment('OREX_HOMESERVER');
  static const _jwtService = String.fromEnvironment('OREX_JWT_SERVICE');
  static const _elementCallBase = String.fromEnvironment(
    'OREX_ELEMENT_CALL_BASE',
  );
  static const _pushGateway = String.fromEnvironment('OREX_PUSH_GATEWAY');
  static const _requireVodozemac = bool.fromEnvironment(
    'OREX_REQUIRE_VODOZEMAC',
    defaultValue: true,
  );
  static const _debugLogs = bool.fromEnvironment(
    'OREX_DEBUG_LOGS',
    defaultValue: true,
  );
  static const _allowInsecureDesktopCache = bool.fromEnvironment(
    'OREX_ALLOW_INSECURE_DESKTOP_CACHE',
    defaultValue: false,
  );

  static final OrexRuntimeConfig current = OrexRuntimeConfig.fromDefines(
    environmentName: _environmentName,
    homeserver: _homeserver,
    jwtService: _jwtService,
    elementCallBase: _elementCallBase,
    pushGateway: _pushGateway,
    requireVodozemac: _requireVodozemac,
    debugLogs: _debugLogs,
    allowInsecureDesktopCache: _allowInsecureDesktopCache,
  );

  static OrexEnvironment get environment => current.environment;

  static String get homeserver => current.homeserver;

  static String get jwtService => current.jwtService;

  /// В продовом режиме приложение не должно стартовать без vodozemac:
  /// иначе приватные Matrix-комнаты могут внезапно стать фактически без E2EE.
  /// Для локальной отладки допускается временное значение false; в репозитории
  /// остаётся true.
  static bool get requireVodozemac => current.requireVodozemac;

  /// Подробные dev-логи продуктовых Matrix-flow: создание комнат, metadata,
  /// права каналов, preview супергрупп.
  ///
  /// Отключение для release/dev-build:
  /// `--dart-define=OREX_DEBUG_LOGS=false`.
  static bool get debugLogs => current.debugLogs;

  /// Escape hatch for Windows/Linux dogfooding while desktop SQLCipher is not
  /// wired yet. Production builds must keep this false unless the release is
  /// explicitly positioned as using an unencrypted local Matrix cache.
  static bool get allowInsecureDesktopCache =>
      current.allowInsecureDesktopCache;

  // LiveKit (wss://lk.vasys.ru) бэкенд возвращает сам через lk-jwt-service.

  /// Базовый адрес Element Call.
  ///
  /// По умолчанию используется публичный call.element.io. Для собственного
  /// Element Call поверх LiveKit + lk-jwt-service адрес задаётся отдельно,
  /// например 'https://call.vasys.ru'.
  static String get elementCallBase => current.elementCallBase;

  static Uri get homeserverUri => current.homeserverUri;
  static Uri get jwtServiceUri => current.jwtServiceUri;
  static Uri? get pushGatewayUri => current.pushGatewayUri;

  /// Хост homeserver без схемы (нужен Element Call для авторизации).
  static String get homeserverHost => current.homeserverHost;

  /// Быстрая проверка security-инвариантов конфигурации на старте.
  static void validateSecurity() => current.validateSecurity();
}

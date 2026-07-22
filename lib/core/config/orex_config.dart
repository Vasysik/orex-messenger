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
    required this.authUrl,
    required this.oidcClientId,
    required this.jwtService,
    required this.elementCallBase,
    required this.pushGateway,
    required this.requireVodozemac,
    required this.debugLogs,
    required this.allowInsecureDesktopCache,
    required this.allowUnencryptedCalls,
  });

  static const productionHomeserver = 'https://vasys.ru';
  static const productionAuthUrl = 'https://vasys.ru/auth';
  static const productionJwtService = 'https://jwt.vasys.ru';
  static const productionPushGateway =
      'http://sygnal:5000/_matrix/push/v1/notify';
  static const defaultElementCallBase = 'https://call.element.io';

  final OrexEnvironment environment;
  final String homeserver;
  final String authUrl;
  final String oidcClientId;
  final String jwtService;
  final String elementCallBase;
  final String pushGateway;
  final bool requireVodozemac;
  final bool debugLogs;
  final bool allowInsecureDesktopCache;
  final bool allowUnencryptedCalls;

  factory OrexRuntimeConfig.fromDefines({
    String environmentName = 'production',
    String homeserver = '',
    String authUrl = '',
    String oidcClientId = '',
    String jwtService = '',
    String elementCallBase = '',
    String pushGateway = '',
    bool requireVodozemac = true,
    bool debugLogs = false,
    bool allowInsecureDesktopCache = false,
    bool allowUnencryptedCalls = false,
  }) {
    final environment = OrexEnvironment.parse(environmentName);
    final resolvedHomeserver = _definedOrDefault(
      homeserver,
      environment.isProduction ? productionHomeserver : '',
    );
    final resolvedAuthUrl = _definedOrDefault(
      authUrl,
      environment.isProduction ? productionAuthUrl : '',
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
      authUrl: resolvedAuthUrl,
      oidcClientId: oidcClientId.trim(),
      jwtService: resolvedJwtService,
      elementCallBase: _definedOrDefault(
        elementCallBase,
        defaultElementCallBase,
      ),
      pushGateway: resolvedPushGateway,
      requireVodozemac: requireVodozemac,
      debugLogs: debugLogs,
      allowInsecureDesktopCache: allowInsecureDesktopCache,
      allowUnencryptedCalls: allowUnencryptedCalls,
    )..validateSecurity();
  }

  Uri get homeserverUri => _httpsUri(homeserver, 'OREX_HOMESERVER');

  Uri get authUri {
    final value = authUrl.trim();
    if (value.isEmpty) {
      throw StateError('OREX_AUTH_URL is required');
    }
    final uri = _httpsUri(value, 'OREX_AUTH_URL');
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw StateError(
        'OREX_AUTH_URL must not contain credentials, query or fragment',
      );
    }
    return uri;
  }

  Uri get masDiscoveryUri {
    final base = authUri;
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      path: '$basePath/.well-known/openid-configuration',
      query: null,
      fragment: null,
    );
  }

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
      _requireExplicitEndpoint(authUrl, 'OREX_AUTH_URL');
      _requireExplicitEndpoint(jwtService, 'OREX_JWT_SERVICE');
    }
    homeserverUri;
    authUri;
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
  static const _authUrl = String.fromEnvironment('OREX_AUTH_URL');
  static const _oidcClientId = String.fromEnvironment('OREX_OIDC_CLIENT_ID');
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
    defaultValue: false,
  );
  static const _allowInsecureDesktopCache = bool.fromEnvironment(
    'OREX_ALLOW_INSECURE_DESKTOP_CACHE',
    defaultValue: false,
  );
  static const _allowUnencryptedCalls = bool.fromEnvironment(
    'OREX_ALLOW_UNENCRYPTED_CALLS',
    defaultValue: false,
  );
  static const _liveKitAllowedHosts = String.fromEnvironment(
    'OREX_LIVEKIT_ALLOWED_HOSTS',
  );
  static const _updateBaseUrl = String.fromEnvironment(
    'OREX_UPDATE_BASE_URL',
    defaultValue: 'https://orex.vasys.ru/updates/',
  );
  static const _updateChannel = String.fromEnvironment(
    'OREX_UPDATE_CHANNEL',
    defaultValue: 'stable',
  );

  static final OrexRuntimeConfig current = OrexRuntimeConfig.fromDefines(
    environmentName: _environmentName,
    homeserver: _homeserver,
    authUrl: _authUrl,
    oidcClientId: _oidcClientId,
    jwtService: _jwtService,
    elementCallBase: _elementCallBase,
    pushGateway: _pushGateway,
    requireVodozemac: _requireVodozemac,
    debugLogs: _debugLogs,
    allowInsecureDesktopCache: _allowInsecureDesktopCache,
    allowUnencryptedCalls: _allowUnencryptedCalls,
  );

  static OrexEnvironment get environment => current.environment;

  static String get homeserver => current.homeserver;

  static String get authUrl => current.authUrl;

  static String get oidcClientId => current.oidcClientId;

  static String get jwtService => current.jwtService;

  /// В продовом режиме приложение не должно стартовать без vodozemac:
  /// иначе приватные Matrix-комнаты могут внезапно стать фактически без E2EE.
  /// Для локальной отладки допускается временное значение false; в репозитории
  /// остаётся true.
  static bool get requireVodozemac => current.requireVodozemac;

  /// Подробные dev-логи продуктовых Matrix-flow: создание комнат, metadata,
  /// права каналов, preview супергрупп.
  ///
  /// По умолчанию выключены. Для локальной или временной release-диагностики:
  /// `--dart-define=OREX_DEBUG_LOGS=true`.
  static bool get debugLogs => current.debugLogs;

  /// Escape hatch for Windows/Linux dogfooding while desktop SQLCipher is not
  /// wired yet. Production builds must keep this false unless the release is
  /// explicitly positioned as using an unencrypted local Matrix cache.
  static bool get allowInsecureDesktopCache =>
      current.allowInsecureDesktopCache;

  /// Security escape hatch for legacy/public Matrix rooms. Keep false in
  /// production: media keys sent through an unencrypted room are visible to
  /// the homeserver even though LiveKit frame encryption itself is enabled.
  static bool get allowUnencryptedCalls => current.allowUnencryptedCalls;

  static const _productionLiveKitHost = 'lk.vasys.ru';

  /// LiveKit endpoint returned by lk-jwt-service is accepted only from this
  /// explicit host set. Dev/staging must opt in with a dart-define.
  static Set<String> get liveKitAllowedHosts {
    final raw = _liveKitAllowedHosts.trim();
    if (raw.isEmpty) {
      if (!environment.isProduction) {
        throw StateError(
          'OREX_LIVEKIT_ALLOWED_HOSTS is required when OREX_ENV is not production',
        );
      }
      return const {_productionLiveKitHost};
    }

    final hosts = raw
        .split(',')
        .map((value) => value.trim().toLowerCase())
        .where((value) => value.isNotEmpty)
        .toSet();
    if (hosts.isEmpty ||
        hosts.any(
          (host) =>
              host.contains('/') ||
              host.contains(':') ||
              host.contains('@') ||
              Uri.tryParse('https://$host')?.host != host,
        )) {
      throw StateError(
        'OREX_LIVEKIT_ALLOWED_HOSTS must be a comma-separated host list',
      );
    }
    return Set.unmodifiable(hosts);
  }

  /// Базовый адрес Element Call.
  ///
  /// По умолчанию используется публичный call.element.io. Для собственного
  /// Element Call поверх LiveKit + lk-jwt-service адрес задаётся отдельно,
  /// например 'https://call.vasys.ru'.
  static String get elementCallBase => current.elementCallBase;

  /// Update feed selected at build time. Stable and debug installations use
  /// separate channels so both applications can be installed side by side.
  static String get updateChannel {
    final channel = _updateChannel.trim().toLowerCase();
    if (channel != 'stable' && channel != 'debug') {
      throw StateError('OREX_UPDATE_CHANNEL must be stable or debug');
    }
    return channel;
  }

  static bool get isDebugDistribution => updateChannel == 'debug';

  static String get appDisplayName =>
      isDebugDistribution ? 'Orex Messenger Debug' : 'Orex Messenger';

  static Uri get updateBaseUri {
    final uri = Uri.parse(_updateBaseUrl.trim());
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw StateError(
        'OREX_UPDATE_BASE_URL must be a credential-free absolute https:// URL',
      );
    }
    final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    return uri.replace(path: path);
  }

  static Uri get updateFeedUri =>
      updateBaseUri.resolve('$updateChannel/latest.json');

  static Uri get homeserverUri => current.homeserverUri;
  static Uri get authUri => current.authUri;
  static Uri get masDiscoveryUri => current.masDiscoveryUri;
  static Uri get jwtServiceUri => current.jwtServiceUri;
  static Uri? get pushGatewayUri => current.pushGatewayUri;

  /// Хост homeserver без схемы (нужен Element Call для авторизации).
  static String get homeserverHost => current.homeserverHost;

  /// Быстрая проверка security-инвариантов конфигурации на старте.
  static void validateSecurity() {
    current.validateSecurity();
    liveKitAllowedHosts;
    updateChannel;
    updateBaseUri;
  }
}

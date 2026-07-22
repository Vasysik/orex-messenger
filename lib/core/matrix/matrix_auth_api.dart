part of 'matrix_service.dart';

const _orexDeviceCodeGrant =
    'urn:ietf:params:oauth:grant-type:device_code';
const _orexMatrixApiScope = 'urn:matrix:client:api:*';
const _orexMatrixDeviceScopePrefix = 'urn:matrix:client:device:';
const _orexAuthRequestTimeout = Duration(seconds: 25);

/// Модель аутентификации для регистрации через токен приглашения (MSC3231).
class AuthenticationRegistrationToken extends AuthenticationData {
  static const typeName = 'm.login.registration_token';

  AuthenticationRegistrationToken({
    required this.token,
    super.session,
  }) : super(type: typeName);

  final String token;

  @override
  Map<String, Object?> toJson() => {
        ...super.toJson(),
        'token': token,
      };
}

class AuthenticationDummy extends AuthenticationData {
  AuthenticationDummy({super.session}) : super(type: AuthenticationTypes.dummy);
}

/// Одноразовая сессия восстановления пароля по почте.
///
/// [clientSecret] существует только в памяти приложения и связывает запрос
/// письма с завершающим Matrix UIA-запросом. Сохранять его в настройки или БД
/// нельзя.
class OrexPasswordRecoverySession {
  const OrexPasswordRecoverySession({
    required this.email,
    required this.clientSecret,
    required this.sid,
    required this.sendAttempt,
  });

  final String email;
  final String clientSecret;
  final String sid;
  final int sendAttempt;
}

/// Возможности публичного OAuth/OIDC-контура MAS, нужные Orex.
class OrexMasCapabilities {
  const OrexMasCapabilities({
    required this.issuer,
    required this.tokenEndpoint,
    required this.deviceAuthorizationEndpoint,
    required this.grantTypes,
  });

  final Uri issuer;
  final Uri tokenEndpoint;
  final Uri? deviceAuthorizationEndpoint;
  final Set<String> grantTypes;

  bool get supportsDeviceAuthorization =>
      deviceAuthorizationEndpoint != null &&
      grantTypes.contains(_orexDeviceCodeGrant);

  bool get qrBootstrapAvailable =>
      supportsDeviceAuthorization && OrexConfig.oidcClientId.trim().isNotEmpty;
}

/// Ответ MAS на первый шаг OAuth Device Authorization Grant.
///
/// Это готовая основа для QR-экрана: [qrUri] можно кодировать в QR, а
/// [deviceCode] позже использовать для polling token endpoint. Токен polling
/// намеренно не подключён к Matrix-сессии, пока используемая версия SDK не
/// получит проверенный публичный API для импорта Native OIDC device-flow.
class OrexDeviceAuthorizationSession {
  const OrexDeviceAuthorizationSession({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.verificationUriComplete,
    required this.expiresIn,
    required this.interval,
    required this.deviceId,
    required this.createdAt,
  });

  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final Uri? verificationUriComplete;
  final Duration expiresIn;
  final Duration interval;
  final String deviceId;
  final DateTime createdAt;

  Uri get qrUri => verificationUriComplete ?? verificationUri;

  bool get isExpired => DateTime.now().toUtc().isAfter(
        createdAt.add(expiresIn),
      );
}

class OrexAuthProtocolException implements Exception {
  const OrexAuthProtocolException({
    required this.message,
    this.code,
    this.statusCode,
  });

  final String message;
  final String? code;
  final int? statusCode;

  @override
  String toString() {
    final status = statusCode == null ? null : 'HTTP $statusCode';
    final details = <String>[
      ?code,
      ?status,
    ];
    return details.isEmpty ? message : '${details.join(' / ')}: $message';
  }
}

extension MatrixAuthApi on MatrixService {
  bool get isLoggedIn => client.isLogged();

  /// Нативный вход Orex по логину и паролю.
  ///
  /// Запрос идёт в стандартный Matrix Client-Server endpoint. При включённом
  /// MAS этот endpoint должен обслуживаться ресурсом `compat`, поэтому UI
  /// остаётся полностью нативным, а проверка пароля уже принадлежит MAS.
  Future<void> login({
    required String username,
    required String password,
  }) async {
    await client.checkHomeserver(homeserver);
    await client.login(
      LoginType.mLoginPassword,
      identifier: AuthenticationUserIdentifier(user: username),
      password: password,
      initialDeviceDisplayName: 'Orex',
    );
    voip?.resumeStaleMembershipCleanupForLoggedInAccount();
    // access_token и deviceId SDK сохранит в свою БД автоматически.
  }

  /// Регистрация нового аккаунта с использованием ключа приглашения.
  ///
  /// MAS умеет обслуживать registration-token через Matrix compatibility API,
  /// поэтому красивый нативный экран Orex не требуется заменять web-формой.
  Future<void> registerWithToken({
    required String username,
    required String password,
    required String token,
  }) async {
    await client.checkHomeserver(homeserver);

    final normalizedUsername = username.trim();
    final normalizedToken = token.trim();
    String? uiaSession;
    AuthenticationData? auth;
    final attemptedStages = <String>{};

    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        await client.register(
          username: normalizedUsername,
          password: password,
          initialDeviceDisplayName: 'Orex',
          auth: auth,
        );
        voip?.resumeStaleMembershipCleanupForLoggedInAccount();
        return;
      } on MatrixException catch (e) {
        if (!e.requireAdditionalAuthentication) rethrow;

        uiaSession = e.session ?? uiaSession;
        final nextAuth = _nextRegistrationAuth(
          e,
          token: normalizedToken,
          session: uiaSession,
          attemptedStages: attemptedStages,
        );
        if (nextAuth == null) rethrow;
        auth = nextAuth;
      }
    }

    throw StateError(
      'Сервер не завершил регистрацию после нескольких шагов проверки',
    );
  }

  AuthenticationData? _nextRegistrationAuth(
    MatrixException e, {
    required String token,
    required String? session,
    required Set<String> attemptedStages,
  }) {
    if (session == null || session.isEmpty) return null;

    final completed = e.completedAuthenticationFlows.toSet();
    final tokenComplete =
        completed.contains(AuthenticationRegistrationToken.typeName);
    final flows = e.authenticationFlows ?? const <AuthenticationFlow>[];
    final usableFlows = flows.where(
      (flow) =>
          flow.stages.contains(AuthenticationRegistrationToken.typeName) ||
          tokenComplete,
    );

    for (final flow in usableFlows) {
      for (final stage in flow.stages) {
        if (completed.contains(stage)) continue;

        if (stage == AuthenticationRegistrationToken.typeName) {
          if (attemptedStages.contains(stage)) return null;
          attemptedStages.add(stage);
          return AuthenticationRegistrationToken(
            token: token,
            session: session,
          );
        }

        if (stage == AuthenticationTypes.dummy && tokenComplete) {
          if (attemptedStages.contains(stage)) return null;
          attemptedStages.add(stage);
          return AuthenticationDummy(session: session);
        }

        break;
      }
    }

    return null;
  }

  /// Отправляет письмо для восстановления пароля, не покидая интерфейс Orex.
  Future<OrexPasswordRecoverySession> requestPasswordRecoveryEmail({
    required String email,
  }) async {
    await client.checkHomeserver(homeserver);
    final normalizedEmail = email.trim();
    if (normalizedEmail.isEmpty) {
      throw const OrexAuthProtocolException(
        message: 'Введите адрес электронной почты',
      );
    }

    final clientSecret = _orexRandomClientSecret();
    return _requestPasswordRecoveryEmail(
      email: normalizedEmail,
      clientSecret: clientSecret,
      sendAttempt: 1,
    );
  }

  /// Повторно отправляет письмо в рамках той же защищённой сессии.
  Future<OrexPasswordRecoverySession> resendPasswordRecoveryEmail(
    OrexPasswordRecoverySession session,
  ) =>
      _requestPasswordRecoveryEmail(
        email: session.email,
        clientSecret: session.clientSecret,
        sendAttempt: session.sendAttempt + 1,
      );

  Future<OrexPasswordRecoverySession> _requestPasswordRecoveryEmail({
    required String email,
    required String clientSecret,
    required int sendAttempt,
  }) async {
    final response = await _orexPostJson(
      homeserver.resolve(
        '/_matrix/client/v3/account/password/email/requestToken',
      ),
      <String, Object?>{
        'client_secret': clientSecret,
        'email': email,
        'send_attempt': sendAttempt,
      },
    );
    final sid = _orexRequiredString(response, 'sid');
    return OrexPasswordRecoverySession(
      email: email,
      clientSecret: clientSecret,
      sid: sid,
      sendAttempt: sendAttempt,
    );
  }

  /// Завершает восстановление после того, как пользователь подтвердил ссылку
  /// из письма. Пароль и почтовые токены не сохраняются приложением.
  Future<void> finishPasswordRecovery({
    required OrexPasswordRecoverySession session,
    required String newPassword,
  }) async {
    if (newPassword.length < 6) {
      throw const OrexAuthProtocolException(
        message: 'Пароль должен быть не короче 6 символов',
      );
    }
    await _orexPostJson(
      homeserver.resolve('/_matrix/client/v3/account/password'),
      <String, Object?>{
        'new_password': newPassword,
        'auth': <String, Object?>{
          'type': AuthenticationTypes.emailIdentity,
          'threepid_creds': <String, Object?>{
            'sid': session.sid,
            'client_secret': session.clientSecret,
          },
        },
      },
    );
  }

  /// Читает только публичную metadata MAS. Основной вход по паролю от этого
  /// метода не зависит; metadata нужна для будущего QR/device-flow.
  Future<OrexMasCapabilities> discoverMasCapabilities() async {
    final response = await _orexGetJson(OrexConfig.masDiscoveryUri);
    return orexParseMasCapabilities(
      response,
      configuredBase: OrexConfig.authUri,
    );
  }

  /// Запрашивает device code у MAS и возвращает все данные для будущего
  /// нативного QR-экрана. Метод не меняет текущую Matrix-сессию.
  Future<OrexDeviceAuthorizationSession> beginQrLogin() async {
    final clientId = OrexConfig.oidcClientId.trim();
    if (clientId.isEmpty) {
      throw const OrexAuthProtocolException(
        message: 'Для QR-входа не задан OREX_OIDC_CLIENT_ID',
      );
    }

    final capabilities = await discoverMasCapabilities();
    final endpoint = capabilities.deviceAuthorizationEndpoint;
    if (!capabilities.supportsDeviceAuthorization || endpoint == null) {
      throw const OrexAuthProtocolException(
        message: 'MAS не объявил поддержку входа по device code',
      );
    }

    final deviceId = _orexRandomDeviceId();
    final response = await _orexPostForm(
      endpoint,
      <String, String>{
        'client_id': clientId,
        'scope': <String>[
          'openid',
          _orexMatrixApiScope,
          '$_orexMatrixDeviceScopePrefix$deviceId',
        ].join(' '),
      },
    );
    return orexParseDeviceAuthorizationSession(
      response,
      deviceId: deviceId,
      now: DateTime.now().toUtc(),
      configuredBase: OrexConfig.authUri,
    );
  }

  Future<void> logout() async {
    final voipService = voip;
    voipService?.pauseStaleMembershipCleanupForAccountTransition();
    await call.terminateForAccountTransition();
    try {
      await push.unregisterBeforeLogout();
    } catch (_) {
      voipService?.resumeStaleMembershipCleanupAfterFailedAccountTransition();
      rethrow;
    }
    try {
      await client.logout();
    } catch (_) {
      push.resumeAfterFailedLogout();
      voipService?.resumeStaleMembershipCleanupAfterFailedAccountTransition();
      rethrow;
    }
    _emitChange();
  }
}

@visibleForTesting
OrexMasCapabilities orexParseMasCapabilities(
  Map<String, Object?> json, {
  required Uri configuredBase,
}) {
  final issuer = Uri.parse(_orexRequiredString(json, 'issuer'));
  final tokenEndpoint = Uri.parse(
    _orexRequiredString(json, 'token_endpoint'),
  );
  final rawDeviceEndpoint = json['device_authorization_endpoint'];
  final deviceEndpoint = rawDeviceEndpoint is String &&
          rawDeviceEndpoint.trim().isNotEmpty
      ? Uri.parse(rawDeviceEndpoint)
      : null;
  final grants = _orexStringSet(json['grant_types_supported']);

  for (final endpoint in <Uri>[
    issuer,
    tokenEndpoint,
    ?deviceEndpoint,
  ]) {
    if (!orexMasEndpointMatches(endpoint, configuredBase)) {
      throw const OrexAuthProtocolException(
        message: 'MAS вернул точку входа вне настроенного /auth',
      );
    }
  }

  return OrexMasCapabilities(
    issuer: issuer,
    tokenEndpoint: tokenEndpoint,
    deviceAuthorizationEndpoint: deviceEndpoint,
    grantTypes: grants,
  );
}

@visibleForTesting
OrexDeviceAuthorizationSession orexParseDeviceAuthorizationSession(
  Map<String, Object?> json, {
  required String deviceId,
  required DateTime now,
  required Uri configuredBase,
}) {
  final expiresIn = _orexRequiredPositiveInt(json, 'expires_in');
  final interval = _orexOptionalPositiveInt(json, 'interval') ?? 5;
  final verificationUri = Uri.parse(
    _orexRequiredString(json, 'verification_uri'),
  );
  final rawComplete = json['verification_uri_complete'];
  final verificationUriComplete =
      rawComplete is String && rawComplete.trim().isNotEmpty
          ? Uri.parse(rawComplete)
          : null;

  for (final uri in <Uri>[
    verificationUri,
    ?verificationUriComplete,
  ]) {
    if (!orexMasEndpointMatches(uri, configuredBase)) {
      throw const OrexAuthProtocolException(
        message: 'MAS вернул небезопасный адрес подтверждения QR-входа',
      );
    }
  }

  return OrexDeviceAuthorizationSession(
    deviceCode: _orexRequiredString(json, 'device_code'),
    userCode: _orexRequiredString(json, 'user_code'),
    verificationUri: verificationUri,
    verificationUriComplete: verificationUriComplete,
    expiresIn: Duration(seconds: expiresIn),
    interval: Duration(seconds: interval),
    deviceId: deviceId,
    createdAt: now.toUtc(),
  );
}

@visibleForTesting
bool orexMasEndpointMatches(Uri endpoint, Uri configuredBase) {
  if (endpoint.scheme != 'https' ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.host != configuredBase.host ||
      endpoint.port != configuredBase.port ||
      endpoint.scheme != configuredBase.scheme) {
    return false;
  }
  final basePath = _orexNormalizedBasePath(configuredBase.path);
  final endpointPath = _orexNormalizedBasePath(endpoint.path);
  return endpointPath == basePath || endpointPath.startsWith('$basePath/');
}

Future<Map<String, Object?>> _orexGetJson(Uri uri) async {
  final response = await http
      .get(uri, headers: const {'Accept': 'application/json'})
      .timeout(_orexAuthRequestTimeout);
  return _orexDecodeResponse(response);
}

Future<Map<String, Object?>> _orexPostJson(
  Uri uri,
  Map<String, Object?> body,
) async {
  final response = await http
      .post(
        uri,
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      )
      .timeout(_orexAuthRequestTimeout);
  return _orexDecodeResponse(response);
}

Future<Map<String, Object?>> _orexPostForm(
  Uri uri,
  Map<String, String> body,
) async {
  final response = await http
      .post(uri, headers: const {'Accept': 'application/json'}, body: body)
      .timeout(_orexAuthRequestTimeout);
  return _orexDecodeResponse(response);
}

Map<String, Object?> _orexDecodeResponse(http.Response response) {
  Object? decoded;
  if (response.bodyBytes.isNotEmpty) {
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw OrexAuthProtocolException(
        message: 'Сервер авторизации вернул повреждённый JSON',
        statusCode: response.statusCode,
      );
    }
  }

  final json = decoded == null
      ? <String, Object?>{}
      : decoded is Map
          ? Map<String, Object?>.from(decoded)
          : throw OrexAuthProtocolException(
              message: 'Сервер авторизации вернул неожиданный ответ',
              statusCode: response.statusCode,
            );

  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw OrexAuthProtocolException(
      code: json['errcode']?.toString() ?? json['error']?.toString(),
      message: json['error_description']?.toString() ??
          json['error']?.toString() ??
          'Запрос авторизации отклонён сервером',
      statusCode: response.statusCode,
    );
  }
  return json;
}

String _orexRequiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.trim().isNotEmpty) return value.trim();
  throw OrexAuthProtocolException(
    message: 'В ответе сервера отсутствует поле $key',
  );
}

int _orexRequiredPositiveInt(Map<String, Object?> json, String key) {
  final value = _orexOptionalPositiveInt(json, key);
  if (value != null) return value;
  throw OrexAuthProtocolException(
    message: 'В ответе сервера отсутствует поле $key',
  );
}

int? _orexOptionalPositiveInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int && value > 0) return value;
  if (value is num && value > 0) return value.toInt();
  return null;
}

Set<String> _orexStringSet(Object? value) {
  if (value is! List) return const <String>{};
  return Set<String>.unmodifiable(
    value.whereType<String>().map((item) => item.trim()).where(
          (item) => item.isNotEmpty,
        ),
  );
}

String _orexNormalizedBasePath(String path) {
  if (path.isEmpty || path == '/') return '';
  return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
}

String _orexRandomClientSecret() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

String _orexRandomDeviceId() {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final random = Random.secure();
  return List<String>.generate(
    10,
    (_) => alphabet[random.nextInt(alphabet.length)],
    growable: false,
  ).join();
}

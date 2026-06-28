part of 'matrix_service.dart';

/// Модель аутентификации для регистрации через токен приглашения (MSC3231)
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


extension MatrixAuthApi on MatrixService {
  bool get isLoggedIn => client.isLogged();

  /// Логин по паролю: POST /_matrix/client/v3/login под капотом SDK.
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
    // access_token и deviceId SDK сохранит в свою БД автоматически.
  }

  /// Регистрация нового аккаунта с использованием ключа приглашения (registration token).
  ///
  /// Synapse отвечает 401 + { session, flows }, пока не пройдены все UIA-шаги.
  /// Для registration token это часто цепочка registration_token → dummy:
  /// токен считается использованным уже после первого шага, поэтому нельзя
  /// принимать следующую 401-стадию за ошибку регистрации.
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
        if (nextAuth == null) {
          // Если только что отправленный stage не был принят, это настоящая
          // ошибка сервера: неверный токен, неподдерживаемая CAPTCHA и т.п.
          rethrow;
        }
        auth = nextAuth;
      }
    }

    throw StateError(
        'Сервер не завершил регистрацию после нескольких шагов проверки');
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

        // В этом flow есть неподдерживаемый шаг; пробуем следующий flow.
        break;
      }
    }

    return null;
  }

  Future<void> logout() async {
    await client.logout();
    _emitChange();
  }


}

import 'dart:async';

/// Matrix HTTP-pusher, который должен быть зарегистрирован для текущего
/// устройства. `gateway` обязан указывать на стандартный Matrix Push Gateway.
class OrexPushRegistrationConfig {
  const OrexPushRegistrationConfig({
    required this.gateway,
    required this.appId,
    required this.appDisplayName,
    required this.deviceDisplayName,
    required this.language,
    required this.platform,
  });

  final Uri gateway;
  final String appId;
  final String appDisplayName;
  final String deviceDisplayName;
  final String language;
  final String platform;
}

abstract interface class OrexPushRegistrar {
  Future<void> register({
    required String token,
    required OrexPushRegistrationConfig config,
  });

  Future<void> unregister({required String token, required String appId});
}

abstract interface class OrexPushTokenStore {
  Future<String?> read(String accountKey);

  Future<void> write(String accountKey, String token);

  Future<void> clear(String accountKey);
}

/// Управляет жизненным циклом Matrix pusher и ротацией FCM-токена.
///
/// Все мутации сериализованы. Это предотвращает гонку, когда `onNewToken`
/// приходит одновременно с логином или ручным sync и старый pushkey остаётся
/// зарегистрированным на homeserver.
class OrexPushRegistrationService {
  OrexPushRegistrationService({
    required this.registrar,
    required this.tokenStore,
    required this.currentToken,
    required this.tokenChanges,
    required this.accountKey,
    required this.appId,
    required this.config,
    this.onBackgroundError,
  });

  final OrexPushRegistrar registrar;
  final OrexPushTokenStore tokenStore;
  final Future<String?> Function() currentToken;
  final Stream<String> tokenChanges;
  final String? Function() accountKey;
  final String appId;
  final OrexPushRegistrationConfig? Function() config;
  final void Function(Object error, StackTrace stackTrace)? onBackgroundError;

  StreamSubscription<String>? _tokenSub;
  Future<void> _serial = Future<void>.value();
  bool _started = false;
  bool _suspended = false;
  bool _disposed = false;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _tokenSub = tokenChanges.listen((token) {
      if (_suspended) return;
      final normalized = token.trim();
      if (normalized.isEmpty) return;
      sync(token: normalized).then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          onBackgroundError?.call(error, stackTrace);
        },
      );
    });
  }

  Future<void> sync({String? token}) {
    if (_suspended || _disposed) return Future<void>.value();
    return _enqueue(() async {
      if (_suspended) return;
      final registration = config();
      final key = accountKey()?.trim();
      if (registration == null || key == null || key.isEmpty) return;

      final nextToken = (token ?? await currentToken())?.trim();
      if (nextToken == null || nextToken.isEmpty) return;

      final previousToken = (await tokenStore.read(key))?.trim();
      if (previousToken != null &&
          previousToken.isNotEmpty &&
          previousToken != nextToken) {
        await registrar.unregister(
          token: previousToken,
          appId: registration.appId,
        );
      }

      await registrar.register(token: nextToken, config: registration);
      await tokenStore.write(key, nextToken);
    });
  }

  /// Удаляет pusher перед logout. Ошибка намеренно пробрасывается: молча
  /// выходить из аккаунта и оставлять серверную доставку на старый pushkey —
  /// плохой privacy-инвариант.
  Future<void> unregisterBeforeLogout() async {
    if (_disposed) return;
    _suspended = true;
    try {
      await _enqueue(() async {
        final key = accountKey()?.trim();
        final normalizedAppId = appId.trim();
        if (key == null || key.isEmpty || normalizedAppId.isEmpty) return;

        final stored = (await tokenStore.read(key))?.trim();
        final current = (await currentToken())?.trim();
        final tokens = <String>{
          if (stored != null && stored.isNotEmpty) stored,
          if (current != null && current.isNotEmpty) current,
        };

        for (final token in tokens) {
          await registrar.unregister(token: token, appId: normalizedAppId);
        }
        await tokenStore.clear(key);
      });
    } catch (_) {
      _suspended = false;
      rethrow;
    }
  }

  /// Возобновляет регистрацию только после подтверждённого нового login flow
  /// или если сам Matrix logout завершился ошибкой.
  void resume() {
    if (_disposed) return;
    _suspended = false;
  }

  Future<void> _enqueue(Future<void> Function() action) {
    if (_disposed) return Future<void>.value();
    final operation = _serial.then<void>((_) => action());
    _serial = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _tokenSub?.cancel();
    await _serial;
  }
}

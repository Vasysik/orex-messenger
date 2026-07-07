import 'dart:async';
import 'dart:ui';

import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/orex_logger.dart';
import 'push_platform_bridge.dart';
import 'push_registration_service.dart';

class OrexPushService {
  OrexPushService({
    required Client client,
    required this.gateway,
    OrexPushPlatform? platform,
    OrexPushTokenStore? tokenStore,
  })  : _client = client,
        _platform = platform ?? OrexNativePushPlatform(),
        _tokenStore = tokenStore ?? const _SharedPreferencesPushTokenStore() {
    _openController = StreamController<OrexPushOpen>.broadcast(
      onListen: _flushPendingOpen,
      sync: true,
    );
    _registration = OrexPushRegistrationService(
      registrar: _MatrixPushRegistrar(client),
      tokenStore: _tokenStore,
      currentToken: _platform.currentToken,
      tokenChanges: _platform.tokenChanges,
      accountKey: _accountKey,
      appId: _platform.identity?.appId ?? '',
      config: _registrationConfig,
      onBackgroundError: (error, _) {
        OrexLog.d('Push', 'FCM token rotation sync failed', error);
      },
    );
  }

  final Client _client;
  final Uri? gateway;
  final OrexPushPlatform _platform;
  final OrexPushTokenStore _tokenStore;
  late final OrexPushRegistrationService _registration;
  late final StreamController<OrexPushOpen> _openController;
  static const _matrixSyncRetryInterval = Duration(minutes: 5);

  StreamSubscription<OrexPushOpen>? _openSub;
  Future<void>? _syncInFlight;
  DateTime? _lastSyncAttempt;
  OrexPushOpen? _pendingOpen;
  String? _lastPublishedDeliveryId;
  bool _started = false;
  bool _disposed = false;

  Stream<OrexPushOpen> get onNotificationOpened => _openController.stream;

  bool get isConfigured => gateway != null;

  /// Поднимает только локальный bridge и подписки. Сетевой pusher sync не
  /// блокирует bootstrap: он запускается отдельно и имеет собственный error
  /// boundary.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    try {
      await _platform.initialize();
      await _registration.start();
      _openSub = _platform.notificationOpens.listen(
        _publishOpen,
        onError: (Object error, StackTrace _) {
          OrexLog.d('Push', 'notification open stream failed', error);
        },
      );

      final initial = await _platform.takeInitialNotification();
      if (initial != null) _publishOpen(initial);

      unawaited(sync(force: true));
    } catch (_) {
      await _openSub?.cancel();
      _openSub = null;
      _started = false;
      rethrow;
    }
  }

  /// Синхронизирует lifecycle регистрации с Matrix login state. После
  /// успешного logout registration остаётся suspended до следующего login.
  void handleLoginStateChanged() {
    if (_disposed || !_client.isLogged()) return;
    _registration.resume();
    unawaited(sync(force: true));
  }

  /// Если Matrix logout упал после удаления pusher, текущая сессия остаётся
  /// активной и должна снова получать push.
  void resumeAfterFailedLogout() {
    if (_disposed || !_client.isLogged()) return;
    _registration.resume();
    unawaited(sync(force: true));
  }

  /// Matrix sync означает, что сеть снова доступна. Используем его как
  /// безопасный retry-сигнал, но не шлём `postPusher` на каждый `/sync`.
  void handleMatrixSync() {
    if (_disposed || !isConfigured || !_client.isLogged()) return;
    final lastAttempt = _lastSyncAttempt;
    if (lastAttempt != null &&
        DateTime.now().difference(lastAttempt) < _matrixSyncRetryInterval) {
      return;
    }
    unawaited(sync());
  }

  Future<void> sync({bool force = false}) {
    if (_disposed || !isConfigured || !_client.isLogged()) {
      return Future<void>.value();
    }
    final inFlight = _syncInFlight;
    if (inFlight != null) return inFlight;

    final lastAttempt = _lastSyncAttempt;
    if (!force &&
        lastAttempt != null &&
        DateTime.now().difference(lastAttempt) < _matrixSyncRetryInterval) {
      return Future<void>.value();
    }

    late final Future<void> operation;
    operation = _runSync().whenComplete(() {
      if (identical(_syncInFlight, operation)) _syncInFlight = null;
    });
    _syncInFlight = operation;
    return operation;
  }

  Future<void> _runSync() async {
    _lastSyncAttempt = DateTime.now();
    try {
      if (!await _platform.isSupported()) return;
      await _registration.sync();
    } catch (error) {
      OrexLog.d('Push', 'Matrix pusher sync failed', error);
    }
  }

  /// Разрешение запрашивается только после появления основного UI, а не во
  /// время splash/bootstrap. Android permission общий для приложения, поэтому
  /// достаточно одного сохранённого запроса.
  Future<void> ensurePermissionRequested() async {
    try {
      await _requestPermissionOnce();
    } catch (error) {
      OrexLog.d('Push', 'notification permission request failed', error);
    }
  }

  Future<void> showSyncedMatrixNotification({
    required String roomId,
    String? eventId,
  }) async {
    if (_disposed || !_client.isLogged()) return;
    try {
      await _platform.showLocalMatrixNotification(
        roomId: roomId,
        eventId: eventId,
      );
    } catch (error) {
      OrexLog.d('Push', 'local Matrix notification failed', error);
    }
  }

  Future<void> unregisterBeforeLogout() async {
    if (_disposed || !_client.isLogged()) return;
    // Не проверяем Firebase support: сохранённый pushkey всё равно должен быть
    // удалён с homeserver, даже если локальная Firebase-конфигурация исчезла.
    await _registration.unregisterBeforeLogout();
  }

  Future<void> _requestPermissionOnce() async {
    if (_disposed || !isConfigured || !_client.isLogged()) return;
    if (!await _platform.isSupported()) return;
    final prefs = await SharedPreferences.getInstance();
    const key = 'orex_push_permission_prompted_v1';
    if (prefs.getBool(key) == true) return;
    final status = await _platform.requestPermission();
    if (status != OrexPushPermissionStatus.notSupported) {
      await prefs.setBool(key, true);
    }
  }

  void _publishOpen(OrexPushOpen open) {
    if (_disposed) return;
    final deliveryId = open.deliveryId;
    if (deliveryId != null && deliveryId == _lastPublishedDeliveryId) {
      unawaited(_acknowledgeOpen(open));
      return;
    }
    if (_openController.hasListener) {
      _lastPublishedDeliveryId = deliveryId;
      _openController.add(open);
      unawaited(_acknowledgeOpen(open));
    } else {
      // Cold-start intent может прийти до создания OrexApp. Храним последнее
      // действие до первого UI-listener, а Android persistence не подтверждаем.
      _pendingOpen = open;
    }
  }

  void _flushPendingOpen() {
    final pending = _pendingOpen;
    if (pending == null || _disposed) return;
    _pendingOpen = null;
    scheduleMicrotask(() {
      if (_disposed) return;
      if (_openController.hasListener) {
        _lastPublishedDeliveryId = pending.deliveryId;
        _openController.add(pending);
        unawaited(_acknowledgeOpen(pending));
      } else {
        _pendingOpen = pending;
      }
    });
  }

  Future<void> _acknowledgeOpen(OrexPushOpen open) async {
    try {
      await _platform.acknowledgeNotification(open);
    } catch (error) {
      OrexLog.d('Push', 'notification open acknowledgement failed', error);
    }
  }

  String? _accountKey() {
    final userId = _client.userID?.trim();
    final deviceId = _client.deviceID?.trim();
    if (userId == null ||
        userId.isEmpty ||
        deviceId == null ||
        deviceId.isEmpty) {
      return null;
    }
    return '$userId|$deviceId';
  }

  OrexPushRegistrationConfig? _registrationConfig() {
    final gateway = this.gateway;
    final identity = _platform.identity;
    final deviceId = _client.deviceID?.trim();
    if (gateway == null ||
        identity == null ||
        deviceId == null ||
        deviceId.isEmpty) {
      return null;
    }
    return OrexPushRegistrationConfig(
      gateway: gateway,
      appId: identity.appId,
      appDisplayName: 'Orex Messenger',
      deviceDisplayName: 'Orex ${identity.deviceLabel} · $deviceId',
      language: PlatformDispatcher.instance.locale.toLanguageTag(),
      platform: identity.platform,
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _openSub?.cancel();
    await _registration.dispose();
    _platform.dispose();
    await _openController.close();
  }
}

class _MatrixPushRegistrar implements OrexPushRegistrar {
  const _MatrixPushRegistrar(this.client);

  final Client client;

  @override
  Future<void> register({
    required String token,
    required OrexPushRegistrationConfig config,
  }) async {
    await client.postPusher(
      Pusher(
        appId: config.appId,
        pushkey: token,
        appDisplayName: config.appDisplayName,
        data: PusherData(
          url: config.gateway,
          // Не используем event_id_only: Android должен получить достаточно
          // данных, чтобы мгновенно показать notification/call UI без запуска
          // FlutterEngine и сетевого Matrix-запроса внутри FCM callback.
          additionalProperties: <String, Object?>{
            'platform': config.platform,
          },
        ),
        deviceDisplayName: config.deviceDisplayName,
        kind: 'http',
        lang: config.language,
      ),
      append: false,
    );
    OrexLog.d(
      'Push',
      'Matrix pusher registered app=${config.appId} host=${config.gateway.host}',
    );
  }

  @override
  Future<void> unregister({required String token, required String appId}) async {
    await client.deletePusher(PusherId(appId: appId, pushkey: token));
    OrexLog.d('Push', 'Matrix pusher removed app=$appId');
  }
}

class _SharedPreferencesPushTokenStore implements OrexPushTokenStore {
  const _SharedPreferencesPushTokenStore();

  static const _prefix = 'orex_matrix_push_token_v1:';

  @override
  Future<String?> read(String accountKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_prefix$accountKey');
  }

  @override
  Future<void> write(String accountKey, String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefix$accountKey', token);
  }

  @override
  Future<void> clear(String accountKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$accountKey');
  }
}

import 'dart:async';
import 'dart:ui';

import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/orex_logger.dart';
import '../media/orex_avatar_cache.dart';
import 'push_background_resolver.dart';
import 'push_platform_bridge.dart';
import 'push_registration_service.dart';

typedef OrexIncomingCallAnswerHandler =
    Future<void> Function(OrexPushOpen open);

class OrexPushService {
  OrexPushService({
    required Client client,
    required this.gateway,
    OrexPushPlatform? platform,
    OrexPushTokenStore? tokenStore,
  }) : _client = client,
       _platform =
           platform ??
           OrexNativePushPlatform(
             resolvePush: (payload) => resolveOrexMatrixPush(client, payload),
           ),
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
  OrexPushOpen? _pendingIncomingAnswer;
  OrexIncomingCallAnswerHandler? _incomingCallAnswerHandler;
  String? _lastPublishedDeliveryId;
  bool _started = false;
  bool _ready = false;
  bool _disposed = false;

  Stream<OrexPushOpen> get onNotificationOpened => _openController.stream;

  Stream<bool> get desktopWindowVisibilityChanges =>
      _platform.desktopWindowVisibilityChanges;

  bool get isConfigured => gateway != null;

  /// Native pending-open state has been loaded for this Dart isolate.
  /// Call recovery uses this boundary to avoid discarding an accepted cold-start
  /// descriptor before the answer command is available.
  bool get isReady => _ready;

  /// Только platform identity означает, что эта платформа действительно
  /// зарегистрировала remote Matrix pusher и сама владеет background delivery.
  bool get ownsBackgroundNotifications =>
      isConfigured && _platform.identity != null;

  /// Answers from native Android UI must be claimed before a Flutter widget
  /// tree exists. The handler is installed by the Matrix bootstrap during its
  /// bootstrap; ordinary notification opens remain owned by the UI stream.
  void setIncomingCallAnswerHandler(OrexIncomingCallAnswerHandler? handler) {
    if (_disposed) return;
    _incomingCallAnswerHandler = handler;
    final pending = _pendingOpen;
    if (handler == null || pending == null || !isIncomingCallAnswer(pending)) {
      return;
    }
    _pendingOpen = null;
    _lastPublishedDeliveryId = pending.deliveryId;
    _routeIncomingCallAnswer(pending, handler);
  }

  bool handlesIncomingCallAnswer(OrexPushOpen open) =>
      _incomingCallAnswerHandler != null && isIncomingCallAnswer(open);

  static bool isIncomingCallAnswer(OrexPushOpen open) =>
      open.kind == 'incoming_call' &&
      (open.action == 'answer' || open.action == 'answer_video');

  bool hasPendingIncomingAnswer(String roomId, {String? ringEventId}) {
    final pending = _pendingIncomingAnswer;
    if (pending == null ||
        pending.kind != 'incoming_call' ||
        (pending.action != 'answer' && pending.action != 'answer_video') ||
        pending.roomId != roomId.trim()) {
      return false;
    }
    final pendingRing = pending.ringEventId;
    final candidateRing = ringEventId?.trim();
    if (pendingRing == null || pendingRing.isEmpty) return true;
    if (candidateRing == null || candidateRing.isEmpty) return true;
    return pendingRing == candidateRing;
  }

  Future<void> activateIncomingCallWindow() =>
      _platform.activateIncomingCallWindow();

  void consumePendingIncomingAnswer(OrexPushOpen open) {
    final pending = _pendingIncomingAnswer;
    if (pending == null || !isIncomingCallAnswer(open)) {
      return;
    }
    if (pending.roomId != open.roomId) return;
    final pendingRing = pending.ringEventId;
    final openRing = open.ringEventId;
    if (pendingRing != null && openRing != null && pendingRing != openRing) {
      return;
    }
    _pendingIncomingAnswer = null;
    // Do not acknowledge an accepted cold-start command merely because it
    // reached the Dart stream. Keeping native persistence until the bootstrap
    // coordinator has claimed it makes a process death retryable instead of
    // leaving the connecting cover with no command to replay.
    unawaited(_acknowledgeOpen(open));
  }

  /// Поднимает только локальный bridge и подписки. Сетевой pusher sync не
  /// блокирует bootstrap: он запускается отдельно и имеет собственный error
  /// boundary.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    try {
      await _platform.initialize();
      _openSub = _platform.notificationOpens.listen(
        _publishOpen,
        onError: (Object error, StackTrace _) {
          OrexLog.d('Push', 'notification open stream failed', error);
        },
      );
      // Subscribe before registration or any native method can make the
      // Android bridge flush a persisted cold-start Answer command.
      await _registration.start();

      final initial = await _platform.takeInitialNotification();
      if (initial != null) _publishOpen(initial);

      _ready = true;

      unawaited(sync(force: true));
    } catch (_) {
      await _openSub?.cancel();
      _openSub = null;
      _started = false;
      _ready = false;
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

  Future<void> notifyCallAnswering(String callId, {String? ringEventId}) async {
    if (_disposed) return;
    try {
      await _platform.notifyCallAnswering(callId, ringEventId: ringEventId);
    } catch (error) {
      OrexLog.d('Push', 'native call answering acknowledgement failed', error);
    }
  }

  Future<void> notifyCallUiReady(String callId, {String? ringEventId}) async {
    if (_disposed) return;
    try {
      await _platform.notifyCallUiReady(callId, ringEventId: ringEventId);
    } catch (error) {
      OrexLog.d('Push', 'native call handoff acknowledgement failed', error);
    }
  }

  Future<void> notifyCallEnded(String callId, {String? ringEventId}) async {
    if (_disposed) return;
    try {
      await _platform.notifyCallEnded(callId, ringEventId: ringEventId);
    } catch (error) {
      OrexLog.d('Push', 'native call end acknowledgement failed', error);
    }
  }

  Future<void> notifyCallUiHidden() async {
    if (_disposed) return;
    try {
      await _platform.notifyCallUiHidden();
    } catch (error) {
      OrexLog.d('Push', 'native call UI hide acknowledgement failed', error);
    }
  }

  Future<void> showSyncedMatrixNotification({
    required String roomId,
    String? eventId,
    String? avatarCacheKey,
  }) async {
    if (_disposed || !_client.isLogged()) return;
    final normalizedRoomId = roomId.trim();
    if (normalizedRoomId.isEmpty) return;
    final room = _client.getRoomById(normalizedRoomId);
    final event = room?.lastEvent;
    if (event == null) return;
    final normalizedEventId = eventId?.trim();
    if (normalizedEventId != null &&
        normalizedEventId.isNotEmpty &&
        event.eventId != normalizedEventId) {
      return;
    }
    final payload = resolveOrexSyncedMatrixNotification(event);
    if (payload == null) return;
    final presentationPayload = Map<String, String>.of(payload);
    final normalizedAvatarKey = avatarCacheKey?.trim();
    if (normalizedAvatarKey != null && normalizedAvatarKey.isNotEmpty) {
      presentationPayload['sender_avatar_key'] = normalizedAvatarKey;
      final avatarPath = await OrexAvatarCache.pathForKey(normalizedAvatarKey);
      if (avatarPath != null) {
        presentationPayload['sender_avatar_path'] = avatarPath;
      }
    }
    try {
      await _platform.showLocalMatrixNotification(presentationPayload);
    } catch (error) {
      OrexLog.d('Push', 'local Matrix notification failed', error);
    }
  }

  Future<void> dismissRoomNotifications(String roomId) async {
    if (_disposed) return;
    try {
      await _platform.dismissRoomNotifications(roomId);
    } catch (error) {
      OrexLog.d('Push', 'room notification dismissal failed', error);
    }
  }

  Future<void> unregisterBeforeLogout() async {
    if (_disposed || !_client.isLogged()) return;
    // Не проверяем Firebase support: сохранённый pushkey всё равно должен быть
    // удалён с homeserver, даже если локальная Firebase-конфигурация исчезла.
    await _registration.unregisterBeforeLogout();
  }

  Future<void> _requestPermissionOnce() async {
    if (_disposed || !_client.isLogged()) return;
    final prefs = await SharedPreferences.getInstance();
    const key = 'orex_local_notification_permission_prompted_v1';
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
      if (!isIncomingCallAnswer(open)) {
        unawaited(_acknowledgeOpen(open));
      }
      return;
    }
    if (isIncomingCallAnswer(open)) {
      _pendingIncomingAnswer = open;
      final handler = _incomingCallAnswerHandler;
      if (handler != null) {
        _lastPublishedDeliveryId = deliveryId;
        _routeIncomingCallAnswer(open, handler);
        return;
      }
    }
    if (_openController.hasListener) {
      _lastPublishedDeliveryId = deliveryId;
      _openController.add(open);
      if (!isIncomingCallAnswer(open)) {
        unawaited(_acknowledgeOpen(open));
      }
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
        if (!isIncomingCallAnswer(pending)) {
          unawaited(_acknowledgeOpen(pending));
        }
      } else {
        _pendingOpen = pending;
      }
    });
  }

  void _routeIncomingCallAnswer(
    OrexPushOpen open,
    OrexIncomingCallAnswerHandler handler,
  ) {
    OrexLog.d(
      'Push',
      'routing accepted call to bootstrap coordinator '
          'room=${open.roomId} ring=${open.ringEventId}',
    );
    unawaited(
      handler(open).catchError((Object error, StackTrace _) {
        OrexLog.d('Push', 'incoming-call bootstrap handler failed', error);
      }),
    );
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
    _ready = false;
    _pendingIncomingAnswer = null;
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
          additionalProperties: <String, Object?>{'platform': config.platform},
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
  Future<void> unregister({
    required String token,
    required String appId,
  }) async {
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

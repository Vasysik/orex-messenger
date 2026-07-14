import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;

import 'core/config/orex_config.dart';
import 'core/config/app_version.dart';
import 'core/storage/database.dart';
import 'core/matrix/matrix_service.dart';
import 'core/push/push_background_resolver.dart';
import 'core/push/push_platform_bridge.dart';
import 'core/logging/orex_logger.dart';
import 'core/voip/voip_service.dart';
import 'features/auth/login_screen.dart';
import 'features/calls/call_screen.dart';
import 'features/calls/incoming_call_screen.dart';
import 'features/home/home_shell.dart';
import 'features/settings/verification_screen.dart';
import 'shared/theme/glass.dart';
import 'shared/theme/orex_theme.dart';
import 'shared/theme/theme_controller.dart';
import 'shared/widgets/orex_app_brand.dart';

@pragma('vm:entry-point')
Future<void> orexPushBackgroundMain() => runOrexPushBackgroundEntrypoint();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) BrowserContextMenu.disableContextMenu();
  runApp(const OrexBootstrap());
}

class OrexScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
  };
}

class _Services {
  _Services(this.matrix, this.theme, this.version);
  final MatrixService matrix;
  final ThemeController theme;
  final OrexAppVersion version;
}

class OrexBootstrap extends StatefulWidget {
  const OrexBootstrap({super.key});

  @override
  State<OrexBootstrap> createState() => _OrexBootstrapState();
}

class _OrexBootstrapState extends State<OrexBootstrap> {
  late final Future<OrexAppVersion> _versionFuture = OrexAppVersion.load();
  late final Future<_Services> _future = _init();

  Future<_Services> _init() async {
    final minimumSplash = Future<void>.delayed(
      const Duration(milliseconds: 720),
    );
    final version = await _versionFuture;
    OrexLog.d(
      'Bootstrap',
      'starting $orexAppName ${version.version}, Сборка ${version.buildNumber}',
    );
    OrexConfig.validateSecurity();
    try {
      await vod.init().timeout(const Duration(seconds: 6));
    } catch (e) {
      if (OrexConfig.requireVodozemac) {
        throw StateError(
          'Не удалось инициализировать vodozemac. Запуск остановлен, '
          'чтобы не открыть защищённый мессенджер без E2EE: $e',
        );
      }
      OrexLog.d('Bootstrap', 'vodozemac init skipped/failed, E2EE disabled', e);
    }

    final theme = await ThemeController.load();
    final database = await buildOrexDatabase();
    final matrix = MatrixService(
      homeserver: OrexConfig.homeserverUri,
      database: database,
    );
    await matrix.init();
    await minimumSplash;
    return _Services(matrix, theme, version);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Services>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) {
          OrexLog.d('Bootstrap', 'startup failed', snap.error);
          return const _MiniApp(
            child: _StartupError(
              error:
                  'Проверьте подключение и перезапустите приложение. '
                  'Подробности сохранены только в отладочном логе.',
            ),
          );
        }
        if (!snap.hasData) {
          return _MiniApp(child: SplashScreen(versionFuture: _versionFuture));
        }
        return OrexApp(
          matrix: snap.data!.matrix,
          theme: snap.data!.theme,
          version: snap.data!.version,
        );
      },
    );
  }
}

class _MiniApp extends StatelessWidget {
  const _MiniApp({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: OrexTheme.dark,
      home: child,
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key, this.versionFuture});

  final Future<OrexAppVersion>? versionFuture;

  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FutureBuilder<OrexAppVersion>(
                  future: versionFuture,
                  initialData: OrexAppVersion.fallback,
                  builder: (context, snap) => OrexBrandHeader(
                    version: snap.data ?? OrexAppVersion.fallback,
                    iconSize: 136,
                  ),
                ),
                const SizedBox(height: 28),
                const SizedBox.square(
                  dimension: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.6,
                    color: OrexColors.copper,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Color(0xFFCF6679),
                  size: 48,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Не удалось запустить приложение',
                  style: TextStyle(fontSize: 18),
                ),
                const SizedBox(height: 8),
                Text(error, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class OrexApp extends StatefulWidget {
  const OrexApp({
    super.key,
    required this.matrix,
    required this.theme,
    required this.version,
  });
  final MatrixService matrix;
  final ThemeController theme;
  final OrexAppVersion version;

  @override
  State<OrexApp> createState() => _OrexAppState();
}

class _OrexAppState extends State<OrexApp> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  StreamSubscription? _verificationSub;
  StreamSubscription<OrexIncomingCall>? _incomingCallSub;
  StreamSubscription<OrexCallInstancePromotion>? _callInstancePromotionSub;
  StreamSubscription<OrexCallInstance>? _acceptedCallUiSub;
  StreamSubscription<OrexPushOpen>? _pushOpenSub;
  String? _pushRoomId;
  String? _expandedCallRouteKey;
  Route<void>? _expandedCallRoute;
  int _pushOpenGeneration = 0;
  late bool _wasLoggedIn;
  final Map<String, Object> _incomingCallDialogs = <String, Object>{};
  final Map<String, Object> _pendingCallActionAttempts = <String, Object>{};
  final Map<String, OrexCallInstance> _callInstanceAliases =
      <String, OrexCallInstance>{};
  AppLifecycleState _lifecycleState =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
  DateTime? _backgroundedAt;

  bool get _isForeground => _lifecycleState == AppLifecycleState.resumed;

  bool _isCurrentCall(OrexCallInstance instance) {
    final expected = _canonicalCallInstance(instance);
    return widget.matrix.call.currentCallInstance?.routeKey ==
        expected.routeKey;
  }

  OrexCallInstance _canonicalCallInstance(OrexCallInstance instance) {
    final promoted = _callInstanceAliases[instance.routeKey];
    if (promoted == null) return instance;
    final voip = widget.matrix.voip;
    final controllerInstance = widget.matrix.call.currentCallInstance;
    final runtimeRingEventId =
        voip?.incomingRingEventId(instance.roomId) ??
        voip?.activeRingEventId(instance.roomId) ??
        (controllerInstance?.roomId == instance.roomId
            ? controllerInstance?.ringEventId
            : null);
    return runtimeRingEventId == promoted.ringEventId ? promoted : instance;
  }

  bool _attemptMapContains(
    Map<String, Object> attempts,
    OrexCallInstance instance,
  ) => attempts.containsKey(_canonicalCallInstance(instance).routeKey);

  Object? _claimAttempt(
    Map<String, Object> attempts,
    OrexCallInstance instance,
  ) {
    final key = _canonicalCallInstance(instance).routeKey;
    if (attempts.containsKey(key)) return null;
    final owner = Object();
    attempts[key] = owner;
    return owner;
  }

  void _releaseAttempt(Map<String, Object> attempts, Object owner) {
    attempts.removeWhere((_, value) => identical(value, owner));
  }

  void _handleCallInstancePromotion(OrexCallInstancePromotion promotion) {
    final previousKey = promotion.previous.routeKey;
    _callInstanceAliases[previousKey] = promotion.current;

    void migrate(Map<String, Object> attempts) {
      final owner = attempts.remove(previousKey);
      if (owner != null) {
        attempts.putIfAbsent(promotion.current.routeKey, () => owner);
      }
    }

    migrate(_incomingCallDialogs);
    migrate(_pendingCallActionAttempts);
    if (_expandedCallRouteKey == previousKey) {
      _expandedCallRouteKey = promotion.current.routeKey;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _wasLoggedIn = widget.matrix.isLoggedIn;
    widget.matrix.addListener(_onChanged);
    widget.theme.addListener(_onChanged);
    _verificationSub = widget.matrix.incomingVerifications.listen((kv) {
      _navKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) =>
              VerificationScreen(request: kv, matrix: widget.matrix),
        ),
      );
    });
    _callInstancePromotionSub = widget.matrix.voip?.onCallInstancePromotion
        .listen(_handleCallInstancePromotion);
    _incomingCallSub = widget.matrix.voip?.onIncomingCall.listen(
      _showIncomingCall,
    );
    _acceptedCallUiSub = widget.matrix.call.onAcceptedIncomingCallUiRequested
        .listen(_handleAcceptedCallUiRequest);
    _pushOpenSub = widget.matrix.push.onNotificationOpened.listen(
      _openPushNotification,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pendingCallUi =
          widget.matrix.call.pendingAcceptedIncomingCallUiRequest;
      if (pendingCallUi != null) _openAcceptedCall(pendingCallUi);
      if (widget.matrix.isLoggedIn) {
        unawaited(widget.matrix.push.ensurePermissionRequested());
      }
      for (final incoming
          in widget.matrix.voip?.visibleIncomingCalls() ??
              const <OrexIncomingCall>[]) {
        _showIncomingCall(incoming);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final previousState = _lifecycleState;
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      final backgroundedAt = _backgroundedAt;
      _backgroundedAt = null;
      if (backgroundedAt != null && widget.matrix.call.isActive) {
        final backgroundDuration = DateTime.now().difference(backgroundedAt);
        unawaited(
          widget.matrix.call.recoverMediaAfterBackground(backgroundDuration),
        );
      }
      // Notification action / Core-Telecom answer can arrive in the same frame
      // as lifecycle resume. Give that explicit user action priority before
      // replaying an incoming-call route, otherwise Answer can briefly show the
      // incoming panel again.
      Future<void>.delayed(const Duration(milliseconds: 350), () {
        if (!mounted || !_isForeground) return;
        final incomingCalls =
            widget.matrix.voip?.visibleIncomingCalls() ??
            const <OrexIncomingCall>[];
        for (final incoming in incomingCalls) {
          _showIncomingCall(incoming);
        }
      });
      return;
    }

    if (previousState == AppLifecycleState.resumed) {
      _backgroundedAt = DateTime.now();
    } else {
      _backgroundedAt ??= DateTime.now();
    }

    // Пока Orex не виден, Flutter не открывает маршруты входящего звонка.
    // Если Matrix /sync обнаружил вызов без FCM, Core-Telecom становится
    // резервным системным presentation; native dedup не даст повторно звенеть.
    final incomingCalls =
        widget.matrix.voip?.visibleIncomingCalls() ??
        const <OrexIncomingCall>[];
    for (final incoming in incomingCalls) {
      final instance = incoming.instance;
      if (!(widget.matrix.voip?.isIncomingCallVisible(instance) ?? false) ||
          widget.matrix.call.isActive ||
          widget.matrix.call.isAcceptingIncomingInstance(instance)) {
        continue;
      }
      unawaited(
        widget.matrix.call.prepareIncoming(incoming.room, instance: instance),
      );
    }
  }

  void _openPushNotification(OrexPushOpen open) {
    final actionInstance =
        open.kind == 'incoming_call' &&
            open.action != null &&
            open.roomId != null
        ? OrexCallInstance(roomId: open.roomId!, ringEventId: open.ringEventId)
        : null;
    final actionOwner = actionInstance == null
        ? null
        : _claimAttempt(_pendingCallActionAttempts, actionInstance);
    unawaited(
      _handlePushNotificationOpen(open).whenComplete(() {
        if (actionOwner != null) {
          _releaseAttempt(_pendingCallActionAttempts, actionOwner);
        }
      }),
    );
  }

  Future<void> _handlePushNotificationOpen(OrexPushOpen open) async {
    final roomId = open.roomId;
    if (!mounted || roomId == null) return;

    var room = widget.matrix.client.getRoomById(roomId);
    if (open.kind == 'incoming_call' && room == null) {
      try {
        await widget.matrix.client.oneShotSync(timeout: Duration.zero);
      } catch (e) {
        OrexLog.d('Push', 'cold call room sync failed room=$roomId', e);
      }
      room = widget.matrix.client.getRoomById(roomId);
    }

    if (!mounted) return;
    if (open.kind == 'incoming_call') {
      if (room == null) {
        OrexLog.d('Push', 'incoming call room unavailable room=$roomId');
        if (open.action == 'answer' || open.action == 'answer_video') {
          widget.matrix.push.consumePendingIncomingAnswer(open);
          await widget.matrix.push.notifyCallEnded(
            roomId,
            ringEventId: open.ringEventId,
          );
        }
        return;
      }
      final call = widget.matrix.call;
      final instance = _canonicalCallInstance(
        OrexCallInstance(roomId: room.id, ringEventId: open.ringEventId),
      );
      if (open.action == null && call.isActive && _isCurrentCall(instance)) {
        _openAcceptedCall(instance);
        return;
      }
      switch (open.action) {
        case 'answer':
        case 'answer_video':
          widget.matrix.voip?.dismissIncomingFromSystem(instance);
          try {
            await call.acceptIncoming(
              room,
              video: open.video,
              instance: instance,
              fromSystem: open.fromSystem,
              requestExpandedUi: true,
            );
          } finally {
            widget.matrix.push.consumePendingIncomingAnswer(open);
          }
          if (!mounted) return;
          if (!call.isActive || !_isCurrentCall(instance)) {
            OrexLog.d(
              'Push',
              'incoming call answer completed without exact active call '
                  'room=${room.id} ring=${instance.ringEventId}',
            );
          }
          return;
        case 'reject':
          widget.matrix.voip?.dismissIncomingFromSystem(instance);
          await call.rejectIncoming(
            room,
            instance: instance,
            fromSystem: open.fromSystem,
          );
          return;
        case 'resume':
          await call.recoverPendingCall();
          if (!mounted) return;
          if (call.isActive && _isCurrentCall(instance)) {
            _openAcceptedCall(instance);
          } else {
            await call.discardRecoverableCall(
              room.id,
              ringEventId: instance.ringEventId,
            );
          }
          return;
        case 'hangup':
          await call.recoverPendingCall();
          if (call.isActive && _isCurrentCall(instance)) {
            await call.hangUp();
          } else {
            await call.discardRecoverableCall(
              room.id,
              ringEventId: instance.ringEventId,
            );
          }
          return;
        case 'toggle_mic':
          await call.recoverPendingCall();
          if (call.isActive && _isCurrentCall(instance)) {
            await call.session?.toggleMic();
          } else {
            await call.discardRecoverableCall(
              room.id,
              ringEventId: instance.ringEventId,
            );
          }
          return;
        case 'toggle_audio':
          await call.recoverPendingCall();
          if (call.isActive && _isCurrentCall(instance)) {
            await call.session?.toggleSpeakerMute();
          } else {
            await call.discardRecoverableCall(
              room.id,
              ringEventId: instance.ringEventId,
            );
          }
          return;
        default:
          _showIncomingCall(
            OrexIncomingCall(room: room, ringEventId: instance.ringEventId),
          );
          return;
      }
    }

    setState(() {
      _pushRoomId = roomId;
      _pushOpenGeneration++;
    });
  }

  void _showIncomingCall(OrexIncomingCall incoming, {int attempt = 0}) {
    if (!mounted) return;
    final room = incoming.room;
    final sourceInstance = incoming.instance;
    OrexCallInstance currentInstance() =>
        _canonicalCallInstance(sourceInstance);
    bool isVisible() =>
        widget.matrix.voip?.isIncomingCallVisible(currentInstance()) ?? false;

    final call = widget.matrix.call;
    if (call.isActive) return;
    if (widget.matrix.push.hasPendingIncomingAnswer(
      room.id,
      ringEventId: currentInstance().ringEventId,
    )) {
      return;
    }
    if (!isVisible()) return;
    if (call.isAcceptingIncomingInstance(currentInstance())) return;
    if (_attemptMapContains(_pendingCallActionAttempts, sourceInstance)) return;
    if (!_isForeground) {
      if (!call.isActive) {
        unawaited(call.prepareIncoming(room, instance: currentInstance()));
      }
      return;
    }
    final routeOwner = _claimAttempt(_incomingCallDialogs, sourceInstance);
    if (routeOwner == null) return;

    void retryLater() {
      if (attempt >= 8) {
        _releaseAttempt(_incomingCallDialogs, routeOwner);
        OrexLog.d(
          'Call',
          'incoming call UI unavailable after retries '
              'room=${room.id} ring=${currentInstance().ringEventId}',
        );
        final call = widget.matrix.call;
        if (!call.isActive &&
            isVisible() &&
            !call.isAcceptingIncomingInstance(currentInstance())) {
          unawaited(call.prepareIncoming(room, instance: currentInstance()));
        }
        return;
      }
      Future<void>.delayed(const Duration(milliseconds: 200), () {
        if (!mounted) {
          _releaseAttempt(_incomingCallDialogs, routeOwner);
          return;
        }
        _releaseAttempt(_incomingCallDialogs, routeOwner);
        if (isVisible()) {
          _showIncomingCall(incoming, attempt: attempt + 1);
        }
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _releaseAttempt(_incomingCallDialogs, routeOwner);
        return;
      }
      final call = widget.matrix.call;
      if (!_isForeground ||
          !isVisible() ||
          widget.matrix.push.hasPendingIncomingAnswer(
            room.id,
            ringEventId: currentInstance().ringEventId,
          ) ||
          _attemptMapContains(_pendingCallActionAttempts, sourceInstance) ||
          call.isAcceptingIncomingInstance(currentInstance()) ||
          call.isActive) {
        _releaseAttempt(_incomingCallDialogs, routeOwner);
        return;
      }
      final nav = _navKey.currentState;
      final ctx = nav?.overlay?.context ?? _navKey.currentContext;
      if (nav == null || ctx == null || !ctx.mounted) {
        retryLater();
        return;
      }
      final isWide = MediaQuery.sizeOf(ctx).width >= 900;
      final Future<void> future;
      try {
        future = isWide
            ? showDialog<void>(
                context: ctx,
                barrierDismissible: false,
                useRootNavigator: true,
                builder: (_) => IncomingCallScreen(
                  matrix: widget.matrix,
                  incoming: OrexIncomingCall(
                    room: room,
                    ringEventId: currentInstance().ringEventId,
                  ),
                  asDialog: true,
                ),
              )
            : nav.push<void>(
                MaterialPageRoute(
                  fullscreenDialog: true,
                  builder: (_) => IncomingCallScreen(
                    matrix: widget.matrix,
                    incoming: OrexIncomingCall(
                      room: room,
                      ringEventId: currentInstance().ringEventId,
                    ),
                  ),
                ),
              );
      } catch (error) {
        OrexLog.d(
          'Call',
          'failed to present incoming call room=${room.id}',
          error,
        );
        retryLater();
        return;
      }
      unawaited(
        future
            .catchError((Object error, StackTrace _) {
              OrexLog.d(
                'Call',
                'incoming call route failed room=${room.id}',
                error,
              );
            })
            .whenComplete(
              () => _releaseAttempt(_incomingCallDialogs, routeOwner),
            ),
      );
    });
  }

  void _handleAcceptedCallUiRequest(OrexCallInstance instance) {
    _openAcceptedCall(instance);
  }

  void _openAcceptedCall(OrexCallInstance instance, {int attempt = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      OrexCallInstance currentInstance() => _canonicalCallInstance(instance);

      if (!mounted ||
          !widget.matrix.call.isActive ||
          !_isCurrentCall(currentInstance())) {
        return;
      }

      final nav = _navKey.currentState;
      final ctx = nav?.overlay?.context ?? _navKey.currentContext;
      if (nav == null || ctx == null || !ctx.mounted) {
        if (attempt < 80) {
          Future<void>.delayed(const Duration(milliseconds: 150), () {
            if (mounted) {
              _openAcceptedCall(instance, attempt: attempt + 1);
            }
          });
        }
        return;
      }

      void notifyUiReady() {
        widget.matrix.call.takePendingAcceptedIncomingCallUiRequest();
        final exactInstance = currentInstance();
        unawaited(
          widget.matrix.push.notifyCallUiReady(
            exactInstance.roomId,
            ringEventId: exactInstance.ringEventId,
          ),
        );
      }

      if (MediaQuery.sizeOf(ctx).width >= 900) {
        widget.matrix.call.minimize();
        notifyUiReady();
        return;
      }

      final existingRoute = _expandedCallRoute;
      if (existingRoute != null && existingRoute.isActive) {
        widget.matrix.call.expand();
        if (_expandedCallRouteKey != currentInstance().routeKey) {
          _expandedCallRouteKey = currentInstance().routeKey;
        }
        notifyUiReady();
        return;
      }
      _expandedCallRoute = null;
      _expandedCallRouteKey = null;

      widget.matrix.call.expand();
      final route = MaterialPageRoute<void>(
        builder: (_) => CallScreen(matrix: widget.matrix),
      );
      final routeClosed = nav.push<void>(route);
      _expandedCallRoute = route;
      _expandedCallRouteKey = currentInstance().routeKey;

      // Закрываем нативную lock-screen оболочку только после того, как Flutter
      // действительно отрисовал расширенный режим звонка.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !widget.matrix.call.isActive ||
            !_isCurrentCall(currentInstance()) ||
            !identical(_expandedCallRoute, route)) {
          return;
        }
        notifyUiReady();
      });

      routeClosed.whenComplete(() {
        if (identical(_expandedCallRoute, route)) {
          _expandedCallRoute = null;
          _expandedCallRouteKey = null;
        }
      });
    });
  }

  void _onChanged() {
    if (!mounted) return;
    final isLoggedIn = widget.matrix.isLoggedIn;
    if (isLoggedIn && !_wasLoggedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.matrix.isLoggedIn) return;
        unawaited(widget.matrix.push.ensurePermissionRequested());
      });
    }
    _wasLoggedIn = isLoggedIn;
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _verificationSub?.cancel();
    _incomingCallSub?.cancel();
    _callInstancePromotionSub?.cancel();
    _acceptedCallUiSub?.cancel();
    _pushOpenSub?.cancel();
    widget.matrix.removeListener(_onChanged);
    widget.theme.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: orexAppName,
      navigatorKey: _navKey,
      scrollBehavior: OrexScrollBehavior(),
      debugShowCheckedModeBanner: false,
      theme: OrexTheme.light,
      darkTheme: OrexTheme.dark,
      themeMode: widget.theme.mode,
      home: widget.matrix.isLoggedIn
          ? HomeShell(
              matrix: widget.matrix,
              theme: widget.theme,
              version: widget.version,
              pushRoomId: _pushRoomId,
              pushOpenGeneration: _pushOpenGeneration,
            )
          : LoginScreen(
              matrix: widget.matrix,
              version: widget.version,
              onLoggedIn: () => setState(() {}),
            ),
    );
  }
}

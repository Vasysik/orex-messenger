import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/matrix.dart' show Room;

import 'core/config/orex_config.dart';
import 'core/config/app_version.dart';
import 'core/storage/database.dart';
import 'core/matrix/matrix_service.dart';
import 'core/push/push_platform_bridge.dart';
import 'core/logging/orex_logger.dart';
import 'features/auth/login_screen.dart';
import 'features/calls/call_screen.dart';
import 'features/calls/incoming_call_screen.dart';
import 'features/home/home_shell.dart';
import 'features/settings/verification_screen.dart';
import 'shared/theme/glass.dart';
import 'shared/theme/orex_theme.dart';
import 'shared/theme/theme_controller.dart';
import 'shared/widgets/orex_app_brand.dart';

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
    final minimumSplash =
        Future<void>.delayed(const Duration(milliseconds: 720));
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
          return _MiniApp(child: _StartupError(error: snap.error.toString()));
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
                const Icon(Icons.error_outline,
                    color: Color(0xFFCF6679), size: 48),
                const SizedBox(height: 16),
                const Text('Не удалось запустить приложение',
                    style: TextStyle(fontSize: 18)),
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

class _OrexAppState extends State<OrexApp> {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  StreamSubscription? _verificationSub;
  StreamSubscription? _incomingCallSub;
  StreamSubscription<String>? _systemAcceptedCallSub;
  StreamSubscription<OrexPushOpen>? _pushOpenSub;
  String? _pushRoomId;
  int _pushOpenGeneration = 0;
  late bool _wasLoggedIn;
  final Set<String> _incomingCallDialogs = <String>{};

  @override
  void initState() {
    super.initState();
    _wasLoggedIn = widget.matrix.isLoggedIn;
    widget.matrix.addListener(_onChanged);
    widget.theme.addListener(_onChanged);
    _verificationSub = widget.matrix.incomingVerifications.listen((kv) {
      _navKey.currentState?.push(
        MaterialPageRoute(
            builder: (_) =>
                VerificationScreen(request: kv, matrix: widget.matrix)),
      );
    });
    _incomingCallSub =
        widget.matrix.voip?.onIncomingCall.listen(_showIncomingCall);
    _systemAcceptedCallSub = widget.matrix.call.onSystemIncomingAccepted.listen(
      _openSystemAcceptedCall,
    );
    _pushOpenSub = widget.matrix.push.onNotificationOpened.listen(
      _openPushNotification,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.matrix.isLoggedIn) {
        unawaited(widget.matrix.push.ensurePermissionRequested());
      }
      for (final room in
          widget.matrix.voip?.visibleIncomingRooms() ?? const <Room>[]) {
        _showIncomingCall(room);
      }
    });
  }

  void _openPushNotification(OrexPushOpen open) {
    final roomId = open.roomId;
    if (!mounted || roomId == null) return;
    setState(() {
      _pushRoomId = roomId;
      _pushOpenGeneration++;
    });
  }

  void _showIncomingCall(Room room) {
    if (!mounted) return;
    final call = widget.matrix.call;
    if (call.isActive && call.roomId == room.id) return;
    if (!call.isActive) unawaited(call.prepareIncoming(room));
    if (!_incomingCallDialogs.add(room.id)) return;

    void retryLater() {
      Future<void>.delayed(const Duration(milliseconds: 200), () {
        if (!mounted) {
          _incomingCallDialogs.remove(room.id);
          return;
        }
        _incomingCallDialogs.remove(room.id);
        _showIncomingCall(room);
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _incomingCallDialogs.remove(room.id);
        return;
      }
      final call = widget.matrix.call;
      if (call.isActive && call.roomId == room.id) {
        _incomingCallDialogs.remove(room.id);
        return;
      }
      final nav = _navKey.currentState;
      final ctx = nav?.overlay?.context ?? _navKey.currentContext;
      if (ctx == null || !ctx.mounted) {
        retryLater();
        return;
      }
      showDialog<void>(
        context: ctx,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (_) => IncomingCallScreen(
          matrix: widget.matrix,
          room: room,
          asDialog: true,
        ),
      ).whenComplete(() => _incomingCallDialogs.remove(room.id));
    });
  }

  void _openSystemAcceptedCall(String roomId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !widget.matrix.call.isActive ||
          widget.matrix.call.roomId != roomId) {
        return;
      }
      final nav = _navKey.currentState;
      final ctx = nav?.overlay?.context ?? _navKey.currentContext;
      if (nav == null || ctx == null || !ctx.mounted) return;
      if (MediaQuery.sizeOf(ctx).width >= 900) {
        widget.matrix.call.minimize();
        return;
      }
      widget.matrix.call.expand();
      nav.push(
        MaterialPageRoute(builder: (_) => CallScreen(matrix: widget.matrix)),
      );
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
    _verificationSub?.cancel();
    _incomingCallSub?.cancel();
    _systemAcceptedCallSub?.cancel();
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

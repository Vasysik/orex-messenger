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
import 'core/logging/orex_logger.dart';
import 'features/auth/login_screen.dart';
import 'features/calls/incoming_call_screen.dart';
import 'features/home/home_shell.dart';
import 'features/settings/verification_screen.dart';
import 'shared/theme/glass.dart';
import 'shared/theme/orex_theme.dart';
import 'shared/theme/theme_controller.dart';
import 'shared/widgets/squirrel_mascot.dart';

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
    final version = await _versionFuture;
    OrexLog.d(
      'Bootstrap',
      'starting Orex Messenger ${version.version}, Сборка ${version.buildNumber}',
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SquirrelMascot(size: 132, caption: 'Orex Messenger'),
              const SizedBox(height: 10),
              FutureBuilder<OrexAppVersion>(
                future: versionFuture,
                initialData: OrexAppVersion.fallback,
                builder: (context, snap) {
                  final version = snap.data ?? OrexAppVersion.fallback;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        version.versionLine,
                        style: const TextStyle(
                          color: OrexColors.cream,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        version.buildLine,
                        style: const TextStyle(
                          color: OrexColors.cream,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 28),
              const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: OrexColors.copper,
                ),
              ),
            ],
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
  final Set<String> _incomingCallDialogs = <String>{};

  @override
  void initState() {
    super.initState();
    widget.matrix.addListener(_onChanged);
    widget.theme.addListener(_onChanged);
    _verificationSub = widget.matrix.incomingVerifications.listen((kv) {
      _navKey.currentState?.push(
        MaterialPageRoute(
            builder: (_) =>
                VerificationScreen(request: kv, matrix: widget.matrix)),
      );
    });
    _incomingCallSub = widget.matrix.voip?.onIncomingCall.listen((room) {
      final ctx = _navKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      final call = widget.matrix.call;
      if (call.isActive && call.roomId == room.id) return;
      if (!_incomingCallDialogs.add(room.id)) return;
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

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _verificationSub?.cancel();
    _incomingCallSub?.cancel();
    widget.matrix.removeListener(_onChanged);
    widget.theme.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Orex Messenger',
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
            )
          : LoginScreen(
              matrix: widget.matrix,
              version: widget.version,
              onLoggedIn: () => setState(() {}),
            ),
    );
  }
}

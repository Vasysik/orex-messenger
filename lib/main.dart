import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;

import 'core/config.dart';
import 'core/database.dart';
import 'core/matrix_service.dart';
import 'features/auth/login_screen.dart';
import 'features/call/incoming_call_screen.dart';
import 'features/home/home_shell.dart';
import 'features/settings/verification_screen.dart';
import 'theme/glass.dart';
import 'theme/orex_theme.dart';
import 'theme/theme_controller.dart';
import 'widgets/squirrel_mascot.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Показываем сплэш сразу, тяжёлую инициализацию делаем под ним.
  runApp(const OrexBootstrap());
}

/// Результат инициализации, который нужен приложению.
class _Services {
  _Services(this.matrix, this.theme);
  final MatrixService matrix;
  final ThemeController theme;
}

class OrexBootstrap extends StatefulWidget {
  const OrexBootstrap({super.key});

  @override
  State<OrexBootstrap> createState() => _OrexBootstrapState();
}

class _OrexBootstrapState extends State<OrexBootstrap> {
  late final Future<_Services> _future = _init();

  Future<_Services> _init() async {
    // 1) Шифрование. vodozemac ОБЯЗАН инициализироваться до client.init(),
    //    иначе Matrix SDK не включит E2EE. На web нужен wasm в web/pkg/
    //    (см. README / tool/setup_web_vodozemac.sh).
    //    Если wasm нет, vod.init() ВИСНЕТ — поэтому таймаут: приложение
    //    стартует без E2EE, а не зависает на белом экране.
    try {
      await vod.init().timeout(const Duration(seconds: 6));
    } catch (e) {
      debugPrint('vodozemac init skipped/failed, E2EE disabled: $e');
    }

    final theme = await ThemeController.load();
    final database = await buildOrexDatabase();
    final matrix = MatrixService(
      homeserver: Uri.parse(OrexConfig.homeserver),
      database: database,
    );
    await matrix.init();
    return _Services(matrix, theme);
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
          return const _MiniApp(child: SplashScreen());
        }
        return OrexApp(matrix: snap.data!.matrix, theme: snap.data!.theme);
      },
    );
  }
}

/// Минимальный MaterialApp-обёртка для сплэша/ошибки (до готовности темы).
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
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SquirrelMascot(size: 132, caption: 'Orex Messenger'),
              SizedBox(height: 28),
              SizedBox(
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
  const OrexApp({super.key, required this.matrix, required this.theme});
  final MatrixService matrix;
  final ThemeController theme;

  @override
  State<OrexApp> createState() => _OrexAppState();
}

class _OrexAppState extends State<OrexApp> {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  StreamSubscription? _verificationSub;
  StreamSubscription? _incomingCallSub;

  @override
  void initState() {
    super.initState();
    widget.matrix.addListener(_onChanged);
    widget.theme.addListener(_onChanged);
    // Входящие запросы на проверку (например, из Element X) → показываем
    // экран сравнения эмодзи поверх текущего.
    _verificationSub = widget.matrix.incomingVerifications.listen((kv) {
      _navKey.currentState?.push(
        MaterialPageRoute(builder: (_) => VerificationScreen(request: kv)),
      );
    });
    // Входящие звонки (кто-то начал звонок в комнате) → экран входящего.
    _incomingCallSub = widget.matrix.voip?.onIncomingCall.listen((gc) {
      _navKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) =>
              IncomingCallScreen(matrix: widget.matrix, groupCall: gc),
        ),
      );
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
      debugShowCheckedModeBanner: false,
      theme: OrexTheme.light,
      darkTheme: OrexTheme.dark,
      themeMode: widget.theme.mode,
      home: widget.matrix.isLoggedIn
          ? HomeShell(matrix: widget.matrix, theme: widget.theme)
          : LoginScreen(
              matrix: widget.matrix,
              onLoggedIn: () => setState(() {}),
            ),
    );
  }
}

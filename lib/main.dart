import 'package:flutter/material.dart';
import 'core/call_service.dart';
import 'core/database.dart';
import 'core/matrix_service.dart';
import 'features/auth/login_screen.dart';
import 'features/home/home_shell.dart';
import 'theme/orex_theme.dart';

/// Адреса вашего бэкенда.
const String kHomeserver = 'https://vasys.ru';
const String kJwtService = 'https://jwt.vasys.ru';
// LiveKit URL (wss://lk.vasys.ru) бэкенд возвращает сам в ответе /sfu/get.

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Для E2EE инициализируйте vodozemac здесь (см. README), например:
  //   await vod.init();

  // Кроссплатформенная БД: IndexedDB на web, sqflite/ffi на native.
  final database = await buildOrexDatabase();

  final matrix = MatrixService(
    homeserver: Uri.parse(kHomeserver),
    database: database,
  );
  await matrix.init();

  final calls = CallService(
    client: matrix.client,
    jwtServiceUrl: Uri.parse(kJwtService),
  );

  runApp(OrexApp(matrix: matrix, calls: calls));
}

class OrexApp extends StatefulWidget {
  const OrexApp({super.key, required this.matrix, required this.calls});
  final MatrixService matrix;
  final CallService calls;

  @override
  State<OrexApp> createState() => _OrexAppState();
}

class _OrexAppState extends State<OrexApp> {
  @override
  void initState() {
    super.initState();
    widget.matrix.addListener(_onAuthChanged);
  }

  void _onAuthChanged() => setState(() {});

  @override
  void dispose() {
    widget.matrix.removeListener(_onAuthChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Orex Messenger',
      debugShowCheckedModeBanner: false,
      theme: OrexTheme.light,
      darkTheme: OrexTheme.dark,
      themeMode: ThemeMode.dark, // «тёплая тёмная» по умолчанию
      home: widget.matrix.isLoggedIn
          ? HomeShell(matrix: widget.matrix, calls: widget.calls)
          : LoginScreen(
              matrix: widget.matrix,
              onLoggedIn: () => setState(() {}),
            ),
    );
  }
}

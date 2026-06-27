import 'package:flutter/material.dart';
import '../../core/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/squirrel_mascot.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.matrix, required this.onLoggedIn});
  final MatrixService matrix;
  final VoidCallback onLoggedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _inviteToken = TextEditingController();
  bool _isRegistering = false;
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    final username = _user.text.trim();
    final password = _pass.text;
    final token = _inviteToken.text.trim();

    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = 'Заполните все поля');
      return;
    }
    if (_isRegistering && token.isEmpty) {
      setState(() => _error = 'Введите код приглашения');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_isRegistering) {
        await widget.matrix.registerWithToken(
          username: username,
          password: password,
          token: token,
        );
      } else {
        await widget.matrix.login(
          username: username,
          password: password,
        );
      }
      widget.onLoggedIn();
    } catch (e) {
      // Переводим сырые Matrix-коды в понятные сообщения.
      String msg = e.toString();
      if (msg.contains('M_USER_IN_USE')) {
        msg = 'Это имя пользователя уже занято';
      } else if (msg.contains('M_INVALID_USERNAME')) {
        msg = 'Недопустимое имя пользователя (только латиница, цифры, _, -, .)';
      } else if (msg.contains('M_FORBIDDEN')) {
        msg = _isRegistering
            ? 'Неверный или истёкший код приглашения'
            : 'Неверный логин или пароль';
      } else if (msg.contains('M_UNKNOWN_TOKEN') || msg.contains('M_MISSING_TOKEN')) {
        msg = 'Недействительный токен приглашения';
      } else if (msg.contains('SocketException') || msg.contains('Connection refused')) {
        msg = 'Нет подключения к серверу. Проверьте интернет.';
      }
      setState(() => _error = msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: GlassPanel(
                borderRadius: 28,
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SquirrelMascot(size: 120),
                    const SizedBox(height: 16),
                    Text('Orex Messenger',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontSize: 22)),
                    const SizedBox(height: 4),
                    Text('Тепло. Быстро. Децентрализованно.',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 24),
                    _Field(controller: _user, hint: 'Имя пользователя'),
                    const SizedBox(height: 12),
                    _Field(controller: _pass, hint: 'Пароль', obscure: true),
                    if (_isRegistering) ...[
                      const SizedBox(height: 12),
                      _Field(controller: _inviteToken, hint: 'Код приглашения'),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Color(0xFFCF6679))),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: OrexColors.copper,
                          foregroundColor: OrexColors.cream,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: OrexColors.cream,
                                ),
                              )
                            : Text(_isRegistering ? 'Регистрация' : 'Войти'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              setState(() {
                                _isRegistering = !_isRegistering;
                                _error = null;
                              });
                            },
                      child: Text(
                        _isRegistering
                            ? 'Уже есть аккаунт? Войти'
                            : 'Ещё нет аккаунта? Зарегистрироваться',
                        style: const TextStyle(color: OrexColors.copper),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.hint,
    this.obscure = false,
  });

  final TextEditingController controller;
  final String hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: OrexColors.copper.withValues(alpha: 0.3),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: OrexColors.copper.withValues(alpha: 0.25),
          ),
        ),
      ),
    );
  }
}

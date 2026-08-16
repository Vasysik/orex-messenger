import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/config/app_version.dart';
import '../../core/logging/orex_logger.dart';
import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/orex_app_brand.dart';
import '../../shared/widgets/orex_download_corner_button.dart';
import 'password_recovery_dialog.dart';
import 'qr_login_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.matrix,
    required this.version,
    required this.onLoggedIn,
  });

  final MatrixService matrix;
  final OrexAppVersion version;
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
  bool _showPasswordRecovery = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _inviteToken.dispose();
    super.dispose();
  }

  Future<void> _openQrLogin() async {
    if (_busy) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => QrLoginScreen(
          matrix: widget.matrix,
          authenticated: false,
          onLoggedIn: widget.onLoggedIn,
        ),
      ),
    );
  }

  Future<void> _recoverPassword() async {
    if (_busy) return;
    final changed = await showOrexPasswordRecoveryDialog(
      context,
      matrix: widget.matrix,
    );
    if (!mounted || !changed) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Пароль изменён. Теперь можно войти.')),
    );
  }

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
      if (!mounted) return;
      widget.onLoggedIn();
    } catch (e) {
      final details = e.toString();
      final errcode = e is MatrixException ? e.errcode : null;
      OrexLog.d(
        'Auth',
        _isRegistering ? 'registration failed' : 'login failed',
        e,
      );
      String msg = _isRegistering
          ? 'Не удалось создать аккаунт. Попробуйте ещё раз.'
          : 'Не удалось войти. Попробуйте ещё раз.';
      var revealPasswordRecovery = false;
      if (errcode == 'M_USER_IN_USE' || details.contains('M_USER_IN_USE')) {
        msg = 'Это имя пользователя уже занято';
      } else if (errcode == 'M_INVALID_USERNAME' ||
          details.contains('M_INVALID_USERNAME')) {
        msg = 'Недопустимое имя пользователя (только латиница, цифры, _, -, .)';
      } else if (errcode == 'M_FORBIDDEN' ||
          details.contains('M_FORBIDDEN')) {
        msg = _isRegistering
            ? 'Неверный или истёкший код приглашения'
            : 'Неверный логин или пароль';
        revealPasswordRecovery = !_isRegistering;
      } else if (errcode == 'M_UNKNOWN_TOKEN' ||
          errcode == 'M_MISSING_TOKEN' ||
          details.contains('M_UNKNOWN_TOKEN') ||
          details.contains('M_MISSING_TOKEN')) {
        msg = 'Недействительный токен приглашения';
      } else if (details.contains('SocketException') ||
          details.contains('Connection refused')) {
        msg = 'Нет подключения к серверу. Проверьте интернет.';
      }
      if (mounted) {
        setState(() {
          _error = msg;
          if (revealPasswordRecovery) _showPasswordRecovery = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: GlassPanel(
                      borderRadius: 28,
                      padding: const EdgeInsets.all(28),
                      child: AutofillGroup(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            OrexBrandHeader(
                              version: widget.version,
                              iconSize: 116,
                            ),
                            const SizedBox(height: 26),
                            Text(
                              _isRegistering ? 'Создать аккаунт' : 'С возвращением',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 16),
                            _Field(
                              controller: _user,
                              hint: 'Имя пользователя',
                              suffixIcon: _QrLoginSlot(
                                visible: !_isRegistering,
                                enabled: !_busy,
                                onPressed: _openQrLogin,
                              ),
                              autofillHints: const [AutofillHints.username],
                              textInputAction: TextInputAction.next,
                            ),
                            const SizedBox(height: 12),
                            _Field(
                              controller: _pass,
                              hint: 'Пароль',
                              obscure: true,
                              suffixIcon: _isRegistering
                                  ? null
                                  : _PasswordRecoverySlot(
                                      visible: _showPasswordRecovery,
                                      enabled: !_busy,
                                      onPressed: _recoverPassword,
                                    ),
                              autofillHints: _isRegistering
                                  ? const [AutofillHints.newPassword]
                                  : const [AutofillHints.password],
                              textInputAction: _isRegistering
                                  ? TextInputAction.next
                                  : TextInputAction.done,
                              onSubmitted: _isRegistering || _busy
                                  ? null
                                  : (_) => _submit(),
                            ),
                            if (_isRegistering) ...[
                              const SizedBox(height: 12),
                              _Field(
                                controller: _inviteToken,
                                hint: 'Код приглашения',
                                textInputAction: TextInputAction.done,
                                onSubmitted: _busy ? null : (_) => _submit(),
                              ),
                            ],
                            if (_error != null) ...[
                              const SizedBox(height: 12),
                              Semantics(
                                liveRegion: true,
                                child: Text(
                                  _error!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Color(0xFFCF6679)),
                                ),
                              ),
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
                                    ? const SizedBox.square(
                                        dimension: 22,
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
                                        _showPasswordRecovery = false;
                                        _error = null;
                                      });
                                    },
                              child: Text(
                                _isRegistering
                                    ? 'Уже есть аккаунт? Войти'
                                    : 'Ещё нет аккаунта? Зарегистрироваться',
                                textAlign: TextAlign.center,
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
            ),
            const Positioned(
              right: 18,
              bottom: 18,
              child: SafeArea(child: OrexDownloadCornerButton()),
            ),
          ],
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
    this.suffixIcon,
    this.autofillHints,
    this.textInputAction,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final Widget? suffixIcon;
  final Iterable<String>? autofillHints;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      autofillHints: autofillHints,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      autocorrect: false,
      enableSuggestions: !obscure,
      decoration: InputDecoration(
        hintText: hint,
        suffixIcon: suffixIcon,
        suffixIconConstraints: suffixIcon == null
            ? null
            : const BoxConstraints(minWidth: 54, minHeight: 48),
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

class _PasswordRecoverySlot extends StatelessWidget {
  const _PasswordRecoverySlot({
    required this.visible,
    required this.enabled,
    required this.onPressed,
  });

  final bool visible;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      excluding: !visible,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          child: Tooltip(
            message: 'Восстановить пароль',
            child: IconButton(
              onPressed: enabled ? onPressed : null,
              style: IconButton.styleFrom(
                fixedSize: const Size.square(42),
                minimumSize: const Size.square(42),
                padding: EdgeInsets.zero,
                foregroundColor: OrexColors.copper,
              ),
              icon: const Icon(Icons.help_outline, size: 22),
            ),
          ),
        ),
      ),
    );
  }
}

class _QrLoginSlot extends StatelessWidget {
  const _QrLoginSlot({
    required this.visible,
    required this.enabled,
    required this.onPressed,
  });

  final bool visible;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      excluding: !visible,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          child: Tooltip(
            message: 'Войти по QR-коду',
            child: IconButton(
              onPressed: enabled ? onPressed : null,
              style: IconButton.styleFrom(
                fixedSize: const Size.square(42),
                minimumSize: const Size.square(42),
                padding: EdgeInsets.zero,
                foregroundColor: OrexColors.copper,
              ),
              icon: const Icon(Icons.qr_code_scanner, size: 22),
            ),
          ),
        ),
      ),
    );
  }
}

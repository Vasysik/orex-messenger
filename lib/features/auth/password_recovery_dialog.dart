import 'package:flutter/material.dart';

import '../../core/logging/orex_logger.dart';
import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/orex_theme.dart';

Future<bool> showOrexPasswordRecoveryDialog(
  BuildContext context, {
  required MatrixService matrix,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PasswordRecoveryDialog(matrix: matrix),
  );
  return result == true;
}

enum _RecoveryStep { email, newPassword }

class _PasswordRecoveryDialog extends StatefulWidget {
  const _PasswordRecoveryDialog({required this.matrix});

  final MatrixService matrix;

  @override
  State<_PasswordRecoveryDialog> createState() =>
      _PasswordRecoveryDialogState();
}

class _PasswordRecoveryDialogState extends State<_PasswordRecoveryDialog> {
  final _email = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();
  _RecoveryStep _step = _RecoveryStep.email;
  OrexPasswordRecoverySession? _session;
  bool _busy = false;
  String? _error;
  String? _notice;

  @override
  void dispose() {
    _email.dispose();
    _newPassword.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _requestEmail() async {
    final email = _email.text.trim();
    if (!_looksLikeEmail(email)) {
      setState(() => _error = 'Введите корректный адрес почты');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final session = await widget.matrix.requestPasswordRecoveryEmail(
        email: email,
      );
      if (!mounted) return;
      setState(() {
        _session = session;
        _step = _RecoveryStep.newPassword;
        _notice = 'Письмо отправлено на $email. Откройте ссылку из письма, '
            'затем вернитесь сюда и задайте новый пароль.';
      });
    } catch (error) {
      OrexLog.d('Auth', 'password recovery email failed', error);
      if (mounted) setState(() => _error = _recoveryError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resendEmail() async {
    final session = _session;
    if (session == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final updated = await widget.matrix.resendPasswordRecoveryEmail(session);
      if (!mounted) return;
      setState(() {
        _session = updated;
        _notice = 'Новое письмо отправлено на ${updated.email}.';
      });
    } catch (error) {
      OrexLog.d('Auth', 'password recovery resend failed', error);
      if (mounted) setState(() => _error = _recoveryError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    final session = _session;
    if (session == null) return;
    final password = _newPassword.text;
    if (password.length < 6) {
      setState(() => _error = 'Пароль должен быть не короче 6 символов');
      return;
    }
    if (password != _confirmPassword.text) {
      setState(() => _error = 'Пароли не совпадают');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await widget.matrix.finishPasswordRecovery(
        session: session,
        newPassword: password,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      OrexLog.d('Auth', 'password recovery finish failed', error);
      if (mounted) {
        setState(() => _error = _recoveryError(error, finishing: true));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enteringEmail = _step == _RecoveryStep.email;
    return AlertDialog(
      title: const Text('Восстановление доступа'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  enteringEmail
                      ? 'Укажите почту, привязанную к аккаунту Orex.'
                      : 'После подтверждения ссылки из письма задайте новый '
                          'пароль прямо в Orex.',
                ),
                const SizedBox(height: 16),
                if (enteringEmail)
                  TextField(
                    controller: _email,
                    autofocus: true,
                    enabled: !_busy,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    textInputAction: TextInputAction.done,
                    onSubmitted: _busy ? null : (_) => _requestEmail(),
                    decoration: const InputDecoration(
                      labelText: 'Электронная почта',
                      prefixIcon: Icon(Icons.alternate_email),
                    ),
                  )
                else ...[
                  TextField(
                    controller: _newPassword,
                    autofocus: true,
                    enabled: !_busy,
                    obscureText: true,
                    autofillHints: const [AutofillHints.newPassword],
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Новый пароль',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirmPassword,
                    enabled: !_busy,
                    obscureText: true,
                    autofillHints: const [AutofillHints.newPassword],
                    textInputAction: TextInputAction.done,
                    onSubmitted: _busy ? null : (_) => _finish(),
                    decoration: const InputDecoration(
                      labelText: 'Повторите пароль',
                      prefixIcon: Icon(Icons.lock_reset),
                    ),
                  ),
                ],
                if (_notice != null) ...[
                  const SizedBox(height: 14),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _notice!,
                      style: const TextStyle(color: OrexColors.copper),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Color(0xFFCF6679)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        if (!enteringEmail)
          TextButton(
            onPressed: _busy ? null : _resendEmail,
            child: const Text('Отправить ещё раз'),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : enteringEmail
                  ? _requestEmail
                  : _finish,
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(enteringEmail ? 'Отправить письмо' : 'Сменить пароль'),
        ),
      ],
    );
  }
}

bool _looksLikeEmail(String value) {
  final at = value.indexOf('@');
  return at > 0 && at < value.length - 3 && value.indexOf('.', at) > at + 1;
}

String _recoveryError(Object error, {bool finishing = false}) {
  if (error is OrexAuthProtocolException) {
    return switch (error.code) {
      'M_LIMIT_EXCEEDED' =>
        'Слишком много попыток. Подождите немного и повторите.',
      'M_THREEPID_AUTH_FAILED' =>
        'Ссылка из письма ещё не подтверждена или уже истекла.',
      'M_THREEPID_NOT_FOUND' =>
        'Не удалось начать восстановление для этого адреса.',
      _ => error.message,
    };
  }
  final text = error.toString();
  if (text.contains('SocketException') ||
      text.contains('ClientException') ||
      text.contains('TimeoutException')) {
    return 'Нет подключения к серверу. Проверьте интернет.';
  }
  return finishing
      ? 'Не удалось сменить пароль. Проверьте ссылку из письма.'
      : 'Не удалось отправить письмо. Попробуйте ещё раз.';
}

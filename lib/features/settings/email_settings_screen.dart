import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/logging/orex_logger.dart';
import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/orex_dialogs.dart';

class EmailSettingsScreen extends StatefulWidget {
  const EmailSettingsScreen({super.key, required this.matrix});

  final MatrixService matrix;

  @override
  State<EmailSettingsScreen> createState() => _EmailSettingsScreenState();
}

class _EmailSettingsScreenState extends State<EmailSettingsScreen> {
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    widget.matrix.addListener(_onMatrixChanged);
    _refresh();
  }

  @override
  void dispose() {
    widget.matrix.removeListener(_onMatrixChanged);
    super.dispose();
  }

  void _onMatrixChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    await widget.matrix.refreshAccountEmails(force: true);
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _bind({required bool replaceExisting}) async {
    final result = await showDialog<_EmailBindingResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _EmailBindingDialog(
        matrix: widget.matrix,
        replaceAddresses: replaceExisting
            ? widget.matrix.accountEmails
            : const <String>[],
      ),
    );
    if (!mounted || result == null) return;

    final messenger = ScaffoldMessenger.of(context);
    if (result.failedRemovals.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            replaceExisting
                ? 'Почта изменена на ${result.email}'
                : 'Почта ${result.email} привязана',
          ),
        ),
      );
    } else {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Новая почта привязана, но старый адрес не удалось отвязать. '
            'Попробуйте удалить его отдельно.',
          ),
        ),
      );
    }
    await _refresh();
  }

  Future<void> _unlink(String address) async {
    final isLast = widget.matrix.accountEmails.length == 1;
    final confirmed = await showOrexConfirmDialog(
      context,
      title: 'Отвязать почту?',
      message: isLast
          ? 'Без привязанной почты восстановить пароль через письмо будет '
              'невозможно. Отвязать $address?'
          : 'Адрес $address больше нельзя будет использовать для '
              'восстановления доступа.',
      confirmLabel: 'Отвязать',
      danger: true,
    );
    if (!confirmed || !mounted) return;

    showOrexBlockingProgressDialog(context);
    try {
      await widget.matrix.unlinkAccountEmail(address);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Почта отвязана')),
      );
    } catch (error) {
      OrexLog.d('Account', 'unlink email failed', error);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_emailBindingError(error, unlinking: true))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final emails = widget.matrix.accountEmails;
    final loaded = widget.matrix.accountEmailsLoaded;
    final loading = _refreshing && !loaded;
    final loadFailed = widget.matrix.accountEmailsLoadFailed && !loaded;

    return AmbientBackground(
      groupBackdrops: true,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('Почта'),
          actionsPadding: const EdgeInsets.only(right: 8),
          actions: [
            IconButton(
              tooltip: 'Обновить',
              onPressed: _refreshing ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : loadFailed
                ? _EmailLoadError(onRetry: _refresh)
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      GlassPanel(
                        borderRadius: 20,
                        padding: const EdgeInsets.all(18),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: OrexColors.copper.withValues(alpha: 0.14),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                emails.isEmpty
                                    ? Icons.mark_email_unread_outlined
                                    : Icons.mark_email_read_outlined,
                                color: OrexColors.copper,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    emails.isEmpty
                                        ? 'Почта не привязана'
                                        : 'Почта привязана',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    emails.isEmpty
                                        ? 'Привяжите адрес, чтобы восстановить '
                                            'доступ к аккаунту, если забудете '
                                            'пароль.'
                                        : 'Подтверждённый адрес можно '
                                            'использовать для восстановления '
                                            'пароля.',
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (emails.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        for (final address in emails)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: GlassPanel(
                              borderRadius: 18,
                              padding: EdgeInsets.zero,
                              child: ListTile(
                                leading: const Icon(
                                  Icons.alternate_email,
                                  color: OrexColors.copper,
                                ),
                                title: Text(address),
                                subtitle: const Text('Подтверждена'),
                                trailing: IconButton(
                                  tooltip: 'Отвязать почту',
                                  onPressed: () => _unlink(address),
                                  icon: const Icon(Icons.link_off),
                                ),
                              ),
                            ),
                          ),
                      ],
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => _bind(
                            replaceExisting: emails.isNotEmpty,
                          ),
                          icon: Icon(
                            emails.isEmpty ? Icons.add_link : Icons.swap_horiz,
                          ),
                          label: Text(
                            emails.isEmpty
                                ? 'Привязать почту'
                                : 'Перепривязать почту',
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Orex не хранит пароль от почты. Подтверждение '
                        'выполняется одноразовой ссылкой, которую отправляет '
                        'сервер.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
      ),
    );
  }
}

class _EmailLoadError extends StatelessWidget {
  const _EmailLoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: GlassPanel(
            borderRadius: 20,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.cloud_off_outlined,
                  size: 42,
                  color: OrexColors.copper,
                ),
                const SizedBox(height: 12),
                Text(
                  'Не удалось проверить привязанную почту',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Проверьте подключение к серверу и повторите попытку.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Повторить'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmailBindingResult {
  const _EmailBindingResult({
    required this.email,
    required this.failedRemovals,
  });

  final String email;
  final List<String> failedRemovals;
}

enum _EmailBindingStep { address, confirmation }

class _EmailBindingDialog extends StatefulWidget {
  const _EmailBindingDialog({
    required this.matrix,
    required this.replaceAddresses,
  });

  final MatrixService matrix;
  final List<String> replaceAddresses;

  @override
  State<_EmailBindingDialog> createState() => _EmailBindingDialogState();
}

class _EmailBindingDialogState extends State<_EmailBindingDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  _EmailBindingStep _step = _EmailBindingStep.address;
  OrexEmailBindingSession? _session;
  bool _busy = false;
  String? _notice;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _requestEmail() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
      _error = null;
    });
    try {
      final session = await widget.matrix.requestAccountEmailBinding(
        email: _email.text,
      );
      if (!mounted) return;
      setState(() {
        _session = session;
        _step = _EmailBindingStep.confirmation;
        _notice = 'Письмо отправлено на ${session.email}. Откройте ссылку '
            'из письма, затем вернитесь сюда.';
      });
    } catch (error) {
      OrexLog.d('Account', 'request email binding failed', error);
      if (mounted) setState(() => _error = _emailBindingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    final session = _session;
    if (_busy || session == null) return;
    setState(() {
      _busy = true;
      _notice = null;
      _error = null;
    });
    try {
      final updated = await widget.matrix.resendAccountEmailBinding(session);
      if (!mounted) return;
      setState(() {
        _session = updated;
        _notice = 'Новое письмо отправлено на ${updated.email}.';
      });
    } catch (error) {
      OrexLog.d('Account', 'resend email binding failed', error);
      if (mounted) setState(() => _error = _emailBindingError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    final session = _session;
    if (_busy || session == null) return;
    if (_password.text.isEmpty) {
      setState(() => _error = 'Введите текущий пароль аккаунта');
      return;
    }

    setState(() {
      _busy = true;
      _notice = null;
      _error = null;
    });
    var dialogClosed = false;
    try {
      await widget.matrix.finishAccountEmailBinding(
        session: session,
        currentPassword: _password.text,
      );

      final failedRemovals = <String>[];
      for (final oldAddress in widget.replaceAddresses) {
        if (oldAddress.toLowerCase() == session.email.toLowerCase()) continue;
        try {
          await widget.matrix.unlinkAccountEmail(oldAddress);
        } catch (error) {
          failedRemovals.add(oldAddress);
          OrexLog.d('Account', 'remove replaced email failed', error);
        }
      }
      if (!mounted) return;
      dialogClosed = true;
      Navigator.pop(
        context,
        _EmailBindingResult(
          email: session.email,
          failedRemovals: List<String>.unmodifiable(failedRemovals),
        ),
      );
    } catch (error) {
      OrexLog.d('Account', 'finish email binding failed', error);
      if (mounted) {
        setState(() => _error = _emailBindingError(error, finishing: true));
      }
    } finally {
      if (mounted && !dialogClosed) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enteringAddress = _step == _EmailBindingStep.address;
    return AlertDialog(
      title: Text(
        widget.replaceAddresses.isEmpty
            ? 'Привязать почту'
            : 'Перепривязать почту',
      ),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: AutofillGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  enteringAddress
                      ? 'Укажите новый адрес. Сервер отправит письмо со '
                          'ссылкой подтверждения.'
                      : 'После перехода по ссылке подтвердите действие '
                          'текущим паролем Orex.',
                ),
                const SizedBox(height: 16),
                if (enteringAddress)
                  TextField(
                    controller: _email,
                    enabled: !_busy,
                    autofocus: true,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    textInputAction: TextInputAction.done,
                    onSubmitted: _busy ? null : (_) => _requestEmail(),
                    decoration: const InputDecoration(
                      labelText: 'Электронная почта',
                      prefixIcon: Icon(Icons.alternate_email),
                    ),
                  )
                else
                  TextField(
                    controller: _password,
                    enabled: !_busy,
                    autofocus: true,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    textInputAction: TextInputAction.done,
                    onSubmitted: _busy ? null : (_) => _finish(),
                    decoration: const InputDecoration(
                      labelText: 'Текущий пароль',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
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
        if (!enteringAddress)
          TextButton(
            onPressed: _busy ? null : _resend,
            child: const Text('Отправить ещё раз'),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : enteringAddress
                  ? _requestEmail
                  : _finish,
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(enteringAddress ? 'Отправить письмо' : 'Подтвердить'),
        ),
      ],
    );
  }
}

String _emailBindingError(
  Object error, {
  bool finishing = false,
  bool unlinking = false,
}) {
  if (error is OrexAuthProtocolException) return error.message;
  if (error is MatrixException) {
    return switch (error.errcode) {
      'M_THREEPID_IN_USE' => 'Этот адрес уже привязан к другому аккаунту.',
      'M_THREEPID_AUTH_FAILED' =>
        'Ссылка из письма ещё не подтверждена или уже истекла.',
      'M_FORBIDDEN' => finishing
          ? 'Неверный текущий пароль.'
          : 'Сервер отклонил операцию.',
      'M_LIMIT_EXCEEDED' =>
        'Слишком много попыток. Подождите немного и повторите.',
      _ => unlinking
          ? 'Не удалось отвязать почту.'
          : 'Не удалось изменить привязанную почту.',
    };
  }
  final text = error.toString();
  if (text.contains('SocketException') ||
      text.contains('ClientException') ||
      text.contains('TimeoutException')) {
    return 'Нет подключения к серверу. Проверьте интернет.';
  }
  if (unlinking) return 'Не удалось отвязать почту.';
  return finishing
      ? 'Не удалось подтвердить почту. Проверьте ссылку из письма.'
      : 'Не удалось отправить письмо. Попробуйте ещё раз.';
}

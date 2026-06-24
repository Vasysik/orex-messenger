import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import 'verification_screen.dart';

/// Экран подтверждения ТЕКУЩЕЙ сессии. Решает проблему «владелец не подтверждён»
/// в других клиентах: пока эта сессия не подписана кросс-подписью, Element X и
/// прочие помечают её как непроверенную.
///
/// Два пути (как в Element):
///   • «С другого устройства» — самопроверка по эмодзи. Запрос уходит на ваши
///     уже доверенные сессии (например, Element X), там сравниваете эмодзи,
///     после чего то устройство кросс-подписывает эту сессию.
///   • «Ключом восстановления» — без второго устройства: вводим ключ
///     восстановления (или passphrase), SDK разблокирует SSSS и сам
///     кросс-подписывает это устройство.
class VerifySessionScreen extends StatefulWidget {
  const VerifySessionScreen({super.key, required this.matrix});
  final MatrixService matrix;

  @override
  State<VerifySessionScreen> createState() => _VerifySessionScreenState();
}

class _VerifySessionScreenState extends State<VerifySessionScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _verifyFromOtherDevice() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final kv = await widget.matrix.startSelfVerification();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => VerificationScreen(request: kv)),
      );
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyWithRecoveryKey() async {
    final controller = TextEditingController();
    final key = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ключ восстановления'),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(
            hintText: 'Ключ восстановления или passphrase',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Подтвердить'),
          ),
        ],
      ),
    );
    if (key == null || key.isEmpty) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.matrix.verifyWithRecoveryKey(key);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сессия подтверждена')),
      );
      Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Не удалось: проверьте ключ восстановления.\n$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askPassword() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Подтвердите паролем'),
        content: TextField(
          controller: c,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'Пароль от аккаунта'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('ОК'),
          ),
        ],
      ),
    );
  }

  Future<void> _setupCrossSigning() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final recoveryKey =
          await widget.matrix.setupCrossSigning(askPassword: _askPassword);
      if (!mounted) return;
      await _showRecoveryKey(recoveryKey);
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showRecoveryKey(String key) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Сохраните ключ восстановления'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Это ваш ключ безопасности. Запишите его и храните в надёжном '
              'месте: им подтверждают новые сессии и восстанавливают доступ к '
              'зашифрованным сообщениям. Без него восстановить переписку нельзя.',
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                key,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: key));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Скопировано')),
                );
              }
            },
            child: const Text('Копировать'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Я сохранил'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final available = widget.matrix.crossSigningAvailable;

    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('Подтверждение сессии'),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: available ? _chooser() : _noCrossSigning(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chooser() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.verified_user, size: 54, color: OrexColors.copper),
        const SizedBox(height: 16),
        Text('Подтвердите эту сессию',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontSize: 18)),
        const SizedBox(height: 8),
        Text(
          'Пока сессия не подтверждена, другие ваши клиенты помечают её как '
          'непроверенную. Выберите способ:',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        if (_busy) ...[
          const CircularProgressIndicator(color: OrexColors.copper),
          const SizedBox(height: 16),
          const Text('Ожидаем другое устройство…'),
        ] else ...[
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: OrexColors.copper,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: _verifyFromOtherDevice,
            icon: const Icon(Icons.devices),
            label: const Text('С другого устройства (эмодзи)'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: _verifyWithRecoveryKey,
            icon: const Icon(Icons.key),
            label: const Text('Ключом восстановления'),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFCF6679))),
        ],
      ],
    );
  }

  Widget _noCrossSigning() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.shield_outlined, size: 54, color: OrexColors.copper),
        const SizedBox(height: 16),
        Text('Настроить проверку подлинности',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontSize: 18)),
        const SizedBox(height: 8),
        Text(
          'На аккаунте ещё нет кросс-подписи и ключа восстановления. Создайте их '
          'прямо здесь (аналог «Secure Backup» в Element): появится ключ '
          'восстановления, а эта сессия станет доверенной — другие клиенты '
          'перестанут считать её непроверенной.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        if (_busy) ...[
          const CircularProgressIndicator(color: OrexColors.copper),
          const SizedBox(height: 12),
          const Text('Настраиваем…'),
        ] else
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: OrexColors.copper,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: _setupCrossSigning,
            icon: const Icon(Icons.shield),
            label: const Text('Создать ключ восстановления'),
          ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFCF6679))),
        ],
      ],
    );
  }
}

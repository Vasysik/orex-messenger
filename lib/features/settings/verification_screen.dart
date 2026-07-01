import 'package:flutter/material.dart';
import 'package:matrix/encryption/utils/key_verification.dart';

import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';

/// Наш экран подтверждения сессии по эмодзи (SAS) — аналог проверки в Element,
/// но свой. Убирает предупреждение «зашифровано устройством, не проверенным
/// владельцем»: после сравнения эмодзи сессии взаимно подписываются.
class VerificationScreen extends StatefulWidget {
  const VerificationScreen({super.key, required this.request, this.matrix});
  final KeyVerification request;

  /// Нужен, чтобы после успешной проверки обновить плашку «не подтверждена»
  /// без перезагрузки вкладки (статус кросс-подписи доезжает с задержкой).
  final MatrixService? matrix;

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  KeyVerification get kv => widget.request;

  @override
  void initState() {
    super.initState();
    kv.onUpdate = () {
      if (kv.state == KeyVerificationState.done) {
        final m = widget.matrix;
        if (m != null) {
          for (final ms in const [300, 1500, 3500]) {
            Future.delayed(Duration(milliseconds: ms), m.refresh);
          }
          // Ключ бэкапа доезжает через SSSS чуть позже — тянем всю историю.
          Future.delayed(const Duration(seconds: 2), m.restoreKeyBackup);
        }
      }
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    kv.onUpdate = null;
    super.dispose();
  }

  Future<void> _enterRecoveryKey() async {
    final c = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ключ восстановления'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Ключ восстановления или passphrase',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('ОК'),
          ),
        ],
      ),
    );
    if (value != null && value.isNotEmpty) {
      await kv.openSSSS(keyOrPassphrase: value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('Проверка сессии'),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _content(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content() {
    switch (kv.state) {
      case KeyVerificationState.askAccept:
        return _prompt(
          icon: Icons.verified_user,
          title: 'Другая сессия хочет провериться',
          subtitle: kv.deviceId ?? kv.userId,
          actions: [
            _btn('Отклонить', kv.rejectVerification, danger: true),
            _btn('Принять', kv.acceptVerification),
          ],
        );

      case KeyVerificationState.askSas:
      case KeyVerificationState.waitingSas:
        return _emojiCompare();

      case KeyVerificationState.askSSSS:
        return _prompt(
          icon: Icons.key,
          title: 'Нужен ключ восстановления',
          subtitle: 'Введите ключ восстановления, чтобы продолжить проверку.',
          actions: [_btn('Ввести ключ', _enterRecoveryKey)],
        );

      case KeyVerificationState.done:
        return _prompt(
          icon: Icons.check_circle,
          iconColor: OrexColors.online,
          title: 'Сессия проверена',
          subtitle: 'Сообщения от неё больше не помечаются как непроверенные.',
          actions: [_btn('Готово', () => Navigator.of(context).pop())],
        );

      case KeyVerificationState.error:
        return _prompt(
          icon: Icons.error_outline,
          iconColor: const Color(0xFFCF6679),
          title: 'Проверка не удалась',
          subtitle: 'Попробуйте начать заново.',
          actions: [_btn('Закрыть', () => Navigator.of(context).pop())],
        );

      default:
        // waitingAccept / askChoice / QR-состояния
        return const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: OrexColors.copper),
            SizedBox(height: 16),
            Text('Ожидание другой сессии…'),
          ],
        );
    }
  }

  Widget _emojiCompare() {
    final emojis = kv.sasEmojis;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Сравните эмодзи',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 18)),
        const SizedBox(height: 8),
        Text('Они должны совпадать на обеих сессиях, в том же порядке.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 20),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 14,
          runSpacing: 16,
          children: emojis
              .map((e) => SizedBox(
                    width: 88,
                    child: Column(
                      children: [
                        Text(e.emoji, style: const TextStyle(fontSize: 40)),
                        const SizedBox(height: 4),
                        Text(e.name,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ))
              .toList(),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            _btn('Не совпадают', kv.rejectVerification, danger: true),
            _btn('Совпадают', kv.acceptSas),
          ],
        ),
      ],
    );
  }

  Widget _prompt({
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> actions,
    Color? iconColor,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 54, color: iconColor ?? OrexColors.copper),
        const SizedBox(height: 16),
        Text(title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 18)),
        const SizedBox(height: 8),
        Text(subtitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 24),
        Row(children: actions),
      ],
    );
  }

  Widget _btn(String label, VoidCallback onTap, {bool danger = false}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: const Color(0xFFCF6679))
              : FilledButton.styleFrom(backgroundColor: OrexColors.copper),
          onPressed: onTap,
          child: Text(label),
        ),
      ),
    );
  }
}

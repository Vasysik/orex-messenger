import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';

/// Хранилище ключей (онлайн-бэкап ключей сообщений): статус,
/// время последнего бэкапа и тумблер автоматического.
class KeyStorageScreen extends StatefulWidget {
  const KeyStorageScreen({super.key, required this.matrix});
  final MatrixService matrix;

  @override
  State<KeyStorageScreen> createState() => _KeyStorageScreenState();
}

class _KeyStorageScreenState extends State<KeyStorageScreen> {
  @override
  void initState() {
    super.initState();
    // Принудительно запрашиваем актуальный статус с сервера при входе на экран
    widget.matrix.updateServerBackupVersion();
  }

  String _ago(DateTime? t) {
    if (t == null) return 'ещё не выполнялся';
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 30) return 'только что';
    if (d.inMinutes < 1) return '${d.inSeconds} с назад';
    if (d.inMinutes < 60) return '${d.inMinutes} мин назад';
    if (d.inHours < 24) return '${d.inHours} ч назад';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
  }

  /// Запрашивает пароль от аккаунта (нужен для UIA при включении бэкапа).
  Future<String?> _askPassword(BuildContext context) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Требуется пароль'),
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
              child: const Text('ОК')),
        ],
      ),
    );
  }

  /// Запрашивает ключ восстановления (нужен когда SSSS заблокирован).
  Future<String?> _askRecoveryKey(BuildContext context) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Ключ восстановления'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ключи безопасности локально заблокированы.\n'
              'Введите ключ восстановления (или passphrase), чтобы открыть к ним доступ и загрузить хранилище на сервер.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: c,
              autofocus: true,
              obscureText: true,
              decoration:
                  const InputDecoration(hintText: 'Ключ восстановления'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('ОК')),
        ],
      ),
    );
  }

  /// Показывает индикатор загрузки поверх экрана.
  void _showProgress(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: OrexColors.copper),
      ),
    );
  }

  /// Включает хранилище ключей. Если SSSS заблокирован — запрашивает
  /// ключ восстановления и повторяет попытку.
  Future<void> _enableKeyStorage() async {
    bool retry = false;
    String? enteredKey;
    do {
      retry = false;
      if (!mounted) return;
      _showProgress(context);

      try {
        if (!mounted) return;
        final newRecoveryKey = await widget.matrix.enableKeyBackup(
          askPassword: () => _askPassword(context),
          recoveryKey: enteredKey,
        );
        if (mounted) {
          Navigator.pop(context); // закрываем индикатор
          if (newRecoveryKey != null && newRecoveryKey.isNotEmpty) {
            await _showNewRecoveryKey(context, newRecoveryKey);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('Хранилище ключей успешно включено')),
            );
          }
        }
      } catch (e) {
        if (mounted) Navigator.pop(context); // закрываем индикатор

        if (e.toString().contains('recovery_key_required')) {
          if (!mounted) return;
          final key = await _askRecoveryKey(context);
          if (key != null && key.isNotEmpty) {
            if (!mounted) return;
            _showProgress(context);
            try {
              await widget.matrix.verifyWithRecoveryKey(key);
              enteredKey =
                  key; // Запоминаем введённый ключ для повторной попытки [1.3.1]
              if (mounted) Navigator.pop(context); // закрываем индикатор
              retry = true; // SSSS разблокирован, повторяем включение бэкапа
            } catch (e2) {
              if (mounted) {
                Navigator.pop(context); // закрываем индикатор
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Неверный ключ восстановления: $e2')),
                );
              }
            }
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Ошибка при включении бэкапа: $e')),
            );
          }
        }
      }
    } while (retry);
  }

  /// Показывает сгенерированный новый ключ восстановления на экране
  Future<void> _showNewRecoveryKey(BuildContext context, String key) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Новый ключ восстановления'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Хранилище ключей включено, и для него создан новый ключ восстановления. '
              'Скопируйте его и храните в надёжном месте:',
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
                  const SnackBar(
                      content: Text('Ключ скопирован в буфер обмена')),
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

  /// Запрашивает подтверждение и отключает хранилище ключей.
  Future<void> _confirmDisable(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отключить хранилище?'),
        content: const Text(
          'Резервная копия ваших ключей на сервере будет удалена. '
          'При выходе из учётной записи на этом устройстве вы можете навсегда потерять доступ к зашифрованной переписке.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFCF6679),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Отключить'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    try {
      await widget.matrix.disableKeyBackup();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Хранилище ключей отключено')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка при отключении: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('Хранилище ключей'),
        ),
        body: AnimatedBuilder(
          animation: widget.matrix,
          builder: (context, _) {
            final enabled = widget.matrix.keyBackupEnabled;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Статус бэкапа — кликабелен когда выключен (включить)
                GlassPanel(
                  borderRadius: 18,
                  padding: EdgeInsets.zero,
                  tint: enabled ? null : const Color(0xFFCF6679),
                  opacity: enabled ? 0.55 : 0.12,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: enabled ? null : _enableKeyStorage,
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Row(
                          children: [
                            Icon(
                              enabled ? Icons.cloud_done : Icons.cloud_off,
                              color: enabled
                                  ? OrexColors.online
                                  : const Color(0xFFCF6679),
                              size: 30,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    enabled
                                        ? 'Включено'
                                        : 'Отключено (нажмите для включения)',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: enabled
                                              ? null
                                              : const Color(0xFFCF6679),
                                        ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    enabled
                                        ? 'Ключи сообщений хранятся на сервере — история восстановится на новых устройствах.'
                                        : 'Нажмите, чтобы запустить и настроить облачное хранилище ключей на сервере.',
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            if (!enabled)
                              const Icon(
                                Icons.chevron_right,
                                color: Color(0xFFCF6679),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Предупреждение: автобэкап выключен (только когда бэкап включён)
                if (enabled && !widget.matrix.autoBackup)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: GlassPanel(
                      borderRadius: 18,
                      padding: const EdgeInsets.all(16),
                      opacity: 0.12,
                      tint: Colors.orange,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.warning_amber_rounded,
                                  color: Color(0xFFE0A03A)),
                              SizedBox(width: 8),
                              Text(
                                'Автобэкап выключен',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFE0A03A),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Новые ключи шифрования не будут отправляться на сервер автоматически. '
                            'Если вы забудете сделать ручной бэкап, часть сообщений может быть потеряна при выходе.',
                            style: TextStyle(fontSize: 12),
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            style: FilledButton.styleFrom(
                                backgroundColor: OrexColors.copper),
                            onPressed: () => widget.matrix.setAutoBackup(true),
                            child: const Text('Включить автоматический бэкап'),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Настройки и действия (только когда бэкап включён)
                if (enabled) ...[
                  GlassPanel(
                    borderRadius: 18,
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.schedule,
                              color: OrexColors.copper),
                          title: const Text('Последний бэкап'),
                          subtitle: Text(_ago(widget.matrix.lastBackup)),
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          secondary: const Icon(Icons.autorenew,
                              color: OrexColors.copper),
                          title: const Text('Автоматический бэкап'),
                          subtitle: const Text(
                              'Новые сообщения сохраняются автоматически'),
                          value: widget.matrix.autoBackup,
                          onChanged: widget.matrix.setAutoBackup,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: OrexColors.copper,
                      minimumSize: const Size.fromHeight(48),
                    ),
                    icon: widget.matrix.backupInProgress
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: OrexColors.cream),
                          )
                        : const Icon(Icons.backup),
                    label: Text(widget.matrix.backupInProgress
                        ? 'Бэкап…'
                        : 'Создать резервную копию сейчас'),
                    onPressed: widget.matrix.backupInProgress
                        ? null
                        : widget.matrix.backupNow,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFCF6679),
                      side: const BorderSide(color: Color(0xFFCF6679)),
                      minimumSize: const Size.fromHeight(48),
                    ),
                    icon: const Icon(Icons.cloud_off),
                    label: const Text('Отключить хранилище ключей'),
                    onPressed: () => _confirmDisable(context),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Полный бэкап выгружает все ключи, какие есть на этом '
                    'устройстве. Сообщения, ключей которых здесь нет, '
                    'восстановить нельзя.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

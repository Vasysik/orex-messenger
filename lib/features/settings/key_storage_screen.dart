import 'package:flutter/material.dart';

import '../../core/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import 'verify_session_screen.dart';

/// Хранилище ключей (онлайн-бэкап ключей сообщений): статус, время последнего
/// бэкапа, ручной бэкап и тумблер автоматического.
class KeyStorageScreen extends StatelessWidget {
  const KeyStorageScreen({super.key, required this.matrix});
  final MatrixService matrix;

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
          animation: matrix,
          builder: (context, _) {
            final enabled = matrix.keyBackupEnabled;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                GlassPanel(
                  borderRadius: 18,
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      Icon(enabled ? Icons.cloud_done : Icons.cloud_off,
                          color: enabled
                              ? OrexColors.online
                              : const Color(0xFFE0A03A),
                          size: 30),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(enabled ? 'Включено' : 'Не настроено',
                                style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 2),
                            Text(
                              enabled
                                  ? 'Ключи сообщений хранятся на сервере — '
                                      'история восстановится на новых устройствах.'
                                  : 'Без него переписка не переносится на новые '
                                      'устройства.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (!enabled)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: OrexColors.copper,
                      minimumSize: const Size.fromHeight(48),
                    ),
                    icon: const Icon(Icons.shield),
                    label: const Text('Настроить хранилище ключей'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => VerifySessionScreen(matrix: matrix),
                      ),
                    ),
                  )
                else ...[
                  GlassPanel(
                    borderRadius: 18,
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.schedule,
                              color: OrexColors.copper),
                          title: const Text('Последний бэкап'),
                          subtitle: Text(_ago(matrix.lastBackup)),
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          secondary: const Icon(Icons.autorenew,
                              color: OrexColors.copper),
                          title: const Text('Автоматический бэкап'),
                          subtitle: const Text(
                              'Новые сообщения сохраняются автоматически'),
                          value: matrix.autoBackup,
                          onChanged: matrix.setAutoBackup,
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
                    icon: matrix.backupInProgress
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: OrexColors.cream),
                          )
                        : const Icon(Icons.backup),
                    label: Text(matrix.backupInProgress
                        ? 'Бэкап…'
                        : 'Создать резервную копию сейчас'),
                    onPressed:
                        matrix.backupInProgress ? null : matrix.backupNow,
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

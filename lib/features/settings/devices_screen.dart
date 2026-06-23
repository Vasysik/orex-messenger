import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.matrix});
  final MatrixService matrix;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  late Future<List<Device>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.matrix.devices();
  }

  void _reload() => setState(() => _future = widget.matrix.devices());

  Future<void> _rename(Device d) async {
    final controller = TextEditingController(text: d.displayName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Имя устройства'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await widget.matrix.renameDevice(d.deviceId, name);
    _reload();
  }

  Future<void> _delete(Device d) async {
    // Удаление устройства требует пароль (User-Interactive Auth).
    final pwdController = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить устройство?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Сессия «${d.displayName ?? d.deviceId}» будет завершена.'),
            const SizedBox(height: 14),
            TextField(
              controller: pwdController,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Пароль для подтверждения',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFCF6679)),
            onPressed: () => Navigator.pop(ctx, pwdController.text),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (password == null || password.isEmpty) return;

    try {
      await widget.matrix.deleteDevice(d.deviceId, password);
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось удалить: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentDeviceId = widget.matrix.deviceId;
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('Устройства'),
        ),
        body: FutureBuilder<List<Device>>(
          future: _future,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final devices = snap.data!
              ..sort((a, b) => (b.lastSeenTs ?? 0).compareTo(a.lastSeenTs ?? 0));
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: devices.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final d = devices[i];
                final isCurrent = d.deviceId == currentDeviceId;
                return GlassPanel(
                  borderRadius: 16,
                  child: ListTile(
                    leading: Icon(
                      isCurrent ? Icons.smartphone : Icons.devices_other,
                      color: OrexColors.copper,
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            d.displayName?.isNotEmpty == true
                                ? d.displayName!
                                : d.deviceId,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isCurrent)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: OrexColors.online.withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Text('текущее',
                                style: TextStyle(fontSize: 11)),
                          ),
                      ],
                    ),
                    subtitle: Text(
                      [
                        d.deviceId,
                        if (d.lastSeenIp != null) d.lastSeenIp!,
                      ].join(' · '),
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'rename') _rename(d);
                        if (v == 'delete') _delete(d);
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                            value: 'rename', child: Text('Переименовать')),
                        if (!isCurrent)
                          const PopupMenuItem(
                              value: 'delete', child: Text('Удалить')),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

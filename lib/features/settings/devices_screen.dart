import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import 'verification_screen.dart';

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

  void _reload() => setState(() {
        _future = widget.matrix.devices();
      });

  Future<void> _verify(Device d) async {
    final kv = await widget.matrix.verifyDevice(d.deviceId);
    if (kv == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ключи устройства недоступны')),
        );
      }
      return;
    }
    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
            builder: (_) =>
                VerificationScreen(request: kv, matrix: widget.matrix)),
      );
    }
  }

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
                final verified =
                    isCurrent || widget.matrix.isDeviceVerified(d.deviceId);
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
                          const _Badge(
                            text: 'текущее',
                            color: OrexColors.online,
                          )
                        else
                          _Badge(
                            text: verified ? 'проверено' : 'не проверено',
                            color: verified
                                ? OrexColors.online
                                : const Color(0xFFE0A03A),
                          ),
                      ],
                    ),
                    subtitle: Text(
                      [
                        d.deviceId,
                        if (d.lastSeenIp != null) d.lastSeenIp!,
                      ].join(' · '),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Явная кнопка проверки для непроверённых чужих сессий —
                        // чтобы подтвердить, например, Element X с этой (доверенной)
                        // сессии.
                        if (!isCurrent && !verified)
                          IconButton(
                            tooltip: 'Подтвердить',
                            icon: const Icon(Icons.verified_user,
                                color: OrexColors.copper),
                            onPressed: () => _verify(d),
                          ),
                        PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'verify') _verify(d);
                            if (v == 'rename') _rename(d);
                            if (v == 'delete') _delete(d);
                          },
                          itemBuilder: (_) => [
                            if (!isCurrent)
                              const PopupMenuItem(
                                  value: 'verify',
                                  child: Text('Подтвердить')),
                            const PopupMenuItem(
                                value: 'rename', child: Text('Переименовать')),
                            if (!isCurrent)
                              const PopupMenuItem(
                                  value: 'delete', child: Text('Удалить')),
                          ],
                        ),
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

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: const TextStyle(fontSize: 11)),
    );
  }
}

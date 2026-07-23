import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/logging/orex_logger.dart';
import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/orex_dialogs.dart';
import '../auth/qr_login_screen.dart';
import 'verification_screen.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.matrix});
  final MatrixService matrix;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  late Future<List<Device>> _future;
  final Set<String> _selected = <String>{};
  List<Device> _lastDevices = const <Device>[];
  bool _deleting = false;

  bool get _selectionMode => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _future = widget.matrix.devices();
  }

  void _reload() => setState(() {
        _selected.clear();
        _lastDevices = const <Device>[];
        _future = widget.matrix.devices();
      });

  Future<void> _openQrLogin() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => QrLoginScreen(
          matrix: widget.matrix,
          authenticated: true,
        ),
      ),
    );
    if (mounted) _reload();
  }

  void _toggleSelection(Device device) {
    if (device.deviceId == widget.matrix.deviceId || _deleting) return;
    setState(() {
      if (!_selected.add(device.deviceId)) {
        _selected.remove(device.deviceId);
      }
    });
  }

  void _selectAll() {
    final current = widget.matrix.deviceId;
    final all = _lastDevices
        .where((device) => device.deviceId != current)
        .map((device) => device.deviceId)
        .toSet();
    setState(() {
      if (_selected.length == all.length && _selected.containsAll(all)) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(all);
      }
    });
  }

  Future<void> _verify(Device device) async {
    final verification = await widget.matrix.verifyDevice(device.deviceId);
    if (verification == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ключи устройства недоступны')),
        );
      }
      return;
    }
    if (mounted) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => VerificationScreen(
            request: verification,
            matrix: widget.matrix,
          ),
        ),
      );
      if (mounted) setState(() {});
    }
  }

  Future<void> _rename(Device device) async {
    final name = await showOrexTextInputDialog(
      context,
      title: 'Имя устройства',
      initialValue: device.displayName,
      confirmLabel: 'Сохранить',
      trim: true,
    );
    if (name == null || name.isEmpty) return;
    await widget.matrix.renameDevice(device.deviceId, name);
    _reload();
  }

  Future<void> _deleteOne(Device device) => _deleteSelected(
        ids: {device.deviceId},
        description: 'Сессия «${device.displayName ?? device.deviceId}» '
            'будет завершена.',
      );

  Future<void> _deleteBatch() => _deleteSelected(
        ids: Set<String>.from(_selected),
        description: 'Будут завершены выбранные сессии: ${_selected.length}.',
      );

  Future<void> _deleteSelected({
    required Set<String> ids,
    required String description,
  }) async {
    final current = widget.matrix.deviceId;
    ids.removeWhere((id) => id == current);
    if (ids.isEmpty || _deleting) return;

    final password = await showOrexTextInputDialog(
      context,
      title: ids.length == 1
          ? 'Удалить устройство?'
          : 'Удалить ${ids.length} устройств?',
      message: '$description\nТекущее устройство останется активно.',
      labelText: 'Пароль для подтверждения',
      confirmLabel: 'Удалить',
      obscureText: true,
      danger: true,
    );
    if (password == null || password.isEmpty || !mounted) return;

    setState(() => _deleting = true);
    try {
      await widget.matrix.deleteDevices(ids, password);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ids.length == 1
                ? 'Устройство удалено'
                : 'Удалено устройств: ${ids.length}',
          ),
        ),
      );
      _reload();
    } catch (error) {
      OrexLog.d('Devices', 'delete devices failed', error);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is MatrixException && error.errcode == 'M_FORBIDDEN'
                  ? 'Неверный пароль'
                  : 'Не удалось удалить выбранные устройства',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: Text(
            _selectionMode ? 'Выбрано: ${_selected.length}' : 'Устройства',
          ),
          actionsPadding: const EdgeInsets.only(right: 8),
          actions: [
            if (!_selectionMode)
              IconButton(
                tooltip: 'QR-вход',
                onPressed: _openQrLogin,
                icon: const Icon(Icons.qr_code_scanner),
              ),
            if (!_selectionMode)
              IconButton(
                tooltip: 'Выбрать все, кроме текущего',
                onPressed: _deleting ? null : _selectAll,
                icon: const Icon(Icons.select_all),
              ),
            if (_selectionMode)
              IconButton(
                tooltip: 'Выбрать все, кроме текущего',
                onPressed: _deleting ? null : _selectAll,
                icon: const Icon(Icons.select_all),
              ),
            if (_selectionMode)
              IconButton(
                tooltip: 'Удалить выбранные',
                onPressed: _deleting ? null : _deleteBatch,
                icon: _deleting
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_outline),
              ),
            if (_selectionMode)
              IconButton(
                tooltip: 'Снять выделение',
                onPressed: _deleting
                    ? null
                    : () => setState(() => _selected.clear()),
                icon: const Icon(Icons.close),
              ),
          ],
        ),
        body: FutureBuilder<List<Device>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Не удалось загрузить устройства'),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Повторить'),
                    ),
                  ],
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final devices = snapshot.data!.toList()
              ..sort(
                (a, b) => (b.lastSeenTs ?? 0).compareTo(a.lastSeenTs ?? 0),
              );
            _lastDevices = devices;

            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: devices.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, index) {
                final device = devices[index];
                final isCurrent = device.deviceId == widget.matrix.deviceId;
                final selected = _selected.contains(device.deviceId);
                final verified = isCurrent ||
                    widget.matrix.isDeviceVerified(device.deviceId);

                return GlassPanel(
                  borderRadius: 16,
                  child: ListTile(
                    selected: selected,
                    selectedTileColor:
                        OrexColors.copper.withValues(alpha: 0.12),
                    onTap: _selectionMode && !isCurrent
                        ? () => _toggleSelection(device)
                        : null,
                    onLongPress: isCurrent
                        ? null
                        : () => _toggleSelection(device),
                    leading: _selectionMode && !isCurrent
                        ? Checkbox(
                            value: selected,
                            onChanged: (_) => _toggleSelection(device),
                          )
                        : Icon(
                            isCurrent
                                ? Icons.smartphone
                                : Icons.devices_other,
                            color: OrexColors.copper,
                          ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            device.displayName?.isNotEmpty == true
                                ? device.displayName!
                                : device.deviceId,
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
                        device.deviceId,
                        if (device.lastSeenIp != null) device.lastSeenIp!,
                      ].join(' · '),
                    ),
                    trailing: _selectionMode
                        ? (isCurrent
                            ? const Icon(Icons.lock_outline, size: 20)
                            : null)
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!isCurrent && !verified)
                                IconButton(
                                  tooltip: 'Подтвердить',
                                  icon: const Icon(
                                    Icons.verified_user,
                                    color: OrexColors.copper,
                                  ),
                                  onPressed: () => _verify(device),
                                ),
                              PopupMenuButton<String>(
                                onSelected: (value) {
                                  if (value == 'verify') _verify(device);
                                  if (value == 'rename') _rename(device);
                                  if (value == 'delete') _deleteOne(device);
                                  if (value == 'select') {
                                    _toggleSelection(device);
                                  }
                                },
                                itemBuilder: (_) => [
                                  if (!isCurrent)
                                    const PopupMenuItem(
                                      value: 'select',
                                      child: Text('Выбрать'),
                                    ),
                                  if (!isCurrent)
                                    const PopupMenuItem(
                                      value: 'verify',
                                      child: Text('Подтвердить'),
                                    ),
                                  const PopupMenuItem(
                                    value: 'rename',
                                    child: Text('Переименовать'),
                                  ),
                                  if (!isCurrent)
                                    const PopupMenuItem(
                                      value: 'delete',
                                      child: Text('Удалить'),
                                    ),
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

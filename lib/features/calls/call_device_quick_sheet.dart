import 'package:flutter/material.dart';

import '../../core/audio/audio_device_utils.dart';
import '../../core/matrix/matrix_service.dart';
import '../../core/voip/call_session.dart';
import '../../shared/theme/orex_theme.dart';

Future<void> showOrexInputQuickSheet(
  BuildContext context, {
  required MatrixService matrix,
}) async {
  final devices = await enumerateOrexAudioDevices(
    requestPermission: true,
    includeCallRoutes: true,
  );
  if (!context.mounted) return;
  await _showDeviceSheet(
    context,
    title: 'Микрофон',
    defaultTitle: 'Системный микрофон',
    defaultIcon: Icons.mic,
    selectedId: matrix.audio.inputDeviceId,
    devices: devices.where((d) => d.isInput).toList(),
    iconFor: orexInputDeviceIcon,
    onSelect: matrix.audio.setInputDeviceId,
  );
}

Future<void> showOrexOutputQuickSheet(
  BuildContext context, {
  required MatrixService matrix,
}) async {
  final devices = await enumerateOrexAudioDevices(includeCallRoutes: true);
  if (!context.mounted) return;
  await _showDeviceSheet(
    context,
    title: 'Вывод звука',
    defaultTitle: orexIsAndroidNativePlatform ? 'Динамик телефона' : 'Системный вывод',
    defaultIcon: orexIsAndroidNativePlatform ? Icons.speaker : Icons.volume_up,
    selectedId: matrix.audio.outputDeviceId,
    devices: devices
        .where((d) => d.isOutput)
        .where((d) => !(orexIsAndroidNativePlatform && d.category == 'speaker'))
        .toList(),
    iconFor: orexOutputDeviceIcon,
    onSelect: matrix.audio.setOutputDeviceId,
  );
}

Future<void> showOrexCameraQuickSheet(
  BuildContext context, {
  required MatrixService matrix,
  CallSession? session,
}) async {
  final devices = await enumerateOrexCameraDevices(requestPermission: true);
  if (!context.mounted) return;
  await _showDeviceSheet(
    context,
    title: 'Камера',
    defaultTitle: 'Системная камера',
    defaultIcon: Icons.videocam,
    selectedId: matrix.audio.cameraDeviceId,
    devices: devices,
    iconFor: orexCameraDeviceIcon,
    onSelect: (id) async {
      await matrix.audio.setCameraDeviceId(id);
      await session?.syncAudioSettingsFromSettings();
    },
  );
}

Future<void> _showDeviceSheet(
  BuildContext context, {
  required String title,
  required String defaultTitle,
  required IconData defaultIcon,
  required String? selectedId,
  required List<OrexAudioDevice> devices,
  required IconData Function(OrexAudioDevice device) iconFor,
  required Future<void> Function(String? id) onSelect,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: const Color(0xFF17120F),
    builder: (sheetContext) {
      return SafeArea(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ),
              _DeviceOptionTile(
                icon: defaultIcon,
                title: defaultTitle,
                selected: selectedId == null || selectedId.trim().isEmpty,
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await onSelect(null);
                },
              ),
              for (final device in devices)
                _DeviceOptionTile(
                  icon: iconFor(device),
                  title: device.label,
                  selected: selectedId == device.id,
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await onSelect(device.id);
                  },
                ),
              if (devices.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Других устройств сейчас не найдено.',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _DeviceOptionTile extends StatelessWidget {
  const _DeviceOptionTile({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: OrexColors.copper),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? OrexColors.copper : Colors.white38,
      ),
      onTap: onTap,
    );
  }
}

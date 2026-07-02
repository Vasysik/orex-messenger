import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/orex_theme.dart';

class AudioDeviceSettingsDialog extends StatefulWidget {
  const AudioDeviceSettingsDialog({super.key, required this.matrix});

  final MatrixService matrix;

  @override
  State<AudioDeviceSettingsDialog> createState() =>
      _AudioDeviceSettingsDialogState();
}

class _AudioDeviceSettingsDialogState extends State<AudioDeviceSettingsDialog> {
  bool _loading = true;
  String? _error;
  List<dynamic> _devices = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final devices = await _enumerateDevicesWithPermissionUnlock();
      if (!mounted) return;
      setState(() => _devices = devices);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<dynamic>> _enumerateDevicesWithPermissionUnlock() async {
    rtc.MediaStream? permissionStream;
    try {
      permissionStream = await rtc.navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
    } catch (_) {}

    try {
      return await rtc.navigator.mediaDevices.enumerateDevices();
    } finally {
      for (final track in permissionStream?.getTracks() ?? <dynamic>[]) {
        try {
          track.stop();
        } catch (_) {}
      }
    }
  }

  Future<void> _testOutput() async {
    await widget.matrix.audio.playNotification();
  }

  Future<void> _testMic() async {
    try {
      final stream = await rtc.navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      for (final track in stream.getTracks()) {
        track.stop();
      }
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Микрофон доступен')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Микрофон недоступен: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Аудиоустройства'),
      content: SizedBox(
        width: 480,
        child: _loading
            ? const SizedBox(
                height: 140,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Orex использует системные устройства по умолчанию. '
                    'Наушники Bluetooth могут переключаться в режим гарнитуры, '
                    'когда приложение включает микрофон — это поведение ОС/драйвера.',
                  ),
                  const SizedBox(height: 14),
                  if (_error != null)
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                  if (_devices.isEmpty)
                    const Text('Устройства не найдены')
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final d in _devices) _deviceTile(d),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: const Text('Обновить'),
        ),
        TextButton.icon(
          onPressed: _testOutput,
          icon: const Icon(Icons.volume_up),
          label: const Text('Проверить звук'),
        ),
        TextButton.icon(
          onPressed: _testMic,
          icon: const Icon(Icons.mic),
          label: const Text('Проверить микрофон'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Готово'),
        ),
      ],
    );
  }

  Widget _deviceTile(dynamic device) {
    final kind = '${device.kind}';
    final label = '${device.label}'.trim().isEmpty
        ? _kindLabel(kind)
        : '${device.label}';
    return ListTile(
      dense: true,
      leading: Icon(_kindIcon(kind), color: OrexColors.copper),
      title: Text(label),
      subtitle: Text(kind),
    );
  }

  IconData _kindIcon(String kind) {
    if (kind.contains('audioinput')) return Icons.mic;
    if (kind.contains('audiooutput')) return Icons.volume_up;
    if (kind.contains('videoinput')) return Icons.videocam;
    return Icons.devices;
  }

  String _kindLabel(String kind) {
    if (kind.contains('audioinput')) return 'Микрофон';
    if (kind.contains('audiooutput')) return 'Динамик / наушники';
    if (kind.contains('videoinput')) return 'Камера';
    return 'Устройство';
  }
}

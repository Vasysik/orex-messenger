import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/matrix/matrix_service.dart';
import '../settings/audio_device_settings_content.dart';

class AudioDeviceSettingsDialog extends StatefulWidget {
  const AudioDeviceSettingsDialog({super.key, required this.matrix});

  final MatrixService matrix;

  @override
  State<AudioDeviceSettingsDialog> createState() =>
      _AudioDeviceSettingsDialogState();
}

class _AudioDeviceSettingsDialogState extends State<AudioDeviceSettingsDialog> {
  late final OrexAudioDeviceSettingsController _controller;

  @override
  void initState() {
    super.initState();
    _controller = OrexAudioDeviceSettingsController(
      matrix: widget.matrix,
      includeCallRoutes: true,
    )..addListener(_handleControllerChanged);
    unawaited(_controller.load());
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _testMic() async {
    try {
      await _controller.testMic();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Микрофон доступен')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Микрофон недоступен: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Аудиоустройства'),
      content: SizedBox(
        width: 520,
        child: _controller.loading
            ? const SizedBox(
                height: 160,
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_controller.error != null) ...[
                      Text(
                        _controller.error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                      const SizedBox(height: 12),
                    ],
                    OrexAudioDeviceSettingsContent(
                      controller: _controller,
                      layout: OrexAudioDeviceSettingsLayout.dialog,
                    ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () => _controller.load(requestPermission: true),
          icon: const Icon(Icons.refresh),
          label: const Text('Обновить'),
        ),
        TextButton.icon(
          onPressed: _controller.testOutput,
          icon: const Icon(Icons.volume_up),
          label: const Text('Звук'),
        ),
        TextButton.icon(
          onPressed: _testMic,
          icon: const Icon(Icons.mic),
          label: const Text('Микрофон'),
        ),
        TextButton.icon(
          onPressed: _controller.resetSoundSettings,
          icon: const Icon(Icons.restart_alt),
          label: const Text('Сброс'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Готово'),
        ),
      ],
    );
  }
}

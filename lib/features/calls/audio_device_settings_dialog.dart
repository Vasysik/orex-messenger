import 'package:flutter/material.dart';

import '../../core/matrix/matrix_service.dart';
import '../settings/audio_device_settings_content.dart';

class AudioDeviceSettingsDialog extends StatelessWidget {
  const AudioDeviceSettingsDialog({super.key, required this.matrix});

  final MatrixService matrix;

  @override
  Widget build(BuildContext context) {
    return OrexAudioDeviceSettingsHost(
      matrix: matrix,
      includeCallRoutes: true,
      builder: (context, controller, actions) => AlertDialog(
        title: const Text('Аудиоустройства'),
        content: SizedBox(
          width: 520,
          child: controller.loading
              ? const SizedBox(
                  height: 160,
                  child: Center(child: CircularProgressIndicator()),
                )
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (controller.error != null) ...[
                        Text(
                          controller.error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                        const SizedBox(height: 12),
                      ],
                      OrexAudioDeviceSettingsContent(
                        controller: controller,
                        layout: OrexAudioDeviceSettingsLayout.dialog,
                      ),
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => actions.refresh(requestPermission: true),
            icon: const Icon(Icons.refresh),
            label: const Text('Обновить'),
          ),
          TextButton.icon(
            onPressed: () {
              actions.testOutput();
            },
            icon: const Icon(Icons.volume_up),
            label: const Text('Звук'),
          ),
          TextButton.icon(
            onPressed: () {
              actions.testMic(context);
            },
            icon: const Icon(Icons.mic),
            label: const Text('Микрофон'),
          ),
          TextButton.icon(
            onPressed: () {
              actions.resetSoundSettings();
            },
            icon: const Icon(Icons.restart_alt),
            label: const Text('Сброс'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Готово'),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/glass.dart';
import '../../shared/widgets/orex_settings_components.dart';
import 'audio_device_settings_content.dart';

class AudioDevicesScreen extends StatelessWidget {
  const AudioDevicesScreen({super.key, required this.matrix});

  final MatrixService matrix;

  @override
  Widget build(BuildContext context) {
    return OrexAudioDeviceSettingsHost(
      matrix: matrix,
      includeCallRoutes: false,
      builder: (context, controller, actions) => AmbientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: const Text('Звук и устройства'),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              OrexSettingsSection(
                title: 'Проверка',
                children: [
                  OrexSettingsTile(
                    icon: Icons.refresh,
                    title: 'Обновить список устройств',
                    subtitle: controller.loading
                        ? 'Загрузка...'
                        : 'Перечитать устройства и разблокировать их названия',
                    onTap: () => actions.refresh(requestPermission: true),
                  ),
                  OrexSettingsTile(
                    icon: Icons.volume_up,
                    title: 'Проверить звук',
                    subtitle: 'Проиграть звук уведомления',
                    onTap: () {
                      actions.testOutput();
                    },
                  ),
                  OrexSettingsTile(
                    icon: Icons.mic,
                    title: 'Проверить микрофон',
                    subtitle: 'Запросить выбранный вход и сразу отпустить трек',
                    onTap: () {
                      actions.testMic(context);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (controller.error != null) ...[
                OrexSettingsSection(
                  title: 'Ошибка',
                  children: [
                    OrexSettingsTile(
                      icon: Icons.error_outline,
                      title: 'Не удалось получить устройства',
                      subtitle: controller.error,
                      danger: true,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              OrexAudioDeviceSettingsContent(
                controller: controller,
                layout: OrexAudioDeviceSettingsLayout.screen,
              ),
              const SizedBox(height: 16),
              Text(
                'Порог говорения применяется к локальному микрофону в звонке как быстрый gate: звук ниже линии порога приглушается перед отправкой.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              OrexSettingsSection(
                title: 'Сброс',
                children: [
                  OrexSettingsTile(
                    icon: Icons.restart_alt,
                    title: 'Сбросить настройки звука',
                    subtitle:
                        'Вернуть системный микрофон, системный вывод, системную камеру и стандартный порог',
                    onTap: () {
                      actions.resetSoundSettings();
                    },
                    danger: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

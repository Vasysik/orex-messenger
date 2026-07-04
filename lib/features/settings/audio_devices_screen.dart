import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/glass.dart';
import '../../shared/widgets/orex_settings_components.dart';
import 'audio_device_settings_content.dart';

class AudioDevicesScreen extends StatefulWidget {
  const AudioDevicesScreen({super.key, required this.matrix});

  final MatrixService matrix;

  @override
  State<AudioDevicesScreen> createState() => _AudioDevicesScreenState();
}

class _AudioDevicesScreenState extends State<AudioDevicesScreen> {
  late final OrexAudioDeviceSettingsController _controller;

  @override
  void initState() {
    super.initState();
    _controller = OrexAudioDeviceSettingsController(
      matrix: widget.matrix,
      includeCallRoutes: false,
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
    return AmbientBackground(
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
                  subtitle: _controller.loading
                      ? 'Загрузка...'
                      : 'Перечитать устройства и разблокировать их названия',
                  onTap: () => _controller.load(requestPermission: true),
                ),
                OrexSettingsTile(
                  icon: Icons.volume_up,
                  title: 'Проверить звук',
                  subtitle: 'Проиграть звук уведомления',
                  onTap: _controller.testOutput,
                ),
                OrexSettingsTile(
                  icon: Icons.mic,
                  title: 'Проверить микрофон',
                  subtitle: 'Запросить выбранный вход и сразу отпустить трек',
                  onTap: _testMic,
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_controller.error != null) ...[
              OrexSettingsSection(
                title: 'Ошибка',
                children: [
                  OrexSettingsTile(
                    icon: Icons.error_outline,
                    title: 'Не удалось получить устройства',
                    subtitle: _controller.error,
                    danger: true,
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            OrexAudioDeviceSettingsContent(
              controller: _controller,
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
                  onTap: _controller.resetSoundSettings,
                  danger: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

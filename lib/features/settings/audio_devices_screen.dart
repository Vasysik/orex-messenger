import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/orex_settings_components.dart';

class AudioDevicesScreen extends StatefulWidget {
  const AudioDevicesScreen({super.key, required this.matrix});

  final MatrixService matrix;

  @override
  State<AudioDevicesScreen> createState() => _AudioDevicesScreenState();
}

class _AudioDevicesScreenState extends State<AudioDevicesScreen> {
  bool _loading = true;
  String? _error;
  List<dynamic> _devices = const [];
  String? _inputId;
  String? _outputId;

  @override
  void initState() {
    super.initState();
    _inputId = widget.matrix.audio.inputDeviceId;
    _outputId = widget.matrix.audio.outputDeviceId;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final devices = await rtc.navigator.mediaDevices.enumerateDevices();
      if (!mounted) return;
      setState(() => _devices = devices);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _testOutput() => widget.matrix.audio.playNotification();

  Future<void> _testMic() async {
    try {
      final stream = await rtc.navigator.mediaDevices.getUserMedia({
        'audio': _inputId == null
            ? true
            : {
                'deviceId': {'exact': _inputId},
              },
        'video': false,
      });
      for (final track in stream.getTracks()) {
        track.stop();
      }
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

  List<dynamic> _byKind(String kind) =>
      _devices.where((d) => '${d.kind}'.contains(kind)).toList();

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
                  subtitle: _loading ? 'Загрузка…' : 'Переопросить WebRTC-устройства',
                  onTap: _load,
                ),
                OrexSettingsTile(
                  icon: Icons.volume_up,
                  title: 'Проверить звук',
                  subtitle: 'Проиграть звук уведомления',
                  onTap: _testOutput,
                ),
                OrexSettingsTile(
                  icon: Icons.mic,
                  title: 'Проверить микрофон',
                  subtitle: 'Запросить доступ и сразу отпустить трек',
                  onTap: _testMic,
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_error != null)
              OrexSettingsSection(
                title: 'Ошибка',
                children: [
                  OrexSettingsTile(
                    icon: Icons.error_outline,
                    title: 'Не удалось получить устройства',
                    subtitle: _error,
                    danger: true,
                  ),
                ],
              ),
            OrexSettingsSection(
              title: 'Устройство ввода',
              children: [
                _DeviceRadioTile(
                  icon: Icons.settings_input_component,
                  title: 'Системный микрофон',
                  subtitle: 'Использовать устройство по умолчанию',
                  selected: _inputId == null,
                  onTap: () => setState(() {
                    _inputId = null;
                    widget.matrix.audio.inputDeviceId = null;
                  }),
                ),
                for (final d in _byKind('audioinput'))
                  _DeviceRadioTile(
                    icon: Icons.mic,
                    title: _label(d, 'Микрофон'),
                    subtitle: '${d.deviceId}',
                    selected: _inputId == '${d.deviceId}',
                    onTap: () => setState(() {
                      _inputId = '${d.deviceId}';
                      widget.matrix.audio.inputDeviceId = _inputId;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            OrexSettingsSection(
              title: 'Устройство вывода',
              children: [
                _DeviceRadioTile(
                  icon: Icons.speaker,
                  title: 'Системный вывод',
                  subtitle: 'Использовать динамики/наушники по умолчанию',
                  selected: _outputId == null,
                  onTap: () => setState(() {
                    _outputId = null;
                    widget.matrix.audio.outputDeviceId = null;
                  }),
                ),
                for (final d in _byKind('audiooutput'))
                  _DeviceRadioTile(
                    icon: Icons.volume_up,
                    title: _label(d, 'Динамик / наушники'),
                    subtitle: '${d.deviceId}',
                    selected: _outputId == '${d.deviceId}',
                    onTap: () => setState(() {
                      _outputId = '${d.deviceId}';
                      widget.matrix.audio.outputDeviceId = _outputId;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Выбор вывода применяется там, где это разрешает платформа/WebRTC. '
              'На части desktop/Android-сборок фактический audio route всё ещё контролирует ОС.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  String _label(dynamic device, String fallback) {
    final label = '${device.label}'.trim();
    return label.isEmpty ? fallback : label;
  }
}

class _DeviceRadioTile extends StatelessWidget {
  const _DeviceRadioTile({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: OrexColors.copper),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? OrexColors.copper : Colors.white38,
      ),
      onTap: onTap,
    );
  }
}

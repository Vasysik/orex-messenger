import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../core/audio/audio_device_utils.dart';
import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/orex_settings_components.dart';
import 'mic_level_tester.dart';

class AudioDevicesScreen extends StatefulWidget {
  const AudioDevicesScreen({super.key, required this.matrix});

  final MatrixService matrix;

  @override
  State<AudioDevicesScreen> createState() => _AudioDevicesScreenState();
}

class _AudioDevicesScreenState extends State<AudioDevicesScreen> {
  bool _loading = true;
  String? _error;
  List<OrexAudioDevice> _devices = const [];
  String? _inputId;
  String? _outputId;
  double _thresholdDb = -50;
  bool _thresholdEnabled = true;
  bool _explicitOutputRouting = false;

  @override
  void initState() {
    super.initState();
    _inputId = widget.matrix.audio.inputDeviceId;
    _outputId = widget.matrix.audio.outputDeviceId;
    _thresholdDb = widget.matrix.audio.speakingThresholdDb;
    _thresholdEnabled = widget.matrix.audio.speakingThresholdEnabled;
    _explicitOutputRouting = widget.matrix.audio.explicitOutputRouting;
    _load();
  }

  Future<void> _load({bool requestPermission = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final devices = await enumerateOrexAudioDevices(
        requestPermission: requestPermission,
      );
      if (!mounted) return;
      setState(() => _devices = devices);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _unlockAndReload() => _load(requestPermission: true);

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
      await _load(requestPermission: false);
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

  Future<void> _selectInput(String? id) async {
    await widget.matrix.audio.setInputDeviceId(id);
    if (!mounted) return;
    setState(() => _inputId = widget.matrix.audio.inputDeviceId);
  }

  Future<void> _selectOutput(String? id) async {
    await widget.matrix.audio.setOutputDeviceId(id);
    if (!mounted) return;
    setState(() => _outputId = widget.matrix.audio.outputDeviceId);
  }

  List<OrexAudioDevice> _byKind(String kind) =>
      _devices.where((d) => d.kind == kind).toList();

  bool get _desktopOutputRoutingCanDuck {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  @override
  Widget build(BuildContext context) {
    final inputs = _byKind('audioinput');
    final outputs = _byKind('audiooutput');
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
                  subtitle: _loading
                      ? 'Загрузка…'
                      : 'Переопросить WebRTC/Flutter WebRTC без включения микрофона',
                  onTap: () { _load(); },
                ),
                OrexSettingsTile(
                  icon: Icons.privacy_tip_outlined,
                  title: 'Разрешить доступ к микрофону и обновить',
                  subtitle: 'Коротко открыть микрофон, чтобы ОС/WebRTC раскрыли названия устройств',
                  onTap: _unlockAndReload,
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
                  subtitle: 'Запросить выбранный вход и сразу отпустить трек',
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
                  onTap: () => _selectInput(null),
                ),
                for (final d in inputs)
                  _DeviceRadioTile(
                    icon: Icons.mic,
                    title: d.label,
                    subtitle: d.nativeOnly ? '${d.id} · native' : d.id,
                    selected: _inputId == d.id,
                    onTap: () => _selectInput(d.id),
                  ),
                if (!_loading && inputs.isEmpty)
                  const _EmptyDeviceHint(
                    text: 'WebRTC пока отдаёт только системный вход. Нажмите «Разрешить доступ к микрофону и обновить» или проверьте разрешение микрофона в Windows.',
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
                  onTap: () => _selectOutput(null),
                ),
                for (final d in outputs)
                  _DeviceRadioTile(
                    icon: Icons.volume_up,
                    title: d.label,
                    subtitle: d.nativeOnly ? '${d.id} · route' : d.id,
                    selected: _outputId == d.id,
                    onTap: () => _selectOutput(d.id),
                  ),
                if (!_loading && outputs.isEmpty)
                  const _EmptyDeviceHint(
                    text: 'WebRTC пока отдаёт только системный вывод. На Windows фактический маршрут может оставаться за системным микшером/драйвером.',
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (_desktopOutputRoutingCanDuck) ...[
              OrexSettingsSection(
                title: 'Маршрутизация вывода',
                children: [
                  SwitchListTile(
                    value: _explicitOutputRouting,
                    onChanged: (value) async {
                      setState(() => _explicitOutputRouting = value);
                      await widget.matrix.audio.setExplicitOutputRouting(value);
                    },
                    secondary: const Icon(Icons.headphones, color: OrexColors.copper),
                    title: const Text('Принудительно выбирать вывод WebRTC'),
                    subtitle: const Text(
                      'Выключено: Orex сохраняет выбранные наушники, но не фиксирует route внутри WebRTC — Windows микширует звук сама. '
                      'Включайте только если нужно жёстко вывести звонок на конкретное устройство; на некоторых драйверах это приглушает остальной звук.',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            OrexSettingsSection(
              title: 'Порог говорения',
              children: [
                OrexMicLevelTester(
                  matrix: widget.matrix,
                  inputDeviceId: _inputId,
                  thresholdDb: _thresholdDb,
                  thresholdEnabled: _thresholdEnabled,
                  onThresholdChanged: (value) async {
                    setState(() => _thresholdDb = value);
                    await widget.matrix.audio.setSpeakingThresholdDb(value);
                  },
                  onThresholdEnabledChanged: (value) async {
                    setState(() => _thresholdEnabled = value);
                    await widget.matrix.audio.setSpeakingThresholdEnabled(value);
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Orex больше не открывает микрофон автоматически при входе в этот экран. '
              'Если звук слегка проседает только когда в голосовом канале есть участники, это обычно не список устройств, а системная audio-session/communications-политика Windows или Bluetooth headset profile. На desktop LiveKit не управляет системной audio session, поэтому безопаснее не форсировать output route.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyDeviceHint extends StatelessWidget {
  const _EmptyDeviceHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white60,
            ),
      ),
    );
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
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? OrexColors.copper : Colors.white38,
      ),
      onTap: onTap,
    );
  }
}

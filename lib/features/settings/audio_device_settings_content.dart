import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../core/audio/audio_cue_service.dart';
import '../../core/audio/audio_device_utils.dart';
import '../../core/logging/orex_logger.dart';
import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/orex_settings_components.dart';
import 'mic_level_tester.dart';

enum OrexAudioDeviceSettingsLayout { dialog, screen }

typedef OrexAudioDeviceSettingsBuilder =
    Widget Function(
      BuildContext context,
      OrexAudioDeviceSettingsController controller,
      OrexAudioDeviceSettingsActions actions,
    );

class OrexAudioDeviceSettingsHost extends StatefulWidget {
  const OrexAudioDeviceSettingsHost({
    super.key,
    required this.matrix,
    required this.includeCallRoutes,
    required this.builder,
  });

  final MatrixService matrix;
  final bool includeCallRoutes;
  final OrexAudioDeviceSettingsBuilder builder;

  @override
  State<OrexAudioDeviceSettingsHost> createState() =>
      _OrexAudioDeviceSettingsHostState();
}

class _OrexAudioDeviceSettingsHostState
    extends State<OrexAudioDeviceSettingsHost> {
  late final OrexAudioDeviceSettingsController _controller;
  late final OrexAudioDeviceSettingsActions _actions;

  @override
  void initState() {
    super.initState();
    _controller = OrexAudioDeviceSettingsController(
      matrix: widget.matrix,
      includeCallRoutes: widget.includeCallRoutes,
    )..addListener(_handleControllerChanged);
    _actions = OrexAudioDeviceSettingsActions._(_controller);
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

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _controller, _actions);
  }
}

class OrexAudioDeviceSettingsActions {
  const OrexAudioDeviceSettingsActions._(this._controller);

  final OrexAudioDeviceSettingsController _controller;

  Future<void> refresh({bool requestPermission = true}) =>
      _controller.load(requestPermission: requestPermission);

  Future<void> testOutput() => _controller.testOutput();

  Future<void> resetSoundSettings() => _controller.resetSoundSettings();

  Future<void> testMic(BuildContext context) async {
    try {
      await _controller.testMic();
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Микрофон доступен')));
    } catch (e) {
      OrexLog.d('Audio', 'microphone permission/test failed', e);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Микрофон недоступен')),
      );
    }
  }
}

class OrexAudioDeviceSettingsController extends ChangeNotifier {
  OrexAudioDeviceSettingsController({
    required this.matrix,
    required this.includeCallRoutes,
  }) {
    _readPrefs();
  }

  final MatrixService matrix;
  final bool includeCallRoutes;

  bool loading = true;
  String? error;
  List<OrexAudioDevice> devices = const [];
  List<OrexAudioDevice> cameras = const [];
  String? inputId;
  String? outputId;
  String? cameraId;
  double thresholdDb = AudioCueService.defaultSpeakingThresholdDb;
  bool thresholdEnabled = AudioCueService.defaultSpeakingThresholdEnabled;

  bool _disposed = false;

  List<OrexAudioDevice> get inputs => _byKind('audioinput');

  List<OrexAudioDevice> get outputs => _byKind('audiooutput');

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> load({bool requestPermission = false}) async {
    loading = true;
    error = null;
    _notify();
    try {
      final nextDevices = await enumerateOrexAudioDevices(
        requestPermission: requestPermission,
        includeCallRoutes: includeCallRoutes,
      );
      final nextCameras = await enumerateOrexCameraDevices(
        requestPermission: requestPermission,
      );
      if (_disposed) return;
      devices = nextDevices;
      cameras = nextCameras;
    } catch (e) {
      OrexLog.d('Audio', 'device enumeration failed', e);
      if (_disposed) return;
      error = 'Не удалось получить список аудиоустройств';
    } finally {
      if (!_disposed) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> testOutput() => matrix.audio.playNotification();

  Future<void> testMic() async {
    final stream = await rtc.navigator.mediaDevices.getUserMedia({
      'audio': inputId == null
          ? true
          : {
              'deviceId': {'exact': inputId},
            },
      'video': false,
    });
    for (final track in stream.getTracks()) {
      track.stop();
    }
    await load();
  }

  Future<void> resetSoundSettings() async {
    await matrix.audio.resetSoundSettings();
    if (_disposed) return;
    _readPrefs();
    await load();
  }

  Future<void> selectInput(String? id) async {
    await matrix.audio.setInputDeviceId(id);
    if (_disposed) return;
    inputId = matrix.audio.inputDeviceId;
    _notify();
  }

  Future<void> selectOutput(String? id) async {
    await matrix.audio.setOutputDeviceId(id);
    if (_disposed) return;
    outputId = matrix.audio.outputDeviceId;
    _notify();
  }

  Future<void> selectCamera(String? id) async {
    await matrix.audio.setCameraDeviceId(id);
    if (_disposed) return;
    cameraId = matrix.audio.cameraDeviceId;
    _notify();
  }

  Future<void> setSpeakingThresholdDb(double value) async {
    thresholdDb = value;
    _notify();
    await matrix.audio.setSpeakingThresholdDb(value);
  }

  Future<void> setSpeakingThresholdEnabled(bool value) async {
    thresholdEnabled = value;
    _notify();
    await matrix.audio.setSpeakingThresholdEnabled(value);
  }

  List<OrexAudioDevice> _byKind(String kind) {
    final kindDevices = devices.where((d) => d.kind == kind);
    if (orexIsAndroidNativePlatform && kind == 'audiooutput') {
      return kindDevices.where((d) => d.category != 'speaker').toList();
    }
    return kindDevices.toList();
  }

  void _readPrefs() {
    inputId = matrix.audio.inputDeviceId;
    outputId = matrix.audio.outputDeviceId;
    cameraId = matrix.audio.cameraDeviceId;
    thresholdDb = matrix.audio.speakingThresholdDb;
    thresholdEnabled = matrix.audio.speakingThresholdEnabled;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

class OrexAudioDeviceSettingsContent extends StatelessWidget {
  const OrexAudioDeviceSettingsContent({
    super.key,
    required this.controller,
    required this.layout,
  });

  final OrexAudioDeviceSettingsController controller;
  final OrexAudioDeviceSettingsLayout layout;

  bool get _isDialog => layout == OrexAudioDeviceSettingsLayout.dialog;

  @override
  Widget build(BuildContext context) {
    final sections = [
      _inputSection(),
      _outputSection(),
      _cameraSection(),
      _thresholdSection(),
    ];

    return Column(
      mainAxisSize: _isDialog ? MainAxisSize.min : MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _withSpacing(sections, _isDialog ? 12 : 16),
    );
  }

  Widget _inputSection() {
    return _section(
      title: _isDialog ? 'Ввод' : 'Устройство ввода',
      icon: Icons.mic,
      children: [
        _deviceTile(
          icon: _isDialog ? Icons.mic : Icons.settings_input_component,
          title: 'Системный микрофон',
          subtitle: _isDialog
              ? 'По умолчанию'
              : 'Использовать устройство по умолчанию',
          selected: controller.inputId == null,
          onTap: () => controller.selectInput(null),
        ),
        for (final device in controller.inputs)
          _deviceTile(
            icon: orexInputDeviceIcon(device),
            title: device.label,
            selected: controller.inputId == device.id,
            onTap: () => controller.selectInput(device.id),
          ),
        if (!_isDialog && !controller.loading && controller.inputs.isEmpty)
          const _EmptyDeviceHint(
            text:
                'Сейчас доступен только системный вход. Нажмите «Проверить микрофон» или проверьте системные разрешения микрофона.',
          ),
      ],
    );
  }

  Widget _outputSection() {
    return _section(
      title: _isDialog ? 'Вывод' : 'Устройство вывода',
      icon: Icons.volume_up,
      children: [
        _deviceTile(
          icon: orexIsAndroidNativePlatform ? Icons.speaker : Icons.volume_up,
          title: orexIsAndroidNativePlatform
              ? 'Динамик телефона'
              : 'Системный вывод',
          subtitle: _defaultOutputSubtitle,
          selected:
              controller.outputId == null ||
              orexIsAndroidSpeakerOutputDeviceId(controller.outputId),
          onTap: () => controller.selectOutput(null),
        ),
        for (final device in controller.outputs)
          _deviceTile(
            icon: orexOutputDeviceIcon(device),
            title: device.label,
            selected: controller.outputId == device.id,
            onTap: () => controller.selectOutput(device.id),
          ),
        if (!controller.loading && controller.outputs.isEmpty)
          _EmptyDeviceHint(
            text: _isDialog
                ? 'Сейчас доступен только системный вывод. Нажмите «Обновить», чтобы перечитать устройства и разблокировать их названия.'
                : 'Сейчас доступен только системный вывод. Нажмите «Обновить список устройств» и проверьте, видит ли устройство операционная система.',
          ),
      ],
    );
  }

  Widget _cameraSection() {
    return _section(
      title: 'Камера',
      icon: Icons.videocam,
      children: [
        _deviceTile(
          icon: Icons.videocam,
          title: 'Системная камера',
          subtitle: _isDialog
              ? 'По умолчанию'
              : 'Использовать камеру по умолчанию',
          selected: controller.cameraId == null,
          onTap: () => controller.selectCamera(null),
        ),
        for (final camera in controller.cameras)
          _deviceTile(
            icon: orexCameraDeviceIcon(camera),
            title: camera.label,
            selected: controller.cameraId == camera.id,
            onTap: () => controller.selectCamera(camera.id),
          ),
        if (!_isDialog && !controller.loading && controller.cameras.isEmpty)
          const _EmptyDeviceHint(
            text:
                'Камеры не найдены. Нажмите «Обновить список устройств» и проверьте системные разрешения камеры.',
          ),
      ],
    );
  }

  Widget _thresholdSection() {
    return _section(
      title: 'Порог говорения',
      icon: Icons.graphic_eq,
      children: [
        OrexMicLevelTester(
          matrix: controller.matrix,
          inputDeviceId: controller.inputId,
          thresholdDb: controller.thresholdDb,
          thresholdEnabled: controller.thresholdEnabled,
          compact: _isDialog,
          onThresholdChanged: controller.setSpeakingThresholdDb,
          onThresholdEnabledChanged: controller.setSpeakingThresholdEnabled,
        ),
      ],
    );
  }

  String get _defaultOutputSubtitle {
    if (orexIsAndroidNativePlatform) {
      return _isDialog
          ? 'По умолчанию для звонка'
          : 'Стандартный вывод Android вне звонка';
    }
    return _isDialog ? 'По умолчанию' : 'Использовать устройство по умолчанию';
  }

  Widget _section({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    if (!_isDialog) {
      return OrexSettingsSection(title: title, children: children);
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: OrexColors.copper),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _deviceTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return _AudioDeviceRadioTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      selected: selected,
      onTap: onTap,
      dense: _isDialog,
    );
  }
}

class _AudioDeviceRadioTile extends StatelessWidget {
  const _AudioDeviceRadioTile({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
    required this.dense,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        dense: dense,
        leading: Icon(icon, color: OrexColors.copper),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? OrexColors.copper : Colors.white38,
        ),
        onTap: onTap,
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
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: Colors.white60),
      ),
    );
  }
}

List<Widget> _withSpacing(List<Widget> children, double gap) {
  return [
    for (var i = 0; i < children.length; i++) ...[
      if (i > 0) SizedBox(height: gap),
      children[i],
    ],
  ];
}

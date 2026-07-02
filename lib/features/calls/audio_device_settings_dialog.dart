import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../core/audio/audio_device_utils.dart';
import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/orex_theme.dart';
import '../settings/mic_level_tester.dart';

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
  List<OrexAudioDevice> _devices = const [];
  String? _inputId;
  String? _outputId;
  double _thresholdDb = -50;
  bool _thresholdEnabled = true;

  @override
  void initState() {
    super.initState();
    _inputId = widget.matrix.audio.inputDeviceId;
    _outputId = widget.matrix.audio.outputDeviceId;
    _thresholdDb = widget.matrix.audio.speakingThresholdDb;
    _thresholdEnabled = widget.matrix.audio.speakingThresholdEnabled;
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

  Future<void> _testOutput() async {
    await widget.matrix.audio.playNotification();
  }

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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Аудиоустройства'),
      content: SizedBox(
        width: 520,
        child: _loading
            ? const SizedBox(
                height: 160,
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Список открывается без включения микрофона. Если ОС скрыла названия/устройства, нажмите «Разрешить» — Orex коротко запросит микрофон и сразу отпустит трек.',
                    ),
                    const SizedBox(height: 14),
                    if (_error != null)
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                    _section(
                      'Ввод',
                      Icons.mic,
                      [
                        _deviceTile(
                          title: 'Системный микрофон',
                          subtitle: 'По умолчанию',
                          selected: _inputId == null,
                          onTap: () => _selectInput(null),
                        ),
                        for (final d in _byKind('audioinput'))
                          _deviceTile(
                            title: d.label,
                            subtitle: d.nativeOnly ? '${d.id} · native' : d.id,
                            selected: _inputId == d.id,
                            onTap: () => _selectInput(d.id),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _section(
                      'Вывод',
                      Icons.volume_up,
                      [
                        _deviceTile(
                          title: 'Системный вывод',
                          subtitle: 'По умолчанию',
                          selected: _outputId == null,
                          onTap: () => _selectOutput(null),
                        ),
                        for (final d in _byKind('audiooutput'))
                          _deviceTile(
                            title: d.label,
                            subtitle: d.nativeOnly ? '${d.id} · route' : d.id,
                            selected: _outputId == d.id,
                            onTap: () => _selectOutput(d.id),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _section(
                      'Порог говорения',
                      Icons.graphic_eq,
                      [
                        OrexMicLevelTester(
                          matrix: widget.matrix,
                          inputDeviceId: _inputId,
                          thresholdDb: _thresholdDb,
                          thresholdEnabled: _thresholdEnabled,
                          compact: true,
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
                  ],
                ),
              ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () { _load(); },
          icon: const Icon(Icons.refresh),
          label: const Text('Обновить'),
        ),
        TextButton.icon(
          onPressed: () => _load(requestPermission: true),
          icon: const Icon(Icons.privacy_tip_outlined),
          label: const Text('Разрешить'),
        ),
        TextButton.icon(
          onPressed: _testOutput,
          icon: const Icon(Icons.volume_up),
          label: const Text('Звук'),
        ),
        TextButton.icon(
          onPressed: _testMic,
          icon: const Icon(Icons.mic),
          label: const Text('Микрофон'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Готово'),
        ),
      ],
    );
  }

  Widget _section(String title, IconData icon, List<Widget> children) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Row(
              children: [
                Icon(icon, size: 18, color: OrexColors.copper),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _deviceTile({
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ListTile(
      dense: true,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? OrexColors.copper : Colors.white38,
      ),
      onTap: onTap,
    );
  }
}

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:record/record.dart' as rec;

import '../../core/audio/audio_cue_service.dart';
import '../../core/audio/pcm_audio_level.dart';
import '../../core/logging/orex_logger.dart';
import '../../core/matrix/matrix_service.dart';
import '../../core/voip/voice_gate_controller.dart';
import '../../shared/theme/orex_theme.dart';

class OrexMicLevelTester extends StatefulWidget {
  const OrexMicLevelTester({
    super.key,
    required this.matrix,
    required this.inputDeviceId,
    required this.thresholdDb,
    required this.thresholdEnabled,
    required this.onThresholdChanged,
    required this.onThresholdEnabledChanged,
    this.compact = false,
  });

  final MatrixService matrix;
  final String? inputDeviceId;
  final double thresholdDb;
  final bool thresholdEnabled;
  final ValueChanged<double> onThresholdChanged;
  final ValueChanged<bool> onThresholdEnabledChanged;
  final bool compact;

  @override
  State<OrexMicLevelTester> createState() => _OrexMicLevelTesterState();
}

class _OrexMicLevelTesterState extends State<OrexMicLevelTester> {
  rec.AudioRecorder? _recorder;
  StreamSubscription<rec.Amplitude>? _ampSub;
  StreamSubscription<Uint8List>? _pcmSub;
  bool _testing = false;
  bool _starting = false;
  String? _error;
  double _levelDb = AudioCueService.minSpeakingThresholdDb;
  double _peakDb = AudioCueService.minSpeakingThresholdDb;

  @override
  void dispose() {
    unawaited(_stop());
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant OrexMicLevelTester oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inputDeviceId != widget.inputDeviceId && _testing) {
      unawaited(_restart());
    }
  }

  Future<void> _restart() async {
    await _stop();
    if (!mounted) return;
    await _start();
  }

  Future<void> _toggle() async {
    if (_testing || _starting) {
      await _stop();
    } else {
      await _start();
    }
  }

  Future<void> _start() async {
    if (_testing || _starting) return;
    setState(() {
      _starting = true;
      _error = null;
      _levelDb = AudioCueService.minSpeakingThresholdDb;
      _peakDb = AudioCueService.minSpeakingThresholdDb;
    });

    rec.AudioRecorder? recorder;
    try {
      recorder = rec.AudioRecorder();
      final allowed = await recorder.hasPermission();
      if (!allowed) throw StateError('Нет разрешения на микрофон');

      final device = await OrexVoiceGateController.recordDeviceFor(
        recorder,
        widget.inputDeviceId,
      );
      final stream = await recorder.startStream(
        rec.RecordConfig(
          encoder: rec.AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          autoGain: false,
          echoCancel: false,
          noiseSuppress: false,
          device: device,
          streamBufferSize: 480,
        ),
      );

      _pcmSub = stream.listen(
        (data) {
          _updateLevel(OrexPcmAudioLevel.dbFromPcm16(data));
        },
        onError: (Object e) {
          if (!mounted) return;
          setState(() => _error = '$e');
        },
      );
      _ampSub = recorder
          .onAmplitudeChanged(const Duration(milliseconds: 60))
          .listen(
            (amp) {
              _updateLevel(_normalizeDb(amp.current));
            },
            onError: (Object e) {
              if (!mounted) return;
              setState(() => _error = '$e');
            },
          );

      if (!mounted) {
        await recorder.stop();
        await recorder.dispose();
        return;
      }
      _recorder = recorder;
      setState(() {
        _testing = true;
        _starting = false;
      });
      OrexLog.d(
        'AudioDevices',
        'mic level test started device=${device?.id ?? 'default'}',
      );
    } catch (e, st) {
      OrexLog.d('AudioDevices', 'mic level test failed stack=$st', e);
      try {
        await recorder?.dispose();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _starting = false;
        _testing = false;
        _error = '$e';
      });
    }
  }

  Future<void> _stop() async {
    final recorder = _recorder;
    _recorder = null;
    await _ampSub?.cancel();
    await _pcmSub?.cancel();
    _ampSub = null;
    _pcmSub = null;
    try {
      await recorder?.stop();
    } catch (_) {}
    try {
      await recorder?.dispose();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _testing = false;
      _starting = false;
    });
  }

  void _updateLevel(double db) {
    if (!mounted) return;
    setState(() {
      _levelDb = db;
      _peakDb = math.max(_peakDb, db);
    });
  }

  double _normalizeDb(double value) {
    if (value.isNaN || value.isInfinite) {
      return AudioCueService.minSpeakingThresholdDb;
    }
    return value.clamp(AudioCueService.minSpeakingThresholdDb, 0).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.thresholdEnabled && _levelDb >= widget.thresholdDb;
    final titleStyle = Theme.of(context).textTheme.titleSmall;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, widget.compact ? 8 : 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                active ? Icons.graphic_eq : Icons.graphic_eq_outlined,
                color: active ? OrexColors.online : OrexColors.copper,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.thresholdEnabled
                      ? 'Порог говорения: ${widget.thresholdDb.round()} dBFS'
                      : 'Порог говорения выключен',
                  style: titleStyle,
                ),
              ),
              Switch(
                value: widget.thresholdEnabled,
                onChanged: widget.onThresholdEnabledChanged,
              ),
            ],
          ),
          const SizedBox(height: 8),
          _MicMeter(
            levelDb: _levelDb,
            peakDb: _peakDb,
            thresholdDb: widget.thresholdDb,
            thresholdEnabled: widget.thresholdEnabled,
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final levelLabel = SizedBox(
                width: 92,
                child: Text(
                  '${_levelDb.round()} dBFS',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: active ? OrexColors.online : Colors.white70,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              );
              final testButton = FilledButton.icon(
                onPressed: _starting ? null : _toggle,
                icon: _starting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(_testing ? Icons.stop : Icons.mic),
                label: Text(_testing ? 'Стоп' : 'Тест'),
              );
              final slider = SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: constraints.maxWidth < 520 ? 7 : 4,
                  thumbShape: RoundSliderThumbShape(
                    enabledThumbRadius: constraints.maxWidth < 520 ? 11 : 9,
                  ),
                ),
                child: Slider(
                  value: widget.thresholdDb,
                  min: AudioCueService.minSpeakingThresholdDb,
                  max: AudioCueService.maxSpeakingThresholdDb,
                  divisions:
                      (AudioCueService.maxSpeakingThresholdDb -
                              AudioCueService.minSpeakingThresholdDb)
                          .round(),
                  label: '${widget.thresholdDb.round()} dBFS',
                  onChanged: widget.thresholdEnabled
                      ? widget.onThresholdChanged
                      : null,
                ),
              );

              if (constraints.maxWidth < 520) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [levelLabel, const Spacer(), testButton]),
                    const SizedBox(height: 8),
                    slider,
                  ],
                );
              }

              return Row(
                children: [
                  levelLabel,
                  Expanded(child: slider),
                  testButton,
                ],
              );
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(
              _error!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFFCF6679)),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            'Тест показывает dBFS почти в реальном времени. Чем ближе порог к 0, тем сильнее отсекаются клавиатура и тихий шум.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.white60),
          ),
        ],
      ),
    );
  }
}

class _MicMeter extends StatelessWidget {
  const _MicMeter({
    required this.levelDb,
    required this.peakDb,
    required this.thresholdDb,
    required this.thresholdEnabled,
  });

  final double levelDb;
  final double peakDb;
  final double thresholdDb;
  final bool thresholdEnabled;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final levelX = _xFor(levelDb, width);
        final peakX = _xFor(peakDb, width);
        final thresholdX = _xFor(thresholdDb, width);
        return SizedBox(
          height: 34,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              Container(
                height: 14,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 25),
                curve: Curves.linear,
                height: 14,
                width: levelX.clamp(0, width),
                decoration: BoxDecoration(
                  gradient: OrexColors.copperGradient,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Positioned(
                left: peakX.clamp(0, width - 2),
                child: Container(width: 2, height: 22, color: Colors.white54),
              ),
              if (thresholdEnabled)
                Positioned(
                  left: thresholdX.clamp(0, width - 2),
                  child: Container(
                    width: 2,
                    height: 30,
                    decoration: BoxDecoration(
                      color: OrexColors.online,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  double _xFor(double db, double width) {
    final min = AudioCueService.minSpeakingThresholdDb;
    final normalized = ((db.clamp(min, 0) - min) / -min).clamp(0.0, 1.0);
    return normalized * width;
  }
}

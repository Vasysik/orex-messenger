import 'dart:async';
import 'dart:typed_data';

import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:record/record.dart' as rec;

import '../audio/audio_cue_service.dart';
import '../audio/pcm_audio_level.dart';
import '../logging/orex_logger.dart';
import 'livekit_track_access.dart';

final class OrexVoiceGateController {
  OrexVoiceGateController({
    required this.participantProvider,
    required this.canPublishMediaProvider,
    required this.disposedProvider,
    this.audioInputDeviceIdProvider,
    this.speakingThresholdDbProvider,
    this.speakingThresholdEnabledProvider,
  });

  static const activeHoldDuration = Duration(milliseconds: 220);

  final lk.LocalParticipant? Function() participantProvider;
  final bool Function() canPublishMediaProvider;
  final bool Function() disposedProvider;
  final String? Function()? audioInputDeviceIdProvider;
  final double Function()? speakingThresholdDbProvider;
  final bool Function()? speakingThresholdEnabledProvider;

  rec.AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _pcmSub;
  bool _starting = false;
  bool _appliedMuted = false;
  bool _trackAccessFailed = false;
  DateTime _lastVoiceAboveThreshold = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _enabled => speakingThresholdEnabledProvider?.call() ?? false;

  double get _thresholdDb =>
      (speakingThresholdDbProvider?.call() ??
              AudioCueService.defaultSpeakingThresholdDb)
          .clamp(
            AudioCueService.minSpeakingThresholdDb,
            AudioCueService.maxSpeakingThresholdDb,
          )
          .toDouble();

  Future<void> sync() async {
    final participant = participantProvider();
    final shouldRun =
        participant != null &&
        participant.isMicrophoneEnabled() &&
        canPublishMediaProvider() &&
        _enabled &&
        !disposedProvider();

    if (!shouldRun) {
      await stop(resetTrack: true);
      return;
    }
    await _start();
  }

  Future<void> _start() async {
    if (_recorder != null || _starting) return;
    _starting = true;
    rec.AudioRecorder? recorder;
    try {
      recorder = rec.AudioRecorder();
      final allowed = await recorder.hasPermission();
      if (!allowed) throw StateError('Нет разрешения на микрофон');

      final device = await recordDeviceFor(
        recorder,
        audioInputDeviceIdProvider?.call(),
        logTag: 'Call',
        logMessage: 'voice gate device match failed',
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
        _onPcm,
        onError: (Object e) {
          OrexLog.d('Call', 'voice gate pcm stream failed', e);
        },
      );
      _recorder = recorder;
      _starting = false;
      _lastVoiceAboveThreshold = DateTime.fromMillisecondsSinceEpoch(0);
      _setMuted(true);
      OrexLog.d('Call', 'voice gate started device=${device?.id ?? 'default'}');
    } catch (e, st) {
      _starting = false;
      OrexLog.d('Call', 'voice gate start failed stack=$st', e);
      try {
        await recorder?.dispose();
      } catch (_) {}
    }
  }

  void _onPcm(Uint8List data) {
    if (disposedProvider()) return;
    final db = OrexPcmAudioLevel.dbFromPcm16(data);
    final now = DateTime.now();
    final threshold = _thresholdDb;
    if (db >= threshold) {
      _lastVoiceAboveThreshold = now;
    }

    final active = isVoiceActive(
      db: db,
      thresholdDb: threshold,
      now: now,
      lastVoiceAboveThreshold: _lastVoiceAboveThreshold,
    );

    if (!_enabled || !canPublishMediaProvider()) {
      unawaited(stop(resetTrack: true));
      return;
    }
    _setMuted(!active);
  }

  void _setMuted(bool muted) {
    if (_appliedMuted == muted) return;
    if (!OrexLiveKitTrackAccess.setLocalMicrophoneTrackEnabled(
      participantProvider(),
      !muted,
    )) {
      if (!_trackAccessFailed) {
        _trackAccessFailed = true;
        OrexLog.d('Call', 'voice gate cannot access local microphone track');
      }
      return;
    }
    _appliedMuted = muted;
  }

  Future<void> stop({required bool resetTrack}) async {
    final recorder = _recorder;
    _recorder = null;
    _starting = false;
    await _pcmSub?.cancel();
    _pcmSub = null;
    try {
      await recorder?.stop();
    } catch (_) {}
    try {
      await recorder?.dispose();
    } catch (_) {}
    if (resetTrack && _appliedMuted) {
      _setMuted(false);
    }
    _appliedMuted = false;
  }

  void dispose() {
    _starting = false;
    unawaited(_pcmSub?.cancel());
    _pcmSub = null;
    unawaited(_recorder?.dispose());
    _recorder = null;
  }

  static bool isVoiceActive({
    required double db,
    required double thresholdDb,
    required DateTime now,
    required DateTime lastVoiceAboveThreshold,
    Duration holdDuration = const Duration(milliseconds: 220),
  }) {
    return db >= thresholdDb ||
        now.difference(lastVoiceAboveThreshold) < holdDuration;
  }

  static String? normalizeInputDeviceId(String? selectedId) {
    final normalized = selectedId?.trim();
    if (normalized == null || normalized.isEmpty || normalized == 'default') {
      return null;
    }
    return normalized;
  }

  static Future<rec.InputDevice?> recordDeviceFor(
    rec.AudioRecorder recorder,
    String? selectedId, {
    String logTag = 'AudioDevices',
    String logMessage = 'record device match failed',
  }) async {
    final normalized = normalizeInputDeviceId(selectedId);
    if (normalized == null) return null;
    try {
      final devices = await recorder.listInputDevices();
      for (final device in devices) {
        if (device.id == normalized) return device;
      }
      // WebRTC and record can expose different IDs for the same physical mic.
      // If exact ID is unavailable, use default rather than failing the call.
    } catch (e) {
      OrexLog.d(logTag, logMessage, e);
    }
    return null;
  }
}

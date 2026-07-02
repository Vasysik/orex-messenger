import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/orex_logger.dart';
import 'audio_device_utils.dart';
import 'native_audio_devices.dart';

/// Единая точка коротких звуков Orex и пользовательских аудио-настроек.
class AudioCueService extends ChangeNotifier {
  static const notificationAsset = 'assets/sounds/orex_notification.wav';
  static const incomingAsset = 'assets/sounds/orex_incoming_call.wav';
  static const voiceJoinAsset = 'assets/sounds/orex_voice_join.wav';
  static const reactionAsset = 'assets/sounds/orex_voice_reaction.wav';

  final AudioPlayer _cuePlayer = AudioPlayer();
  final AudioPlayer _ringtonePlayer = AudioPlayer();

  static const _kInputDeviceId = 'orex_audio_input_device_id';
  static const _kOutputDeviceId = 'orex_audio_output_device_id';
  static const _kSpeakingThresholdDb = 'orex_audio_speaking_threshold_db';
  static const _kSpeakingThresholdEnabled = 'orex_audio_speaking_threshold_enabled';
  static const _kCallMicEnabled = 'orex_audio_call_mic_enabled';

  static const minSpeakingThresholdDb = -70.0;
  static const maxSpeakingThresholdDb = -10.0;
  static const defaultSpeakingThresholdDb = -50.0;
  static const defaultSpeakingThresholdEnabled = false;

  Timer? _ringtoneWatchdog;
  bool _ringing = false;
  String? inputDeviceId;
  String? outputDeviceId;
  double speakingThresholdDb = defaultSpeakingThresholdDb;
  bool speakingThresholdEnabled = defaultSpeakingThresholdEnabled;
  bool? callMicEnabledOverride;

  bool get isRinging => _ringing;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      inputDeviceId = _nullIfEmpty(prefs.getString(_kInputDeviceId));
      outputDeviceId = _nullIfEmpty(prefs.getString(_kOutputDeviceId));
      if (orexIsMobileRouteId(outputDeviceId) && !orexIsMobileNativePlatform) {
        outputDeviceId = null;
        await prefs.remove(_kOutputDeviceId);
      }
      speakingThresholdDb = _clampSpeakingThreshold(
        prefs.getDouble(_kSpeakingThresholdDb) ?? defaultSpeakingThresholdDb,
      );
      speakingThresholdEnabled = prefs.getBool(_kSpeakingThresholdEnabled) ??
          defaultSpeakingThresholdEnabled;
      callMicEnabledOverride = prefs.containsKey(_kCallMicEnabled)
          ? prefs.getBool(_kCallMicEnabled)
          : null;
      await applySelectedDevices();
    } catch (e) {
      OrexLog.d('Audio', 'load audio preferences failed', e);
    }
  }

  Future<void> setInputDeviceId(String? value) async {
    inputDeviceId = _nullIfEmpty(value);
    await _saveString(_kInputDeviceId, inputDeviceId);
    await _applyInputDevice();
    notifyListeners();
  }

  Future<void> setOutputDeviceId(String? value) async {
    outputDeviceId = _nullIfEmpty(value);
    await _saveString(_kOutputDeviceId, outputDeviceId);
    await _applyOutputDevice();
    notifyListeners();
  }

  Future<void> setCallMicEnabled(bool value) async {
    callMicEnabledOverride = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kCallMicEnabled, value);
    } catch (e) {
      OrexLog.d('Audio', 'save call mic preference failed', e);
    }
    notifyListeners();
  }

  Future<void> setSpeakingThresholdDb(double value) async {
    speakingThresholdDb = _clampSpeakingThreshold(value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kSpeakingThresholdDb, speakingThresholdDb);
    } catch (e) {
      OrexLog.d('Audio', 'save speaking threshold failed', e);
    }
    notifyListeners();
  }

  Future<void> setSpeakingThresholdEnabled(bool value) async {
    speakingThresholdEnabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSpeakingThresholdEnabled, value);
    } catch (e) {
      OrexLog.d('Audio', 'save speaking threshold enabled failed', e);
    }
    notifyListeners();
  }

  Future<void> resetSoundSettings() async {
    inputDeviceId = null;
    outputDeviceId = null;
    speakingThresholdDb = defaultSpeakingThresholdDb;
    speakingThresholdEnabled = defaultSpeakingThresholdEnabled;
    callMicEnabledOverride = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kInputDeviceId);
      await prefs.remove(_kOutputDeviceId);
      await prefs.remove(_kCallMicEnabled);
      await prefs.setDouble(_kSpeakingThresholdDb, speakingThresholdDb);
      await prefs.setBool(_kSpeakingThresholdEnabled, speakingThresholdEnabled);
    } catch (e) {
      OrexLog.d('Audio', 'reset sound settings failed', e);
    }
    await applySelectedDevices();
    notifyListeners();
  }

  Future<void> applySelectedDevices() async {
    await _applyInputDevice();
    await _applyOutputDevice();
  }

  Future<void> _applyInputDevice() async {
    // LiveKit receives the chosen microphone through AudioCaptureOptions when
    // the mic track is created. Do not pre-lock the route here: some backends
    // reject IDs that are still valid for getUserMedia/LiveKit, and that only
    // creates noisy startup logs.
  }

  Future<void> _applyOutputDevice() async {
    final id = outputDeviceId?.trim();

    if (id == null || id.isEmpty) {
      if (orexIsMobileNativePlatform) {
        await OrexNativeAudioDevices.selectOutput(null);
      }
      return;
    }

    if (orexIsMobileNativePlatform) {
      final ok = await OrexNativeAudioDevices.selectOutput(id);
      if (!ok) OrexLog.d('Audio', 'native output route not applied id=$id');
      return;
    }

    if (orexIsMobileRouteId(id)) {
      outputDeviceId = null;
      await _saveString(_kOutputDeviceId, null);
      return;
    }

    try {
      await rtc.Helper.selectAudioOutput(id);
      OrexLog.d('Audio', 'selected output device id=$id');
    } catch (e) {
      OrexLog.d('Audio', 'select output device failed id=$id', e);
    }
  }

  Future<void> _saveString(String key, String? value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value == null) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, value);
      }
    } catch (e) {
      OrexLog.d('Audio', 'save preference failed key=$key', e);
    }
  }

  double _clampSpeakingThreshold(double value) => value
      .clamp(minSpeakingThresholdDb, maxSpeakingThresholdDb)
      .toDouble();

  String? _nullIfEmpty(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == 'null') return null;
    return trimmed;
  }

  Future<void> playNotification() => _playAsset(
        notificationAsset,
        SystemSoundType.alert,
        label: 'notification',
      );

  Future<void> playVoiceJoin() => _playAsset(
        voiceJoinAsset,
        SystemSoundType.click,
        label: 'voice join',
      );

  Future<void> playReaction() => _playAsset(
        reactionAsset,
        SystemSoundType.click,
        label: 'voice reaction',
      );

  Future<void> startIncomingRingtone() async {
    if (_ringing) return;
    _ringing = true;
    OrexLog.d('Audio', 'start incoming ringtone');
    try {
      await _ensureAsset(incomingAsset);
      await _ringtonePlayer.setReleaseMode(ReleaseMode.loop);
      await _ringtonePlayer.play(_assetSource(incomingAsset));
    } catch (e) {
      OrexLog.d('Audio', 'incoming ringtone asset playback failed', e);
      await _fallback(SystemSoundType.alert);
      _ringtoneWatchdog = Timer.periodic(const Duration(seconds: 2), (_) {
        _fallback(SystemSoundType.alert);
      });
    }
  }

  Future<void> stopIncomingRingtone() async {
    if (!_ringing && _ringtoneWatchdog == null) return;
    OrexLog.d('Audio', 'stop incoming ringtone');
    _ringing = false;
    _ringtoneWatchdog?.cancel();
    _ringtoneWatchdog = null;
    try {
      await _ringtonePlayer.stop();
      await _ringtonePlayer.setReleaseMode(ReleaseMode.release);
    } catch (_) {}
  }

  Future<void> _playAsset(
    String asset,
    SystemSoundType fallback, {
    required String label,
  }) async {
    try {
      await _ensureAsset(asset);
      await _cuePlayer.stop();
      await _cuePlayer.play(_assetSource(asset));
    } catch (e) {
      OrexLog.d('Audio', '$label asset sound failed asset=$asset', e);
      await _fallback(fallback);
    }
  }

  Future<void> _ensureAsset(String asset) => rootBundle.load(asset);

  AssetSource _assetSource(String asset) {
    final path = asset.startsWith('assets/') ? asset.substring(7) : asset;
    return AssetSource(path);
  }

  Future<void> _fallback(SystemSoundType type) async {
    try {
      await SystemSound.play(type);
    } catch (_) {}
  }

  @override
  void dispose() {
    _ringtoneWatchdog?.cancel();
    _cuePlayer.dispose();
    _ringtonePlayer.dispose();
    super.dispose();
  }
}

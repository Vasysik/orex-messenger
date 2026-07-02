import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/orex_logger.dart';

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

  static const mobileEarpieceOutputId = 'orex://mobile/earpiece';
  static const mobileSpeakerOutputId = 'orex://mobile/speaker';

  static const defaultSpeakingThresholdDb = -50.0;
  static const defaultSpeakingThresholdEnabled = true;

  Timer? _ringtoneWatchdog;
  bool _ringing = false;
  String? inputDeviceId;
  String? outputDeviceId;
  double speakingThresholdDb = defaultSpeakingThresholdDb;
  bool speakingThresholdEnabled = defaultSpeakingThresholdEnabled;

  double localMicLevelDb = -100;
  bool localVoiceActive = false;

  bool get isRinging => _ringing;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      inputDeviceId = _nullIfEmpty(prefs.getString(_kInputDeviceId));
      outputDeviceId = _nullIfEmpty(prefs.getString(_kOutputDeviceId));
      speakingThresholdDb = prefs.getDouble(_kSpeakingThresholdDb) ??
          defaultSpeakingThresholdDb;
      speakingThresholdEnabled = prefs.getBool(_kSpeakingThresholdEnabled) ??
          defaultSpeakingThresholdEnabled;
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

  Future<void> setSpeakingThresholdDb(double value) async {
    speakingThresholdDb = value.clamp(-80, -20).toDouble();
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
    localMicLevelDb = -100;
    localVoiceActive = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kInputDeviceId);
      await prefs.remove(_kOutputDeviceId);
      await prefs.setDouble(_kSpeakingThresholdDb, speakingThresholdDb);
      await prefs.setBool(_kSpeakingThresholdEnabled, speakingThresholdEnabled);
    } catch (e) {
      OrexLog.d('Audio', 'reset sound settings failed', e);
    }
    await applySelectedDevices();
    notifyListeners();
  }

  void updateLocalVoiceActivity({required double db, required bool active}) {
    final clamped = db.clamp(-100, 0).toDouble();
    if (active == localVoiceActive && (clamped - localMicLevelDb).abs() < 1.2) {
      return;
    }
    localMicLevelDb = clamped;
    localVoiceActive = active;
    notifyListeners();
  }

  void clearLocalVoiceActivity() {
    if (localMicLevelDb == -100 && !localVoiceActive) return;
    localMicLevelDb = -100;
    localVoiceActive = false;
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
    final id = outputDeviceId;
    if (id == null || id == 'default') return;

    if (id == mobileSpeakerOutputId || id == mobileEarpieceOutputId) {
      try {
        final speaker = id == mobileSpeakerOutputId;
        await lk.AudioManager.instance.setSpeakerOutputPreferred(
          speaker,
          force: speaker,
        );
        OrexLog.d('Audio', 'selected mobile route speaker=$speaker');
      } catch (e) {
        OrexLog.d('Audio', 'select mobile route failed id=$id', e);
      }
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

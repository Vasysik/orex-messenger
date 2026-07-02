import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

import '../logging/orex_logger.dart';

/// Единая точка коротких звуков Orex.
///
/// Звуки лежат в bundled assets (`assets/sounds/*.wav`) и проигрываются через
/// `audioplayers`. Если аудио-backend на конкретной платформе не сработал,
/// сервис аккуратно падает в системный fallback, не ломая звонок/чат.
class AudioCueService {
  static const notificationAsset = 'assets/sounds/orex_notification.wav';
  static const incomingAsset = 'assets/sounds/orex_incoming_call.wav';
  static const voiceJoinAsset = 'assets/sounds/orex_voice_join.wav';
  static const reactionAsset = 'assets/sounds/orex_voice_reaction.wav';

  final AudioPlayer _cuePlayer = AudioPlayer();
  final AudioPlayer _ringtonePlayer = AudioPlayer();

  Timer? _ringtoneWatchdog;
  bool _ringing = false;
  String? inputDeviceId;
  String? outputDeviceId;

  bool get isRinging => _ringing;

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
    OrexLog.d('Audio', 'start incoming ringtone output=$outputDeviceId');
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
      OrexLog.d(
        'Audio',
        '$label asset sound failed asset=$asset output=$outputDeviceId',
        e,
      );
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

  void dispose() {
    _ringtoneWatchdog?.cancel();
    _cuePlayer.dispose();
    _ringtonePlayer.dispose();
  }
}

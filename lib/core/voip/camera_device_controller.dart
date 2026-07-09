import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;

import '../audio/audio_device_utils.dart';
import '../logging/orex_logger.dart';
import 'livekit_track_access.dart';
import 'screen_share_controller.dart';

final class OrexCameraDeviceResult {
  const OrexCameraDeviceResult._({required this.changed, this.error});

  const OrexCameraDeviceResult.idle() : this._(changed: false, error: null);

  const OrexCameraDeviceResult.success() : this._(changed: true, error: null);

  const OrexCameraDeviceResult.failure(String error)
    : this._(changed: true, error: error);

  final bool changed;
  final String? error;
}

final class OrexCameraDeviceController {
  OrexCameraDeviceController({
    this.videoInputDeviceIdProvider,
    this.cameraDeviceIdSink,
  });

  final String? Function()? videoInputDeviceIdProvider;
  final FutureOr<void> Function(String? deviceId)? cameraDeviceIdSink;

  String? _lastAppliedCameraDeviceId;
  String? _lastRequestedCameraDeviceId;

  lk.CameraCaptureOptions captureOptions() {
    final normalized = normalizedCameraDeviceId();
    _lastAppliedCameraDeviceId = normalized;
    return lk.CameraCaptureOptions(deviceId: normalized);
  }

  String? normalizedCameraDeviceId() {
    return normalizeSelectedDeviceId(videoInputDeviceIdProvider?.call());
  }

  Future<OrexCameraDeviceResult> restartIfInputChanged({
    required lk.LocalParticipant? participant,
    required bool canPublishMedia,
    bool force = false,
  }) async {
    if (participant == null ||
        !participant.isCameraEnabled() ||
        !canPublishMedia) {
      return const OrexCameraDeviceResult.idle();
    }

    final nextCameraId = normalizedCameraDeviceId();
    if (!force && nextCameraId == _lastAppliedCameraDeviceId) {
      return const OrexCameraDeviceResult.idle();
    }
    if (nextCameraId != null &&
        await _switchActiveCameraTrack(participant, nextCameraId)) {
      return const OrexCameraDeviceResult.success();
    }

    return _recreateCameraTrack(participant);
  }

  Future<OrexCameraDeviceResult> selectDevice({
    required lk.LocalParticipant? participant,
    required bool canPublishMedia,
    required String? deviceId,
  }) async {
    final normalized = normalizeSelectedDeviceId(deviceId);
    await _saveCameraDeviceId(normalized);
    if (participant == null || !canPublishMedia) {
      return const OrexCameraDeviceResult.idle();
    }
    if (normalized != null &&
        await _switchActiveCameraTrack(participant, normalized)) {
      return const OrexCameraDeviceResult.success();
    }
    return restartIfInputChanged(
      participant: participant,
      canPublishMedia: canPublishMedia,
      force: true,
    );
  }

  Future<OrexCameraDeviceResult> cycleDevice({
    required lk.LocalParticipant? participant,
    required bool canPublishMedia,
    required List<OrexAudioDevice> devices,
  }) async {
    final ids = uniqueDeviceIds(devices);
    if (ids.isEmpty) return const OrexCameraDeviceResult.idle();

    final activeTrackId = _currentCameraDeviceIdFromTrack(participant);
    final next = nextDeviceId(
      ids: ids,
      configured: normalizedCameraDeviceId(),
      lastRequested: _lastRequestedCameraDeviceId,
      activeTrackId: activeTrackId,
    );
    await _saveCameraDeviceId(next);

    if (participant == null || !canPublishMedia) {
      return const OrexCameraDeviceResult.idle();
    }
    if (await _switchActiveCameraTrack(participant, next)) {
      return const OrexCameraDeviceResult.success();
    }
    return restartIfInputChanged(
      participant: participant,
      canPublishMedia: canPublishMedia,
      force: true,
    );
  }

  Future<OrexCameraDeviceResult> _recreateCameraTrack(
    lk.LocalParticipant participant,
  ) async {
    final oldTrack = _localCameraTrack(participant);
    try {
      await participant.setCameraEnabled(false);
      try {
        await oldTrack?.stop();
      } catch (e) {
        OrexLog.d('Call', 'old camera track stop failed', e);
      }
      try {
        await oldTrack?.dispose();
      } catch (e) {
        OrexLog.d('Call', 'old camera track dispose failed', e);
      }
      await Future<void>.delayed(const Duration(milliseconds: 180));

      final options = captureOptions();
      try {
        final track = await lk.LocalVideoTrack.createCameraTrack(options);
        await participant.publishVideoTrack(track);
      } catch (e) {
        OrexLog.d(
          'Call',
          'explicit camera recreate failed, fallback setCameraEnabled',
          e,
        );
        await participant.setCameraEnabled(true, cameraCaptureOptions: options);
      }
      return const OrexCameraDeviceResult.success();
    } catch (e) {
      OrexLog.d('Call', 'camera device change failed', e);
      return const OrexCameraDeviceResult.failure('Камера недоступна');
    }
  }

  Future<void> _saveCameraDeviceId(String? deviceId) async {
    _lastRequestedCameraDeviceId = deviceId;
    final sink = cameraDeviceIdSink;
    if (sink != null) await sink(deviceId);
  }

  Future<bool> _switchActiveCameraTrack(
    lk.LocalParticipant participant,
    String deviceId,
  ) async {
    if (OrexScreenShareController.desktopNeedsExplicitSource) return false;
    if (!participant.isCameraEnabled()) return false;
    final track = _localCameraTrack(participant);
    if (track == null) return false;
    try {
      await lk.LocalVideoTrackExt(
        track,
      ).switchCamera(deviceId, fastSwitch: true);
      _lastAppliedCameraDeviceId = deviceId;
      OrexLog.d('Call', 'camera switched via LiveKit track device=$deviceId');
      return true;
    } catch (e) {
      OrexLog.d('Call', 'camera fast switch failed device=$deviceId', e);
      return false;
    }
  }

  lk.LocalVideoTrack? _localCameraTrack(lk.LocalParticipant participant) {
    for (final pub in OrexLiveKitTrackAccess.localVideoPublications(
      participant,
    )) {
      if (OrexLiveKitTrackAccess.readDynamic(pub, 'source') !=
          lk.TrackSource.camera) {
        continue;
      }
      final track = OrexLiveKitTrackAccess.readDynamic(pub, 'track');
      if (track is lk.LocalVideoTrack) return track;
      if (pub is lk.LocalVideoTrack) return pub;
    }
    return null;
  }

  String? _currentCameraDeviceIdFromTrack(lk.LocalParticipant? participant) {
    if (participant == null) return null;
    final track = _localCameraTrack(participant);
    if (track == null) return null;
    for (final candidate in [
      OrexLiveKitTrackAccess.readDynamic(track, 'mediaStreamTrack'),
      OrexLiveKitTrackAccess.readDynamic(track, 'rtcTrack'),
      OrexLiveKitTrackAccess.readDynamic(track, 'track'),
      track,
    ]) {
      if (candidate == null) continue;
      try {
        final settings = candidate.getSettings();
        if (settings is Map) {
          final id = settings['deviceId'] ?? settings['device_id'];
          final normalized = normalizeSelectedDeviceId(id?.toString());
          if (normalized != null) return normalized;
        }
      } catch (e) {
        OrexLog.d('Call', 'camera device settings read failed', e);
      }
    }
    return null;
  }

  static String? normalizeSelectedDeviceId(String? deviceId) {
    final normalized = deviceId?.trim();
    if (normalized == null || normalized.isEmpty || normalized == 'default') {
      return null;
    }
    return normalized;
  }

  static List<String> uniqueDeviceIds(List<OrexAudioDevice> devices) {
    final ids = <String>[];
    for (final device in devices) {
      final id = device.id.trim();
      if (id.isNotEmpty && !ids.contains(id)) ids.add(id);
    }
    return ids;
  }

  static String nextDeviceId({
    required List<String> ids,
    required String? configured,
    required String? lastRequested,
    required String? activeTrackId,
  }) {
    final current = configured ?? lastRequested ?? activeTrackId;
    if (current == null) return ids.first;
    final index = ids.indexOf(current);
    if (index < 0) return ids.first;
    final nextIndex = ids.length == 1 ? 0 : (index + 1) % ids.length;
    return ids[nextIndex];
  }
}

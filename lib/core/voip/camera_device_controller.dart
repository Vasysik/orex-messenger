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
  lk.CameraPosition? _lastRequestedCameraPosition;
  Future<void> _operationTail = Future<void>.value();

  lk.CameraCaptureOptions captureOptions() {
    final normalized = normalizedCameraDeviceId();
    final position = _lastRequestedCameraPosition;
    return position == null
        ? lk.CameraCaptureOptions(deviceId: normalized)
        : lk.CameraCaptureOptions(
            deviceId: normalized,
            cameraPosition: position,
          );
  }

  String? normalizedCameraDeviceId() {
    return normalizeSelectedDeviceId(videoInputDeviceIdProvider?.call());
  }

  Future<OrexCameraDeviceResult> restartIfInputChanged({
    required lk.LocalParticipant? participant,
    required bool canPublishMedia,
    bool force = false,
  }) => _serialize(() => _restartIfInputChanged(
        participant: participant,
        canPublishMedia: canPublishMedia,
        force: force,
      ));

  Future<OrexCameraDeviceResult> selectDevice({
    required lk.LocalParticipant? participant,
    required bool canPublishMedia,
    required String? deviceId,
    String? deviceCategory,
  }) => _serialize(() async {
        final normalized = normalizeSelectedDeviceId(deviceId);
        final position = cameraPositionForCategory(deviceCategory);
        _lastRequestedCameraPosition = position;
        await _saveCameraDeviceId(normalized);
        if (participant == null || !canPublishMedia) {
          return const OrexCameraDeviceResult.idle();
        }
        return _switchOrRestart(
          participant,
          normalized,
          cameraPosition: position,
        );
      });

  Future<OrexCameraDeviceResult> cycleDevice({
    required lk.LocalParticipant? participant,
    required bool canPublishMedia,
    required List<OrexAudioDevice> devices,
  }) => _serialize(() async {
        final ids = uniqueDeviceIds(devices);
        if (ids.isEmpty) return const OrexCameraDeviceResult.idle();

        // Keep camera state inside the same serial queue. Persisted settings can
        // lag behind a rapid second tap, while _lastApplied is updated only after
        // the previous physical switch/restart has completed.
        final activeTrackId = _currentCameraDeviceIdFromTrack(participant);
        final activePosition = _currentCameraPositionFromTrack(participant);
        final positionMatchedId = deviceIdForPosition(
          devices,
          activePosition,
        );
        final current = activeTrackId ??
            positionMatchedId ??
            _lastAppliedCameraDeviceId ??
            _lastRequestedCameraDeviceId ??
            normalizedCameraDeviceId();
        final next = nextDeviceId(
          ids: ids,
          configured: current,
          lastRequested: null,
          activeTrackId: null,
        );
        OrexAudioDevice? nextDevice;
        for (final device in devices) {
          if (device.id == next) {
            nextDevice = device;
            break;
          }
        }
        final nextPosition = cameraPositionForCategory(nextDevice?.category);
        _lastRequestedCameraPosition = nextPosition;
        await _saveCameraDeviceId(next);

        if (participant == null || !canPublishMedia) {
          return const OrexCameraDeviceResult.idle();
        }
        return _switchOrRestart(
          participant,
          next,
          cameraPosition: nextPosition,
        );
      });

  Future<OrexCameraDeviceResult> _restartIfInputChanged({
    required lk.LocalParticipant? participant,
    required bool canPublishMedia,
    required bool force,
  }) async {
    if (participant == null ||
        !participant.isCameraEnabled() ||
        !canPublishMedia) {
      return const OrexCameraDeviceResult.idle();
    }

    final nextCameraId = normalizedCameraDeviceId();
    final activeCameraId = _currentCameraDeviceIdFromTrack(participant);
    if (!force &&
        nextCameraId == (activeCameraId ?? _lastAppliedCameraDeviceId)) {
      return const OrexCameraDeviceResult.idle();
    }
    return _switchOrRestart(
      participant,
      nextCameraId,
      cameraPosition: _currentCameraPositionFromTrack(participant),
    );
  }

  Future<OrexCameraDeviceResult> _switchOrRestart(
    lk.LocalParticipant participant,
    String? deviceId, {
    lk.CameraPosition? cameraPosition,
  }) async {
    if (deviceId != null &&
        await _switchActiveCameraTrack(
          participant,
          deviceId,
          cameraPosition: cameraPosition,
        )) {
      return const OrexCameraDeviceResult.success();
    }
    return _restartManagedCameraTrack(
      participant,
      deviceId: deviceId,
      cameraPosition: cameraPosition,
    );
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<OrexCameraDeviceResult> _restartManagedCameraTrack(
    lk.LocalParticipant participant, {
    required String? deviceId,
    required lk.CameraPosition? cameraPosition,
  }) async {
    try {
      // Do not manually create/publish a second camera track here. Mixing
      // setCameraEnabled() with publishVideoTrack() can leave more than one
      // camera publication alive; remote UIs may keep rendering the stale one
      // and some Android camera HALs keep both physical cameras busy.
      if (participant.isCameraEnabled()) {
        await participant.setCameraEnabled(false);
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final selectedDeviceId = deviceId ?? normalizedCameraDeviceId();
      final options = cameraPosition == null
          ? lk.CameraCaptureOptions(deviceId: selectedDeviceId)
          : lk.CameraCaptureOptions(
              deviceId: selectedDeviceId,
              cameraPosition: cameraPosition,
            );
      await participant.setCameraEnabled(
        true,
        cameraCaptureOptions: options,
      );
      _lastAppliedCameraDeviceId = selectedDeviceId;
      if (cameraPosition != null) _lastRequestedCameraPosition = cameraPosition;
      return const OrexCameraDeviceResult.success();
    } catch (e) {
      OrexLog.d('Call', 'managed camera restart failed', e);
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
    String deviceId, {
    required lk.CameraPosition? cameraPosition,
  }) async {
    if (OrexScreenShareController.desktopNeedsExplicitSource) return false;
    if (!participant.isCameraEnabled()) return false;
    final track = _localCameraTrack(participant);
    if (track == null) return false;
    try {
      if (cameraPosition != null) {
        // For built-in phone cameras use LiveKit's semantic front/back API.
        // It restarts the existing published track and replaces the sender's
        // media track, so the remote participant follows the switch without a
        // second camera publication. It also keeps renderer mirror metadata in
        // sync with the real facing direction.
        await lk.LocalVideoTrackExt(track).setCameraPosition(cameraPosition);
      } else {
        // External/unknown cameras still need exact device selection. Keep
        // fastSwitch disabled: the regular restart path stops the old capture
        // before opening the new one.
        await lk.LocalVideoTrackExt(
          track,
        ).switchCamera(deviceId, fastSwitch: false);
      }
      _lastAppliedCameraDeviceId = deviceId;
      if (cameraPosition != null) _lastRequestedCameraPosition = cameraPosition;
      OrexLog.d(
        'Call',
        'camera switched on published track device=$deviceId position=$cameraPosition',
      );
      return true;
    } catch (e) {
      OrexLog.d('Call', 'camera switch failed device=$deviceId', e);
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
    final options = track.currentOptions;
    if (options is lk.CameraCaptureOptions) {
      final id = normalizeSelectedDeviceId(options.deviceId);
      if (id != null) return id;
    }
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

  lk.CameraPosition? _currentCameraPositionFromTrack(
    lk.LocalParticipant? participant,
  ) {
    if (participant == null) return null;
    final track = _localCameraTrack(participant);
    final options = track?.currentOptions;
    return options is lk.CameraCaptureOptions ? options.cameraPosition : null;
  }

  static String? deviceIdForPosition(
    List<OrexAudioDevice> devices,
    lk.CameraPosition? position,
  ) {
    if (position == null) return null;
    for (final device in devices) {
      if (cameraPositionForCategory(device.category) == position) {
        return device.id;
      }
    }
    return null;
  }

  static lk.CameraPosition? cameraPositionForCategory(String? category) {
    return switch (category) {
      'front_camera' => lk.CameraPosition.front,
      'back_camera' => lk.CameraPosition.back,
      _ => null,
    };
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

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'android_screen_share_platform.dart';
import '../logging/orex_logger.dart';

final class OrexScreenShareResult {
  const OrexScreenShareResult({this.error});

  final String? error;
}

final class OrexScreenShareController {
  bool isOn = false;
  bool isBusy = false;
  lk.LocalVideoTrack? _track;
  lk.LocalParticipant? _androidParticipant;
  bool _androidForegroundStarted = false;
  bool _androidStopRequested = false;
  bool _androidStopInProgress = false;

  /// Used when Android ends capture from the status chip, notification or lock
  /// screen while the Flutter call controls are not currently visible.
  void Function()? onStateChanged;

  late final OrexAndroidScreenShareStopHandler _androidStopHandler =
      _handleAndroidStopRequest;

  Future<OrexScreenShareResult> toggle({
    required lk.LocalParticipant participant,
    required bool canPublishMedia,
    String? sourceId,
    String? sourceName,
    String? sourceType,
  }) async {
    if (isBusy || _androidStopInProgress) {
      return const OrexScreenShareResult(error: null);
    }
    isBusy = true;
    try {
      if (!canPublishMedia) {
        return const OrexScreenShareResult(
          error: 'В режиме просмотра трансляция экрана недоступна',
        );
      }
      if (!isSupported) {
        return const OrexScreenShareResult(
          error: 'Трансляция экрана на этой платформе недоступна',
        );
      }

      final next = !isOn;
      if (!next) {
        await stop(participant: participant);
        return const OrexScreenShareResult();
      }

      if (sourceId == null && desktopNeedsExplicitSource) {
        return const OrexScreenShareResult(error: 'Выберите источник экрана');
      }

      if (OrexAndroidScreenSharePlatform.isAndroid) {
        _androidStopRequested = false;
        final permissionGranted =
            await OrexAndroidScreenSharePlatform.requestCapturePermission();
        if (!permissionGranted) return const OrexScreenShareResult();

        // Android 14 requires this foreground owner after the consent result,
        // but before flutter_webrtc turns that token into a MediaProjection.
        final foregroundReady =
            await OrexAndroidScreenSharePlatform.startForeground();
        if (!foregroundReady) {
          return const OrexScreenShareResult(
            error: 'Не удалось подготовить системную демонстрацию экрана',
          );
        }
        _androidForegroundStarted = true;
        _androidParticipant = participant;
        OrexAndroidScreenSharePlatform.setStopHandler(_androidStopHandler);
        OrexAndroidScreenSharePlatform.armStopHandling();
      }

      await _start(
        participant: participant,
        sourceId: sourceId,
        sourceName: sourceName,
        sourceType: sourceType,
      );
      return const OrexScreenShareResult();
    } catch (e, st) {
      await cleanupLocals();
      isOn = false;
      OrexLog.d(
        'Call',
        'screen share failed sourceId=$sourceId type=$sourceType name=${sourceName ?? ''} stack=$st',
        e,
      );
      final sourcePart = sourceName?.trim().isNotEmpty == true
          ? ' для "${sourceName!.trim()}"'
          : '';
      return OrexScreenShareResult(
        error: 'Не удалось включить трансляцию экрана$sourcePart',
      );
    } finally {
      isBusy = false;
      await _drainAndroidStopRequest(participant);
    }
  }

  Future<void> _start({
    required lk.LocalParticipant participant,
    required String? sourceId,
    required String? sourceName,
    required String? sourceType,
  }) async {
    final sourceLabel = sourceName?.trim().isNotEmpty == true
        ? sourceName!.trim()
        : sourceId ?? 'default';
    OrexLog.d(
      'Call',
      'screen share start requested sourceId=$sourceId type=$sourceType name=$sourceLabel',
    );

    if (!kIsWeb && desktopNeedsExplicitSource && sourceId != null) {
      await _startDesktop(
        participant: participant,
        sourceId: sourceId,
        sourceName: sourceName,
        sourceType: sourceType,
        sourceLabel: sourceLabel,
      );
      return;
    }

    if (OrexAndroidScreenSharePlatform.isAndroid) {
      await _startAndroid(participant: participant, sourceLabel: sourceLabel);
      return;
    }

    final options = captureOptions(sourceId);
    await participant.setScreenShareEnabled(
      true,
      screenShareCaptureOptions: options,
    );
    isOn = true;
    OrexLog.d(
      'Call',
      'screen share started via setScreenShareEnabled sourceId=$sourceId',
    );
  }

  Future<void> _startAndroid({
    required lk.LocalParticipant participant,
    required String sourceLabel,
  }) async {
    await _publishTrack(
      participant: participant,
      options: captureOptions(null),
      sourceId: null,
      sourceType: 'screen',
      sourceLabel: sourceLabel,
    );
    final track = _track;
    final trackId = track?.mediaStreamTrack.id;
    if (trackId != null) {
      OrexAndroidScreenSharePlatform.trackProjection(trackId);
    }
  }

  Future<void> _startDesktop({
    required lk.LocalParticipant participant,
    required String sourceId,
    required String? sourceName,
    required String? sourceType,
    required String sourceLabel,
  }) async {
    Object? lastError;
    StackTrace? lastStack;
    final candidates = candidateIds(
      sourceId: sourceId,
      sourceType: sourceType,
      sourceName: sourceName,
    );
    for (final candidateId in candidates) {
      final options = captureOptions(candidateId);
      try {
        OrexLog.d(
          'Call',
          'screen share candidate sourceId=${candidateId ?? 'default'} originalId=$sourceId type=$sourceType name=$sourceLabel',
        );
        await _publishTrack(
          participant: participant,
          options: options,
          sourceId: candidateId,
          sourceType: sourceType,
          sourceLabel: sourceLabel,
        );
        lastError = null;
        lastStack = null;
        break;
      } catch (e, st) {
        lastError = e;
        lastStack = st;
        OrexLog.d(
          'Call',
          'createScreenShareTrack failed candidate=${candidateId ?? 'default'} originalId=$sourceId type=$sourceType name=$sourceLabel stack=$st',
          e,
        );
        await cleanupLocals();
      }
    }

    if (!isOn && lastError != null) {
      await _tryDesktopFallback(
        participant: participant,
        sourceId: sourceId,
        sourceType: sourceType,
      );
    }

    if (!isOn && lastError != null) {
      Error.throwWithStackTrace(lastError, lastStack ?? StackTrace.current);
    }
  }

  Future<void> _tryDesktopFallback({
    required lk.LocalParticipant participant,
    required String sourceId,
    required String? sourceType,
  }) async {
    if (!isDesktopScreenSource(sourceType)) {
      final options = captureOptions(sourceId);
      try {
        await participant.setScreenShareEnabled(
          true,
          screenShareCaptureOptions: options,
        );
        isOn = true;
        OrexLog.d(
          'Call',
          'screen share started via setScreenShareEnabled sourceId=$sourceId',
        );
      } catch (_) {
        return;
      }
      return;
    }

    try {
      OrexLog.d(
        'Call',
        'screen share final fallback setScreenShareEnabled without options',
      );
      await participant.setScreenShareEnabled(true);
      isOn = true;
    } catch (_) {
      return;
    }
  }

  Future<void> _publishTrack({
    required lk.LocalParticipant participant,
    required lk.ScreenShareCaptureOptions options,
    required String? sourceId,
    required String? sourceType,
    required String sourceLabel,
  }) async {
    final track = await lk.LocalVideoTrack.createScreenShareTrack(options);
    // Retain the native capturer before the publish await. If signalling or
    // LiveKit publishing fails, the caller's cleanup must still stop the
    // MediaProjection and release its foreground owner.
    _track = track;
    await participant.publishVideoTrack(track);
    isOn = true;
    OrexLog.d(
      'Call',
      'screen share started via createScreenShareTrack sourceId=${sourceId ?? 'default'} type=$sourceType name=$sourceLabel',
    );
  }

  Future<void> stop({lk.LocalParticipant? participant}) async {
    if (participant != null) {
      try {
        await participant.setScreenShareEnabled(false);
      } catch (e) {
        OrexLog.d('Call', 'screen share disable failed', e);
      }
    }

    await cleanupLocals();
    isOn = false;
  }

  Future<void> cleanupLocals() async {
    final androidForegroundStarted = _androidForegroundStarted;
    _androidForegroundStarted = false;
    _androidStopRequested = false;
    _androidParticipant = null;
    if (androidForegroundStarted) {
      // Prevent explicit track disposal from being reported as a system revoke.
      OrexAndroidScreenSharePlatform.clearTrackedProjection();
      OrexAndroidScreenSharePlatform.clearStopHandler(_androidStopHandler);
    }

    final track = _track;
    _track = null;
    try {
      await track?.stop();
    } catch (e) {
      OrexLog.d('Call', 'screen share track stop failed', e);
    }
    try {
      await track?.dispose();
    } catch (e) {
      OrexLog.d('Call', 'screen share track dispose failed', e);
    }
    if (androidForegroundStarted) {
      await OrexAndroidScreenSharePlatform.stopForeground();
    }
  }

  Future<void> _handleAndroidStopRequest(String reason) async {
    if (_androidForegroundStarted == false && !isOn) return;
    if (isBusy) {
      _androidStopRequested = true;
      return;
    }
    await _stopFromAndroid(reason, _androidParticipant);
  }

  /// Drains a stop received while capture/publish was awaiting the platform.
  ///
  /// The flag is examined only after [isBusy] transitions to false. That
  /// avoids losing a revoke delivered just after the last await in start-up.
  Future<void> _drainAndroidStopRequest(lk.LocalParticipant participant) async {
    if (!_androidStopRequested) return;
    _androidStopRequested = false;
    await _stopFromAndroid(
      'deferred_system_stop',
      _androidParticipant ?? participant,
    );
  }

  Future<void> _stopFromAndroid(
    String reason,
    lk.LocalParticipant? participant,
  ) async {
    if (_androidStopInProgress) return;
    _androidStopInProgress = true;
    OrexLog.d('Call', 'Android stopped screen share reason=$reason');
    try {
      await stop(participant: participant);
      onStateChanged?.call();
    } finally {
      _androidStopInProgress = false;
    }
  }

  static lk.ScreenShareCaptureOptions captureOptions(String? sourceId) {
    final normalized = sourceId?.trim();
    if (normalized == null || normalized.isEmpty) {
      return const lk.ScreenShareCaptureOptions(maxFrameRate: 15.0);
    }
    return lk.ScreenShareCaptureOptions(
      sourceId: normalized,
      maxFrameRate: 15.0,
    );
  }

  static List<String?> candidateIds({
    required String? sourceId,
    required String? sourceType,
    required String? sourceName,
  }) {
    final result = <String?>[];
    void add(String? value) {
      final normalized = value?.trim();
      final candidate = normalized == null || normalized.isEmpty
          ? null
          : normalized;
      if (result.contains(candidate)) return;
      result.add(candidate);
    }

    add(sourceId);
    if (isDesktopScreenSource(sourceType)) {
      final index = screenIndexFromName(sourceName);
      if (index != null) add('screen:$index:0');
      final rawId = sourceId?.trim();
      if (rawId != null && rawId.isNotEmpty && !rawId.startsWith('screen:')) {
        add('screen:$rawId:0');
      }
      add(null);
    }
    return result;
  }

  static int? screenIndexFromName(String? sourceName) {
    if (sourceName == null) return null;
    final match = RegExp(r'(\d+)').firstMatch(sourceName);
    if (match == null) return null;
    final number = int.tryParse(match.group(1) ?? '');
    if (number == null) return null;
    return number <= 0 ? 0 : number - 1;
  }

  static bool isDesktopScreenSource(String? sourceType) =>
      sourceType == null || sourceType == 'screen';

  static bool get isSupported {
    if (kIsWeb) return true;
    return true;
  }

  static bool get desktopNeedsExplicitSource {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }
}

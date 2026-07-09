import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../logging/orex_logger.dart';

final class OrexScreenShareResult {
  const OrexScreenShareResult({this.error});

  final String? error;
}

final class OrexScreenShareController {
  bool isOn = false;
  bool isBusy = false;
  lk.LocalVideoTrack? _track;

  Future<OrexScreenShareResult> toggle({
    required lk.LocalParticipant participant,
    required bool canPublishMedia,
    String? sourceId,
    String? sourceName,
    String? sourceType,
  }) async {
    if (isBusy) return const OrexScreenShareResult(error: null);
    isBusy = true;
    try {
      if (!canPublishMedia) {
        return const OrexScreenShareResult(
          error: 'В режиме просмотра трансляция экрана недоступна',
        );
      }
      if (!isSupported) {
        return const OrexScreenShareResult(
          error: 'Трансляция экрана на Android будет реализована позже',
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
    await participant.publishVideoTrack(track);
    _track = track;
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
    return defaultTargetPlatform != TargetPlatform.android;
  }

  static bool get desktopNeedsExplicitSource {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }
}

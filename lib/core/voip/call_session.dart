import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:record/record.dart' as rec;
import 'package:matrix/matrix.dart';

import '../audio/audio_device_utils.dart';
import '../audio/audio_cue_service.dart';
import '../audio/native_audio_devices.dart';
import '../config/orex_config.dart';
import '../logging/orex_logger.dart';

enum CallStatus { connecting, connected, failed, ended }

/// Нативный звонок на стеке Element Call (MatrixRTC): мы используем ВАШ
/// LiveKit + lk-jwt-service и рисуем СВОЙ интерфейс — без встраивания
/// call.element.io.
///
/// Два клиента Orex, нажавшие звонок в одной Matrix-комнате, получают от
/// lk-jwt-service одну и ту же LiveKit-комнату (она выводится из roomId),
/// поэтому встречаются в одном звонке.
class CallSession extends ChangeNotifier {
  CallSession({
    required this.client,
    required this.matrixRoomId,
    this.initialMicOn = true,
    this.canUseMic = true,
    this.listenOnly = false,
    this.canUseMicNow,
    this.audioInputDeviceIdProvider,
    this.audioOutputDeviceIdProvider,
    this.videoInputDeviceIdProvider,
    this.cameraDeviceIdSink,
    this.speakingThresholdDbProvider,
    this.speakingThresholdEnabledProvider,
    this.callMicPreferenceSink,
  });

  final Client client;
  final String matrixRoomId;
  final bool initialMicOn;
  bool canUseMic;
  bool listenOnly;
  final bool Function()? canUseMicNow;
  final String? Function()? audioInputDeviceIdProvider;
  final String? Function()? audioOutputDeviceIdProvider;
  final String? Function()? videoInputDeviceIdProvider;
  final FutureOr<void> Function(String? deviceId)? cameraDeviceIdSink;
  final double Function()? speakingThresholdDbProvider;
  final bool Function()? speakingThresholdEnabledProvider;
  final FutureOr<void> Function(bool enabled)? callMicPreferenceSink;

  CallStatus status = CallStatus.connecting;
  String? error;
  String? cameraError; // камера не запустилась (звонок при этом идёт со звуком)
  lk.Room? _room;
  lk.Room? get room => _room;
  bool _disposed = false;
  bool screenShareOn = false;
  bool _screenShareBusy = false;
  lk.LocalVideoTrack? _screenShareTrack;
  bool handRaised = false;
  final Map<String, VoiceParticipantState> _voiceStates = <String, VoiceParticipantState>{};
  Timer? _reactionClearTimer;
  Timer? _voiceStateRefreshTimer;
  Timer? _mediaRecoveryTimer;
  String? _lastAppliedInputDeviceId;
  String? _lastAppliedCameraDeviceId;
  rec.AudioRecorder? _voiceGateRecorder;
  StreamSubscription<Uint8List>? _voiceGatePcmSub;
  bool _voiceGateStarting = false;
  bool _voiceGateAppliedMuted = false;
  bool speakerMuted = false;
  bool _voiceGateTrackAccessFailed = false;
  int _cameraCycleCursor = -1;
  int _lastRemoteParticipantCount = 0;
  DateTime _lastVoiceAboveThreshold = DateTime.fromMillisecondsSinceEpoch(0);

  VoiceParticipantState voiceStateForUser(String userId) {
    final cached = _voiceStates[userId];
    if (cached != null) return cached;
    final content =
        client.getRoomById(matrixRoomId)?.getState('ru.orex.voice.participant', userId)?.content;
    return VoiceParticipantState.fromContent(content);
  }

  VoiceParticipantState get localVoiceState =>
      voiceStateForUser(client.userID ?? '');

  /// Подключался ли хоть кто-то ещё (для итогового сообщения «ответили/пропущен»).
  bool sawRemote = false;

  bool get micOn => _room?.localParticipant?.isMicrophoneEnabled() ?? false;
  bool get camOn => _room?.localParticipant?.isCameraEnabled() ?? false;
  bool get canPublishMedia => canUseMic && !listenOnly;

  List<lk.Participant> get participants => [
        if (_room?.localParticipant != null) _room!.localParticipant!,
        ...?_room?.remoteParticipants.values,
      ];

  Future<void> connect({required bool video}) async {
    status = CallStatus.connecting;
    error = null;
    notifyListeners();
    try {
      final creds = await _fetchCredentials();
      final room = lk.Room(
        roomOptions: const lk.RoomOptions(adaptiveStream: true, dynacast: true),
      );
      await room.prepareConnection(creds.url, creds.jwt);
      await room.connect(creds.url, creds.jwt);
      _room = room;
      await applyAudioOutput();
      if (initialMicOn) {
        await room.localParticipant?.setMicrophoneEnabled(
          true,
          audioCaptureOptions: _audioCaptureOptions(),
        );
      } else {
        await room.localParticipant?.setMicrophoneEnabled(false);
      }
      await _syncVoiceGate();
      if (video) {
        // Камера может быть недоступна (занята другим окном/приложением —
        // NotReadableError). Не валим весь звонок: продолжаем со звуком.
        try {
          await room.localParticipant?.setCameraEnabled(
          true,
          cameraCaptureOptions: _cameraCaptureOptions(),
        );
        } catch (e) {
          cameraError = '$e';
        }
      }

      if (_disposed) {
        // Сессию закрыли, пока подключались — сворачиваем комнату.
        await room.disconnect();
        await room.dispose();
        return;
      }
      room.addListener(_onRoom);
      _startVoiceStateRefresh();
      status = CallStatus.connected;
      notifyListeners();
    } catch (e) {
      if (_disposed) return;
      error = '$e';
      status = CallStatus.failed;
      notifyListeners();
    }
  }

  void _onRoom() {
    // Livekit при teardown комнаты шлёт события уже после dispose() — иначе
    // получаем «CallSession used after being disposed».
    if (_disposed) return;
    final remoteCount = _room?.remoteParticipants.length ?? 0;
    final remoteCountChanged = remoteCount != _lastRemoteParticipantCount;
    _lastRemoteParticipantCount = remoteCount;
    if (remoteCount > 0) sawRemote = true;
    _applySpeakerMute();
    _scheduleMediaRecovery(forceMicRestart: remoteCountChanged);
    notifyListeners();
  }

  void _scheduleMediaRecovery({bool forceMicRestart = false}) {
    _mediaRecoveryTimer?.cancel();
    _mediaRecoveryTimer = Timer(const Duration(milliseconds: 450), () async {
      if (_disposed || status != CallStatus.connected) return;
      try {
        await applyAudioOutput();
        await _restartMicIfInputChanged(force: forceMicRestart);
        await _restartCameraIfInputChanged();
        await _syncVoiceGate();
        _applySpeakerMute();
      } catch (e) {
        OrexLog.d('Call', 'media recovery failed', e);
      }
    });
  }


  void _startVoiceStateRefresh() {
    _voiceStateRefreshTimer?.cancel();
    _voiceStateRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_disposed || status != CallStatus.connected) return;
      // Voice participant state comes from Matrix room state, not LiveKit
      // media events. Poll lightly so remote hands/reactions appear in the
      // call UI without writing them to the chat timeline. Permission changes
      // are checked here too, so admins can accept a raised-hand request while
      // the listener stays in the current channel call.
      unawaited(refreshVoicePermissions());
      notifyListeners();
    });
  }

  Future<void> refreshVoicePermissions() async {
    final checker = canUseMicNow;
    if (checker == null || _disposed) return;
    final nextCanUseMic = checker();
    if (nextCanUseMic == canUseMic && listenOnly == !nextCanUseMic) return;

    canUseMic = nextCanUseMic;
    listenOnly = !nextCanUseMic;

    final lp = _room?.localParticipant;
    if (!nextCanUseMic && lp != null) {
      try {
        if (lp.isMicrophoneEnabled()) {
          await lp.setMicrophoneEnabled(false);
        }
      } catch (_) {}
      await _stopVoiceGate(resetTrack: true);
      try {
        if (lp.isCameraEnabled()) {
          await lp.setCameraEnabled(false);
        }
      } catch (_) {}
      if (screenShareOn) {
        try {
          await _stopScreenShare(lp: lp);
        } catch (_) {}
      }
    }


    if (nextCanUseMic && handRaised) {
      final userId = client.userID;
      if (userId != null && userId.isNotEmpty) {
        handRaised = false;
        _voiceStates[userId] = localVoiceState.copyWith(handRaised: false);
        await _publishVoiceParticipantState();
      }
    }

    if (nextCanUseMic && error == 'В режиме просмотра трансляция экрана недоступна') {
      error = null;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> toggleMic() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    if (!canPublishMedia) return;
    final next = !lp.isMicrophoneEnabled();
    await lp.setMicrophoneEnabled(
      next,
      audioCaptureOptions: next ? _audioCaptureOptions() : null,
    );
    final sink = callMicPreferenceSink;
    if (sink != null) await sink(next);
    await _syncVoiceGate();
    if (!_disposed) notifyListeners();
  }

  lk.AudioCaptureOptions _audioCaptureOptions() {
    final normalized = _normalizedInputDeviceId();
    _lastAppliedInputDeviceId = normalized;
    return lk.AudioCaptureOptions(
      deviceId: normalized,
      echoCancellation: true,
      noiseSuppression: true,
      autoGainControl: true,
      highPassFilter: true,
    );
  }

  String? _normalizedInputDeviceId() {
    final normalized = audioInputDeviceIdProvider?.call()?.trim();
    return normalized == null || normalized.isEmpty || normalized == 'default'
        ? null
        : normalized;
  }

  Future<void> syncAudioSettingsFromSettings() async {
    await applyAudioOutput();
    await _restartMicIfInputChanged();
    await _restartCameraIfInputChanged();
    await _syncVoiceGate();
  }

  Future<void> _restartMicIfInputChanged({bool force = false}) async {
    final lp = _room?.localParticipant;
    if (lp == null || !lp.isMicrophoneEnabled() || !canPublishMedia) return;

    final nextInputId = _normalizedInputDeviceId();
    if (!force && nextInputId == _lastAppliedInputDeviceId) return;

    await _stopVoiceGate(resetTrack: true);
    try {
      await lp.setMicrophoneEnabled(false);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      await lp.setMicrophoneEnabled(
        true,
        audioCaptureOptions: _audioCaptureOptions(),
      );
    } catch (e) {
      error = 'Не удалось восстановить микрофон: $e';
    }
    await _syncVoiceGate();
  }

  Future<void> applyAudioOutput() async {
    final id = audioOutputDeviceIdProvider?.call()?.trim();

    if (orexIsMobileNativePlatform) {
      await OrexNativeAudioDevices.selectOutput(id, inCall: true);
      return;
    }

    if (id == null || id.isEmpty || orexIsMobileRouteId(id)) return;

    final room = _room;
    try {
      if (room != null) {
        await room.setAudioOutputDevice(
          lk.MediaDevice(id, id, 'audiooutput', ''),
        );
      } else {
        await rtc.Helper.selectAudioOutput(id);
      }
    } catch (e) {
      OrexLog.d('Call', 'apply audio output failed id=$id', e);
      try {
        await rtc.Helper.selectAudioOutput(id);
      } catch (_) {}
    }
  }

  Future<void> syncVoiceGateFromSettings() => _syncVoiceGate();

  bool get _voiceGateEnabled =>
      speakingThresholdEnabledProvider?.call() ?? false;

  double get _voiceGateThresholdDb =>
      (speakingThresholdDbProvider?.call() ??
              AudioCueService.defaultSpeakingThresholdDb)
          .clamp(
            AudioCueService.minSpeakingThresholdDb,
            AudioCueService.maxSpeakingThresholdDb,
          )
          .toDouble();

  Future<void> _syncVoiceGate() async {
    final lp = _room?.localParticipant;
    final shouldRun = lp != null &&
        lp.isMicrophoneEnabled() &&
        canPublishMedia &&
        _voiceGateEnabled &&
        !_disposed;

    if (!shouldRun) {
      await _stopVoiceGate(resetTrack: true);
      return;
    }
    await _startVoiceGate();
  }

  Future<void> _startVoiceGate() async {
    if (_voiceGateRecorder != null || _voiceGateStarting) return;
    _voiceGateStarting = true;
    rec.AudioRecorder? recorder;
    try {
      recorder = rec.AudioRecorder();
      final allowed = await recorder.hasPermission();
      if (!allowed) throw StateError('Нет разрешения на микрофон');

      final device = await _recordDeviceFor(
        recorder,
        audioInputDeviceIdProvider?.call(),
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
      _voiceGatePcmSub = stream.listen(_onVoiceGatePcm, onError: (Object e) {
        OrexLog.d('Call', 'voice gate pcm stream failed', e);
      });
      _voiceGateRecorder = recorder;
      _voiceGateStarting = false;
      _lastVoiceAboveThreshold = DateTime.fromMillisecondsSinceEpoch(0);
      _setVoiceGateMuted(true);
      OrexLog.d('Call', 'voice gate started device=${device?.id ?? 'default'}');
    } catch (e, st) {
      _voiceGateStarting = false;
      OrexLog.d('Call', 'voice gate start failed stack=$st', e);
      try {
        await recorder?.dispose();
      } catch (_) {}
    }
  }

  Future<rec.InputDevice?> _recordDeviceFor(
    rec.AudioRecorder recorder,
    String? selectedId,
  ) async {
    final normalized = selectedId?.trim();
    if (normalized == null || normalized.isEmpty || normalized == 'default') {
      return null;
    }
    try {
      final devices = await recorder.listInputDevices();
      for (final device in devices) {
        if (device.id == normalized) return device;
      }
    } catch (e) {
      OrexLog.d('Call', 'voice gate device match failed', e);
    }
    return null;
  }

  void _onVoiceGatePcm(Uint8List data) {
    if (_disposed) return;
    final db = _dbFromPcm16(data);
    final now = DateTime.now();
    final threshold = _voiceGateThresholdDb;
    if (db >= threshold) {
      _lastVoiceAboveThreshold = now;
    }

    final active = db >= threshold ||
        now.difference(_lastVoiceAboveThreshold) <
            const Duration(milliseconds: 220);

    if (!_voiceGateEnabled || !canPublishMedia) {
      unawaited(_stopVoiceGate(resetTrack: true));
      return;
    }
    _setVoiceGateMuted(!active);
  }

  double _dbFromPcm16(Uint8List bytes) {
    if (bytes.length < 2) return AudioCueService.minSpeakingThresholdDb;
    final data = ByteData.sublistView(bytes);
    var sumSquares = 0.0;
    var count = 0;
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final sample = data.getInt16(i, Endian.little) / 32768.0;
      sumSquares += sample * sample;
      count++;
    }
    if (count == 0 || sumSquares <= 0) return AudioCueService.minSpeakingThresholdDb;
    final rms = math.sqrt(sumSquares / count);
    if (rms <= 0) return AudioCueService.minSpeakingThresholdDb;
    return (20 * math.log(rms) / math.ln10)
        .clamp(AudioCueService.minSpeakingThresholdDb, 0.0)
        .toDouble();
  }

  void _setVoiceGateMuted(bool muted) {
    if (_voiceGateAppliedMuted == muted) return;
    if (!_setLocalMicTrackEnabled(!muted)) {
      if (!_voiceGateTrackAccessFailed) {
        _voiceGateTrackAccessFailed = true;
        OrexLog.d('Call', 'voice gate cannot access local microphone track');
      }
      return;
    }
    _voiceGateAppliedMuted = muted;
  }

  bool _setLocalMicTrackEnabled(bool enabled) {
    final pub = _localMicrophonePublication();
    final track = pub == null ? null : _readDynamic(pub, 'track');
    return _setMediaTrackEnabled(track, enabled) ||
        _setMediaTrackEnabled(pub, enabled);
  }

  dynamic _localMicrophonePublication() {
    final lp = _room?.localParticipant;
    if (lp == null) return null;
    try {
      final dynamic dynamicParticipant = lp;
      final pub = dynamicParticipant.getTrackPublicationBySource(
        lk.TrackSource.microphone,
      );
      if (pub != null) return pub;
    } catch (_) {}
    try {
      final dynamic dynamicParticipant = lp;
      for (final dynamic pub in _dynamicValues(dynamicParticipant.audioTrackPublications)) {
        if (_readDynamic(pub, 'source') == lk.TrackSource.microphone) return pub;
      }
    } catch (_) {}
    try {
      final dynamic dynamicParticipant = lp;
      for (final dynamic pub in _dynamicValues(dynamicParticipant.trackPublications)) {
        if (_readDynamic(pub, 'source') == lk.TrackSource.microphone) return pub;
      }
    } catch (_) {}
    return null;
  }

  Iterable<dynamic> _dynamicValues(dynamic value) sync* {
    if (value == null) return;
    if (value is Map) {
      yield* value.values;
      return;
    }
    if (value is Iterable) yield* value;
  }

  bool _setMediaTrackEnabled(dynamic candidate, bool enabled) {
    if (candidate == null) return false;
    if (_trySetEnabled(candidate, enabled)) return true;

    for (final getter in const [
      'mediaStreamTrack',
      'rtcTrack',
      'track',
      'senderTrack',
    ]) {
      final nested = _readDynamic(candidate, getter);
      if (_trySetEnabled(nested, enabled)) return true;
    }

    for (final getter in const ['mediaStream', 'stream']) {
      final mediaStream = _readDynamic(candidate, getter);
      if (_setAudioTracksEnabled(mediaStream, enabled)) return true;
    }

    return false;
  }

  bool _trySetEnabled(dynamic candidate, bool enabled) {
    if (candidate == null) return false;
    try {
      candidate.enabled = enabled;
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _setAudioTracksEnabled(dynamic mediaStream, bool enabled) {
    if (mediaStream == null) return false;
    try {
      final tracks = mediaStream.getAudioTracks() as List<dynamic>;
      var changed = false;
      for (final rawTrack in tracks) {
        if (_trySetEnabled(rawTrack, enabled)) changed = true;
      }
      return changed;
    } catch (_) {
      return false;
    }
  }

  dynamic _readDynamic(dynamic object, String getterName) {
    if (object == null) return null;
    try {
      return switch (getterName) {
        'track' => object.track,
        'source' => object.source,
        'mediaStream' => object.mediaStream,
        'stream' => object.stream,
        'mediaStreamTrack' => object.mediaStreamTrack,
        'rtcTrack' => object.rtcTrack,
        'senderTrack' => object.senderTrack,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> _stopVoiceGate({required bool resetTrack}) async {
    final recorder = _voiceGateRecorder;
    _voiceGateRecorder = null;
    _voiceGateStarting = false;
    await _voiceGatePcmSub?.cancel();
    _voiceGatePcmSub = null;
    try {
      await recorder?.stop();
    } catch (_) {}
    try {
      await recorder?.dispose();
    } catch (_) {}
    if (resetTrack && _voiceGateAppliedMuted) {
      _setVoiceGateMuted(false);
    }
    _voiceGateAppliedMuted = false;
  }


  Future<void> toggleSpeakerMute() async {
    speakerMuted = !speakerMuted;
    _applySpeakerMute();
    if (!_disposed) notifyListeners();
  }

  void _applySpeakerMute() {
    final room = _room;
    if (room == null) return;
    final enabled = !speakerMuted;
    for (final participant in room.remoteParticipants.values) {
      _setParticipantAudioEnabled(participant, enabled);
    }
  }

  void _setParticipantAudioEnabled(lk.Participant participant, bool enabled) {
    try {
      final dynamic dynamicParticipant = participant;
      for (final dynamic pub in _dynamicValues(dynamicParticipant.audioTrackPublications)) {
        _setMediaTrackEnabled(pub, enabled);
      }
    } catch (_) {}
    try {
      final dynamic dynamicParticipant = participant;
      for (final dynamic pub in _dynamicValues(dynamicParticipant.trackPublications)) {
        if (_readDynamic(pub, 'source') == lk.TrackSource.microphone) {
          _setMediaTrackEnabled(pub, enabled);
        }
      }
    } catch (_) {}
  }

  Future<void> toggleScreenShare({
    String? sourceId,
    String? sourceName,
    String? sourceType,
  }) async {
    final lp = _room?.localParticipant;
    if (lp == null || _screenShareBusy) return;
    _screenShareBusy = true;
    try {
      // Android media projection requires native foreground-service wiring
      // outside lib/. До этого не открываем системный picker, чтобы не ловить
      // native crash после выбора экрана.
      if (!canPublishMedia) {
        error = 'В режиме просмотра трансляция экрана недоступна';
        if (!_disposed) notifyListeners();
        return;
      }
      if (defaultTargetPlatform == TargetPlatform.android) {
        error = 'Трансляция экрана на Android будет реализована позже';
        if (!_disposed) notifyListeners();
        return;
      }

      final next = !screenShareOn;
      if (!next) {
        await _stopScreenShare(lp: lp);
        error = null;
        return;
      }

      if (sourceId == null && _desktopNeedsExplicitSource) {
        error = 'Выберите источник экрана';
        if (!_disposed) notifyListeners();
        return;
      }

      final sourceLabel = sourceName?.trim().isNotEmpty == true
          ? sourceName!.trim()
          : sourceId ?? 'default';
      OrexLog.d(
        'Call',
        'screen share start requested sourceId=$sourceId type=$sourceType name=$sourceLabel',
      );

      if (!kIsWeb && _desktopNeedsExplicitSource && sourceId != null) {
        Object? lastError;
        StackTrace? lastStack;
        final candidates = _screenShareCandidateIds(
          sourceId: sourceId,
          sourceType: sourceType,
          sourceName: sourceName,
        );
        for (final candidateId in candidates) {
          final options = _screenShareOptions(candidateId);
          try {
            OrexLog.d(
              'Call',
              'screen share candidate sourceId=${candidateId ?? 'default'} originalId=$sourceId type=$sourceType name=$sourceLabel',
            );
            await _publishScreenShareTrack(
              lp: lp,
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
            await _cleanupScreenShareLocals();
          }
        }

        if (!screenShareOn && lastError != null) {
          if (!_isDesktopScreenSource(sourceType)) {
            // Для окна не падаем молча на весь экран: можно расшарить лишнее.
            final options = _screenShareOptions(sourceId);
            try {
              await lp.setScreenShareEnabled(
                true,
                screenShareCaptureOptions: options,
              );
              screenShareOn = true;
              OrexLog.d('Call', 'screen share started via setScreenShareEnabled sourceId=$sourceId');
            } catch (e, st) {
              lastError = e;
              lastStack = st;
            }
          } else {
            // Последний шанс для экранов: вызвать helper без options вообще.
            // В некоторых сборках flutter_webrtc это отличается от options
            // без sourceId и даёт системный default-display path.
            try {
              OrexLog.d('Call', 'screen share final fallback setScreenShareEnabled without options');
              await lp.setScreenShareEnabled(true);
              screenShareOn = true;
              lastError = null;
              lastStack = null;
            } catch (e, st) {
              lastError = e;
              lastStack = st;
            }
          }
        }

        if (!screenShareOn && lastError != null) {
          Error.throwWithStackTrace(lastError, lastStack ?? StackTrace.current);
        }
      } else {
        final options = _screenShareOptions(sourceId);
        await lp.setScreenShareEnabled(
          true,
          screenShareCaptureOptions: options,
        );
        screenShareOn = true;
        OrexLog.d('Call', 'screen share started via setScreenShareEnabled sourceId=$sourceId');
      }
      error = null;
    } catch (e, st) {
      await _cleanupScreenShareLocals();
      screenShareOn = false;
      OrexLog.d(
        'Call',
        'screen share failed sourceId=$sourceId type=$sourceType name=${sourceName ?? ''} stack=$st',
        e,
      );
      final sourcePart = sourceName?.trim().isNotEmpty == true
          ? ' для "${sourceName!.trim()}"'
          : '';
      error = 'Не удалось включить трансляцию экрана$sourcePart: $e';
    } finally {
      _screenShareBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  lk.ScreenShareCaptureOptions _screenShareOptions(String? sourceId) {
    final normalized = sourceId?.trim();
    if (normalized == null || normalized.isEmpty) {
      return const lk.ScreenShareCaptureOptions(maxFrameRate: 15.0);
    }
    return lk.ScreenShareCaptureOptions(sourceId: normalized, maxFrameRate: 15.0);
  }

  List<String?> _screenShareCandidateIds({
    required String? sourceId,
    required String? sourceType,
    required String? sourceName,
  }) {
    final result = <String?>[];
    void add(String? value) {
      final normalized = value?.trim();
      final candidate = normalized == null || normalized.isEmpty ? null : normalized;
      if (result.contains(candidate)) return;
      result.add(candidate);
    }

    add(sourceId);
    if (_isDesktopScreenSource(sourceType)) {
      final index = _screenIndexFromName(sourceName);
      if (index != null) add('screen:$index:0');
      final rawId = sourceId?.trim();
      if (rawId != null && rawId.isNotEmpty) {
        add('screen:$rawId:0');
      }
      add(null);
    }
    return result;
  }

  int? _screenIndexFromName(String? sourceName) {
    if (sourceName == null) return null;
    final match = RegExp(r'(\d+)').firstMatch(sourceName);
    if (match == null) return null;
    final number = int.tryParse(match.group(1) ?? '');
    if (number == null) return null;
    return number <= 0 ? 0 : number - 1;
  }

  Future<void> _publishScreenShareTrack({
    required lk.LocalParticipant lp,
    required lk.ScreenShareCaptureOptions options,
    required String? sourceId,
    required String? sourceType,
    required String sourceLabel,
  }) async {
    final track = await lk.LocalVideoTrack.createScreenShareTrack(options);
    await lp.publishVideoTrack(track);
    _screenShareTrack = track;
    screenShareOn = true;
    OrexLog.d(
      'Call',
      'screen share started via createScreenShareTrack sourceId=${sourceId ?? 'default'} type=$sourceType name=$sourceLabel',
    );
  }

  bool _isDesktopScreenSource(String? sourceType) =>
      sourceType == null || sourceType == 'screen';

  Future<void> _stopScreenShare({lk.LocalParticipant? lp}) async {
    final participant = lp ?? _room?.localParticipant;
    // Не используем LocalParticipant.unpublishTrack(): в части версий
    // livekit_client этот метод отсутствует/не экспортируется, из-за чего
    // flutter analyze падает. Для screen-share LiveKit умеет выключать
    // публикацию по TrackSource через setScreenShareEnabled(false), а локальный
    // track ниже дополнительно останавливается и dispose-ится.
    if (participant != null) {
      try {
        await participant.setScreenShareEnabled(false);
      } catch (_) {}
    }

    await _cleanupScreenShareLocals();
    screenShareOn = false;
  }

  Future<void> _cleanupScreenShareLocals() async {
    final track = _screenShareTrack;
    _screenShareTrack = null;
    try {
      await track?.stop();
    } catch (_) {}
    try {
      await track?.dispose();
    } catch (_) {}
  }

  bool get _desktopNeedsExplicitSource {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  Future<void> toggleHandRaised({bool? force}) async {
    final userId = client.userID;
    if (userId == null || userId.isEmpty) return;
    final next = force ?? !handRaised;
    if (handRaised == next) return;
    handRaised = next;
    _voiceStates[userId] = localVoiceState.copyWith(handRaised: next);
    await _publishVoiceParticipantState();
    if (!_disposed) notifyListeners();
  }

  Future<void> sendVoiceReaction(String emoji) async {
    final userId = client.userID;
    if (userId == null || userId.isEmpty) return;
    _reactionClearTimer?.cancel();
    _voiceStates[userId] = localVoiceState.copyWith(
      reaction: emoji,
      reactionTs: DateTime.now().millisecondsSinceEpoch,
    );
    await _publishVoiceParticipantState();
    if (!_disposed) notifyListeners();
    _reactionClearTimer = Timer(const Duration(seconds: 4), () async {
      if (_disposed) return;
      _voiceStates[userId] = localVoiceState.copyWith(clearReaction: true);
      await _publishVoiceParticipantState();
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> _publishVoiceParticipantState() async {
    final userId = client.userID;
    if (userId == null || userId.isEmpty) return;
    final state = localVoiceState;
    try {
      await client.setRoomStateWithKey(
        matrixRoomId,
        'ru.orex.voice.participant',
        userId,
        {
          'hand_raised': state.handRaised,
          if (state.reaction != null) 'reaction': state.reaction,
          if (state.reactionTs != null) 'reaction_ts': state.reactionTs,
        },
      );
    } catch (e) {
      error = 'Не удалось обновить состояние голосового канала: $e';
      // Voice participant state is UX-only; failed state publish must not break
      // the media session.
    }
  }

  Future<void> toggleCam() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    if (!canPublishMedia) {
      cameraError = 'В режиме просмотра камера недоступна';
      if (!_disposed) notifyListeners();
      return;
    }
    try {
      final next = !lp.isCameraEnabled();
      await lp.setCameraEnabled(
        next,
        cameraCaptureOptions: next ? _cameraCaptureOptions() : null,
      );
      cameraError = null;
    } catch (e) {
      cameraError = '$e';
    }
    if (!_disposed) notifyListeners();
  }

  lk.CameraCaptureOptions _cameraCaptureOptions() {
    final normalized = _normalizedCameraDeviceId();
    _lastAppliedCameraDeviceId = normalized;
    return lk.CameraCaptureOptions(deviceId: normalized);
  }

  String? _normalizedCameraDeviceId() {
    final normalized = videoInputDeviceIdProvider?.call()?.trim();
    return normalized == null || normalized.isEmpty || normalized == 'default'
        ? null
        : normalized;
  }

  Future<void> _restartCameraIfInputChanged({bool force = false}) async {
    final lp = _room?.localParticipant;
    if (lp == null || !lp.isCameraEnabled() || !canPublishMedia) return;

    final nextCameraId = _normalizedCameraDeviceId();
    if (!force && nextCameraId == _lastAppliedCameraDeviceId) return;

    try {
      await lp.setCameraEnabled(false);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await lp.setCameraEnabled(
        true,
        cameraCaptureOptions: _cameraCaptureOptions(),
      );
      cameraError = null;
    } catch (e) {
      cameraError = '$e';
    }
  }

  Future<void> selectCameraDevice(String? deviceId) async {
    final normalized = deviceId?.trim();
    _cameraCycleCursor = -1;
    final sink = cameraDeviceIdSink;
    if (sink != null) {
      await sink(normalized == null || normalized.isEmpty ? null : normalized);
    }
    await _restartCameraIfInputChanged(force: true);
    if (!_disposed) notifyListeners();
  }

  Future<void> cycleCameraDevice(List<String> deviceIds) async {
    final ids = [
      for (final id in deviceIds.map((id) => id.trim()))
        if (id.isNotEmpty) id,
    ];
    if (ids.isEmpty) return;
    final current = _normalizedCameraDeviceId();
    var index = current == null ? _cameraCycleCursor : ids.indexOf(current);
    if (index < 0) {
      // При системной камере LiveKit обычно уже использует первое устройство.
      // Поэтому первый cycle должен перейти на следующее, а не включить то же самое.
      index = ids.length == 1 ? 0 : 0;
    }
    final nextIndex = ids.length == 1 ? 0 : (index + 1) % ids.length;
    _cameraCycleCursor = nextIndex;
    final next = ids[nextIndex];
    final sink = cameraDeviceIdSink;
    if (sink != null) await sink(next);
    await _restartCameraIfInputChanged(force: true);
    if (!_disposed) notifyListeners();
  }

  Future<void> hangUp() async {
    status = CallStatus.ended;
    _voiceStateRefreshTimer?.cancel();
    _voiceStateRefreshTimer = null;
    _mediaRecoveryTimer?.cancel();
    _mediaRecoveryTimer = null;
    await _stopVoiceGate(resetTrack: true);
    final room = _room;
    _room = null;
    if (room != null) {
      // Снимаем слушатель ДО teardown, чтобы события закрытия не дёргали нас.
      room.removeListener(_onRoom);
      try {
        if (screenShareOn) {
          await _stopScreenShare(lp: room.localParticipant);
        }
      } catch (_) {}
      try {
        await room.disconnect();
      } catch (_) {}
      try {
        await room.dispose();
      } catch (_) {}
    }
    if (orexIsAndroidNativePlatform) {
      await OrexNativeAudioDevices.selectOutput(null, inCall: false);
    }
    if (!_disposed) notifyListeners();
  }

  // OpenID-токен Matrix -> lk-jwt-service /sfu/get -> {url, jwt}
  Future<_Creds> _fetchCredentials() async {
    final userId = client.userID!;

    final openId = await client.requestOpenIdToken(userId, <String, Object?>{});

    final resp = await http
        .post(
          OrexConfig.jwtServiceUri.replace(path: '/sfu/get'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'room': matrixRoomId,
            'openid_token': {
              'access_token': openId.accessToken,
              'token_type': openId.tokenType,
              'matrix_server_name': openId.matrixServerName,
            },
            'device_id': client.deviceID ?? '',
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) {
      // Не добавляем resp.body: backend-ошибки иногда содержат диагностические
      // поля, которые не должны попадать в UI/log вместе с auth-контекстом.
      throw Exception('lk-jwt-service ${resp.statusCode}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final url = json['url'] as String?;
    final jwt = json['jwt'] as String?;
    if (url == null || jwt == null || jwt.isEmpty) {
      throw StateError('lk-jwt-service вернул неполные credentials');
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'wss' && uri.scheme != 'https')) {
      throw StateError('LiveKit URL должен быть wss:// или https://');
    }
    return _Creds(url: url, jwt: jwt);
  }

  @override
  void dispose() {
    _disposed = true;
    _reactionClearTimer?.cancel();
    _voiceStateRefreshTimer?.cancel();
    _mediaRecoveryTimer?.cancel();
    _voiceGatePcmSub?.cancel();
    _voiceGateRecorder?.dispose();
    _room?.removeListener(_onRoom);
    _room?.dispose();
    _room = null;
    if (orexIsAndroidNativePlatform) {
      unawaited(OrexNativeAudioDevices.selectOutput(null, inCall: false));
    }
    super.dispose();
  }
}

class _Creds {
  _Creds({required this.url, required this.jwt});
  final String url;
  final String jwt;
}

class VoiceParticipantState {
  const VoiceParticipantState({
    this.handRaised = false,
    this.reaction,
    this.reactionTs,
  });

  factory VoiceParticipantState.fromContent(Map<dynamic, dynamic>? content) {
    if (content == null) return const VoiceParticipantState();
    return VoiceParticipantState(
      handRaised: content['hand_raised'] == true,
      reaction: content['reaction']?.toString(),
      reactionTs: content['reaction_ts'] is num
          ? (content['reaction_ts'] as num).toInt()
          : null,
    );
  }

  final bool handRaised;
  final String? reaction;
  final int? reactionTs;

  VoiceParticipantState copyWith({
    bool? handRaised,
    String? reaction,
    int? reactionTs,
    bool clearReaction = false,
  }) {
    return VoiceParticipantState(
      handRaised: handRaised ?? this.handRaised,
      reaction: clearReaction ? null : reaction ?? this.reaction,
      reactionTs: clearReaction ? null : reactionTs ?? this.reactionTs,
    );
  }
}

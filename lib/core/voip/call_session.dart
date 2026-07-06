import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart';

import '../audio/audio_device_utils.dart';
import '../audio/native_audio_devices.dart';
import '../logging/orex_logger.dart';
import 'camera_device_controller.dart';
import 'livekit_credentials_client.dart';
import 'livekit_track_access.dart';
import 'screen_share_controller.dart';
import 'voice_gate_controller.dart';
import 'voice_participant_state.dart';
import 'voice_state_repository.dart';

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
    OrexLiveKitCredentialsClient? credentialsClient,
  }) : _credentialsClient =
           credentialsClient ?? const OrexLiveKitCredentialsClient() {
    _micRequestedOn = initialMicOn;
    _voiceStates = OrexVoiceStateRepository(
      localUserIdProvider: () => client.userID,
      readContent: (userId) => client
          .getRoomById(matrixRoomId)
          ?.getState(orexVoiceParticipantEventType, userId)
          ?.content,
      writeContent: (userId, content) => client.setRoomStateWithKey(
        matrixRoomId,
        orexVoiceParticipantEventType,
        userId,
        content,
      ),
    );
  }

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
  final OrexLiveKitCredentialsClient _credentialsClient;

  CallStatus status = CallStatus.connecting;
  String? error;
  String? cameraError; // камера не запустилась (звонок при этом идёт со звуком)
  lk.Room? _room;
  lk.Room? get room => _room;
  bool _disposed = false;
  final OrexScreenShareController _screenShare = OrexScreenShareController();
  late final OrexCameraDeviceController _camera = OrexCameraDeviceController(
    videoInputDeviceIdProvider: videoInputDeviceIdProvider,
    cameraDeviceIdSink: cameraDeviceIdSink,
  );
  late final OrexVoiceGateController _voiceGate = OrexVoiceGateController(
    participantProvider: () => _room?.localParticipant,
    canPublishMediaProvider: () => canPublishMedia,
    disposedProvider: () => _disposed,
    audioInputDeviceIdProvider: audioInputDeviceIdProvider,
    speakingThresholdDbProvider: speakingThresholdDbProvider,
    speakingThresholdEnabledProvider: speakingThresholdEnabledProvider,
  );
  bool get screenShareOn => _screenShare.isOn;
  bool handRaised = false;
  late final OrexVoiceStateRepository _voiceStates;
  Timer? _reactionClearTimer;
  Timer? _voiceStateRefreshTimer;
  Timer? _mediaRecoveryTimer;
  String? _lastAppliedInputDeviceId;
  bool speakerMuted = false;
  late bool _micRequestedOn;
  bool _systemMuted = false;
  bool _systemInactive = false;
  int _lastRemoteParticipantCount = 0;

  VoiceParticipantState voiceStateForUser(String userId) {
    return _voiceStates.stateForUser(userId);
  }

  VoiceParticipantState get localVoiceState => _voiceStates.localState;

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
      _applySpeakerMute();
      await applyAudioOutput();
      await _applyMicrophonePolicy(forceCaptureOptions: true);
      await _voiceGate.sync();
      if (video) {
        // Камера может быть недоступна (занята другим окном/приложением —
        // NotReadableError). Не валим весь звонок: продолжаем со звуком.
        try {
          await room.localParticipant?.setCameraEnabled(
            true,
            cameraCaptureOptions: _camera.captureOptions(),
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
        await _voiceGate.sync();
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
      } catch (e) {
        OrexLog.d('Call', 'voice revoke microphone disable failed', e);
      }
      await _voiceGate.stop(resetTrack: true);
      try {
        if (lp.isCameraEnabled()) {
          await lp.setCameraEnabled(false);
        }
      } catch (e) {
        OrexLog.d('Call', 'voice revoke camera disable failed', e);
      }
      if (screenShareOn) {
        try {
          await _stopScreenShare(lp: lp);
        } catch (e) {
          OrexLog.d('Call', 'voice revoke screen share stop failed', e);
        }
      }
    }

    if (nextCanUseMic && handRaised) {
      if (_voiceStates.hasLocalUser) {
        handRaised = false;
        _voiceStates.updateLocal((state) => state.copyWith(handRaised: false));
        await _publishVoiceParticipantState();
      }
    }

    if (nextCanUseMic) {
      await _applyMicrophonePolicy(forceCaptureOptions: true);
    }

    if (nextCanUseMic &&
        error == 'В режиме просмотра трансляция экрана недоступна') {
      error = null;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> toggleMic() async {
    if (_room?.localParticipant == null || !canPublishMedia) return;
    final next = !_micRequestedOn;
    _micRequestedOn = next;
    await _applyMicrophonePolicy(forceCaptureOptions: next);
    final sink = callMicPreferenceSink;
    if (sink != null) await sink(next);
    if (!_disposed) notifyListeners();
  }

  /// Системный mute (гарнитура, Android call UI) не меняет пользовательское
  /// предпочтение микрофона. После unmute восстанавливаем ровно то состояние,
  /// которое пользователь выбрал в Orex.
  Future<void> setSystemMuted(bool muted) async {
    if (_systemMuted == muted) return;
    _systemMuted = muted;
    await _applyMicrophonePolicy(forceCaptureOptions: !muted);
    if (!_disposed) notifyListeners();
  }

  /// Telecom может временно перевести VoIP-звонок в inactive/hold, например
  /// когда пользователь отвечает на SIM-вызов. На hold мы останавливаем и
  /// исходящий микрофон, и входящее аудио, но не разрываем LiveKit-сессию.
  Future<void> setSystemActive(bool active) async {
    final inactive = !active;
    if (_systemInactive == inactive) return;
    _systemInactive = inactive;
    await _applyMicrophonePolicy(forceCaptureOptions: active);
    _applySpeakerMute();
    if (!_disposed) notifyListeners();
  }

  Future<void> _applyMicrophonePolicy({bool forceCaptureOptions = false}) async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    final shouldPublish =
        canPublishMedia && _micRequestedOn && !_systemMuted && !_systemInactive;
    final currentlyEnabled = lp.isMicrophoneEnabled();
    if (currentlyEnabled == shouldPublish && !forceCaptureOptions) {
      await _voiceGate.sync();
      return;
    }

    if (!shouldPublish) {
      await lp.setMicrophoneEnabled(false);
      await _voiceGate.stop(resetTrack: true);
      return;
    }

    await lp.setMicrophoneEnabled(
      true,
      audioCaptureOptions: _audioCaptureOptions(),
    );
    await _voiceGate.sync();
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
    await _voiceGate.sync();
  }

  Future<void> _restartMicIfInputChanged({bool force = false}) async {
    final lp = _room?.localParticipant;
    if (lp == null || !lp.isMicrophoneEnabled() || !canPublishMedia) return;

    final nextInputId = _normalizedInputDeviceId();
    if (!force && nextInputId == _lastAppliedInputDeviceId) return;

    await _voiceGate.stop(resetTrack: true);
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
    await _voiceGate.sync();
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
      } catch (fallbackError) {
        OrexLog.d(
          'Call',
          'fallback audio output select failed id=$id',
          fallbackError,
        );
      }
    }
  }

  Future<void> syncVoiceGateFromSettings() => _voiceGate.sync();

  Future<void> toggleSpeakerMute() async {
    speakerMuted = !speakerMuted;
    _applySpeakerMute();
    await _publishSpeakerMuteState();
    if (!_disposed) notifyListeners();
  }

  Future<void> _publishSpeakerMuteState() async {
    if (!_voiceStates.updateLocal(
      (state) => state.copyWith(speakerMuted: speakerMuted),
    )) {
      return;
    }
    await _publishVoiceParticipantState();
  }

  void _applySpeakerMute() {
    final room = _room;
    if (room == null) return;
    final enabled = !speakerMuted && !_systemInactive;
    for (final participant in room.remoteParticipants.values) {
      OrexLiveKitTrackAccess.setParticipantAudioEnabled(participant, enabled);
    }
  }

  Future<void> toggleScreenShare({
    String? sourceId,
    String? sourceName,
    String? sourceType,
  }) async {
    final lp = _room?.localParticipant;
    if (lp == null || _screenShare.isBusy) return;
    final result = await _screenShare.toggle(
      participant: lp,
      canPublishMedia: canPublishMedia,
      sourceId: sourceId,
      sourceName: sourceName,
      sourceType: sourceType,
    );
    error = result.error;
    if (!_disposed) notifyListeners();
  }

  Future<void> _stopScreenShare({lk.LocalParticipant? lp}) async {
    await _screenShare.stop(participant: lp ?? _room?.localParticipant);
  }

  Future<void> toggleHandRaised({bool? force}) async {
    if (!_voiceStates.hasLocalUser) return;
    final next = force ?? !handRaised;
    if (handRaised == next) return;
    handRaised = next;
    _voiceStates.updateLocal((state) => state.copyWith(handRaised: next));
    await _publishVoiceParticipantState();
    if (!_disposed) notifyListeners();
  }

  Future<void> sendVoiceReaction(String emoji) async {
    if (!_voiceStates.hasLocalUser) return;
    _reactionClearTimer?.cancel();
    _voiceStates.updateLocal(
      (state) => state.copyWith(
        reaction: emoji,
        reactionTs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await _publishVoiceParticipantState();
    if (!_disposed) notifyListeners();
    _reactionClearTimer = Timer(const Duration(seconds: 4), () async {
      if (_disposed) return;
      _voiceStates.updateLocal((state) => state.copyWith(clearReaction: true));
      await _publishVoiceParticipantState();
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> _publishVoiceParticipantState() async {
    try {
      await _voiceStates.publishLocal();
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
        cameraCaptureOptions: next ? _camera.captureOptions() : null,
      );
      cameraError = null;
    } catch (e) {
      cameraError = '$e';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _restartCameraIfInputChanged({bool force = false}) async {
    _applyCameraResult(
      await _camera.restartIfInputChanged(
        participant: _room?.localParticipant,
        canPublishMedia: canPublishMedia,
        force: force,
      ),
    );
  }

  Future<void> selectCameraDevice(String? deviceId) async {
    _applyCameraResult(
      await _camera.selectDevice(
        participant: _room?.localParticipant,
        canPublishMedia: canPublishMedia,
        deviceId: deviceId,
      ),
    );
    if (!_disposed) notifyListeners();
  }

  Future<void> cycleCameraDevice(List<OrexAudioDevice> devices) async {
    _applyCameraResult(
      await _camera.cycleDevice(
        participant: _room?.localParticipant,
        canPublishMedia: canPublishMedia,
        devices: devices,
      ),
    );
    if (!_disposed) notifyListeners();
  }

  void _applyCameraResult(OrexCameraDeviceResult result) {
    if (!result.changed) return;
    cameraError = result.error;
  }

  Future<void> _clearLocalVoiceUiState() async {
    if (!_voiceStates.hasLocalUser) return;
    final state = localVoiceState;
    if (!handRaised &&
        !state.handRaised &&
        state.reaction == null &&
        !state.speakerMuted) {
      return;
    }
    handRaised = false;
    speakerMuted = false;
    _reactionClearTimer?.cancel();
    _reactionClearTimer = null;
    _voiceStates.updateLocal(
      (state) => state.copyWith(
        handRaised: false,
        speakerMuted: false,
        clearReaction: true,
      ),
    );
    try {
      await _publishVoiceParticipantState();
    } catch (e) {
      OrexLog.d('Call', 'clear local voice ui state failed', e);
    }
  }

  Future<void> hangUp() async {
    status = CallStatus.ended;
    await _clearLocalVoiceUiState();
    _voiceStateRefreshTimer?.cancel();
    _voiceStateRefreshTimer = null;
    _mediaRecoveryTimer?.cancel();
    _mediaRecoveryTimer = null;
    await _voiceGate.stop(resetTrack: true);
    final room = _room;
    _room = null;
    if (room != null) {
      // Снимаем слушатель ДО teardown, чтобы события закрытия не дёргали нас.
      room.removeListener(_onRoom);
      try {
        if (screenShareOn) {
          await _stopScreenShare(lp: room.localParticipant);
        }
      } catch (e) {
        OrexLog.d('Call', 'hangup screen share stop failed', e);
      }
      try {
        await room.disconnect();
      } catch (e) {
        OrexLog.d('Call', 'hangup room disconnect failed', e);
      }
      try {
        await room.dispose();
      } catch (e) {
        OrexLog.d('Call', 'hangup room dispose failed', e);
      }
    }
    if (orexIsAndroidNativePlatform) {
      try {
        await OrexNativeAudioDevices.selectOutput(null, inCall: false);
      } catch (e) {
        OrexLog.d('Call', 'hangup reset native audio route failed', e);
      }
    }
    if (!_disposed) notifyListeners();
  }

  // OpenID-токен Matrix -> lk-jwt-service /sfu/get -> {url, jwt}
  Future<OrexLiveKitCredentials> _fetchCredentials() {
    return _credentialsClient.fetch(
      client: client,
      matrixRoomId: matrixRoomId,
      canPublishMedia: canPublishMedia,
      listenOnly: listenOnly,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _reactionClearTimer?.cancel();
    _voiceStateRefreshTimer?.cancel();
    _mediaRecoveryTimer?.cancel();
    _voiceGate.dispose();
    unawaited(_screenShare.cleanupLocals());
    _room?.removeListener(_onRoom);
    _room?.dispose();
    _room = null;
    if (orexIsAndroidNativePlatform) {
      unawaited(OrexNativeAudioDevices.selectOutput(null, inCall: false));
    }
    super.dispose();
  }
}

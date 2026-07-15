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

@visibleForTesting
const orexMobileIceConnectionTimeout = Duration(seconds: 25);

// LiveKit defaults the primary ICE connection to 10 seconds. That is too
// aggressive for a mobile handoff that needs to obtain a TURN candidate, but
// remains bounded below by CallController's 30-second media-stage watchdog.
const _orexMobileConnectOptions = lk.ConnectOptions(
  timeouts: lk.Timeouts(
    connection: orexMobileIceConnectionTimeout,
    debounce: Duration(milliseconds: 20),
    publish: Duration(seconds: 10),
    subscribe: Duration(seconds: 10),
    peerConnection: orexMobileIceConnectionTimeout,
    iceRestart: orexMobileIceConnectionTimeout,
  ),
);

@visibleForTesting
bool orexShouldReconnectCallAfterBackground({
  required lk.ConnectionState? connectionState,
  required bool hasReachedMediaReady,
}) {
  return hasReachedMediaReady &&
      connectionState != lk.ConnectionState.connected;
}

@visibleForTesting
bool orexShouldRefreshPublishedMediaAfterBackground({
  required lk.ConnectionState? connectionState,
  required Duration backgroundDuration,
}) {
  return connectionState == lk.ConnectionState.connected &&
      backgroundDuration >= const Duration(milliseconds: 750);
}

@visibleForTesting
bool orexShouldEnsureCameraAfterBackground({
  required bool cameraRequestedOn,
  required bool cameraEnabled,
}) {
  // Never rebuild an already-enabled camera merely because a room/lifecycle
  // event fired. Replacing the published camera track itself emits another
  // room event, so doing that from generic recovery creates an on/off loop.
  return cameraRequestedOn && !cameraEnabled;
}

@visibleForTesting
Duration orexEncryptionKeyRetryDelay(int attempt) {
  const delays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
  ];
  final safeAttempt = attempt < 0 ? 0 : attempt;
  return delays[safeAttempt < delays.length ? safeAttempt : delays.length - 1];
}

@visibleForTesting
Future<void> orexWaitForMediaProviderRelease({
  required Future<void> mediaTeardown,
  required Future<void> Function() waitForPendingMediaOperations,
}) async {
  try {
    await mediaTeardown;
  } finally {
    // UI teardown is intentionally bounded, but a native key provider must
    // outlive every stale Room/connect operation that captured it.
    await waitForPendingMediaOperations();
  }
}

@visibleForTesting
bool orexShouldPlayRemoteReactionCue({
  required bool knownParticipant,
  required int? previousTs,
  required int? nextTs,
  required int baselineTs,
}) {
  if (nextTs == null) return false;
  if (!knownParticipant) return nextTs > baselineTs;
  return previousTs == null || nextTs > previousTs;
}

String _matrixUserIdFromParticipantIdentity(String identity) {
  final match = RegExp(r'@[^:]+:[^:]+').firstMatch(identity);
  return match?.group(0) ?? identity;
}

/// Нативный звонок на стеке Element Call (MatrixRTC): LiveKit +
/// lk-jwt-service используются под собственным Orex UI — без встраивания
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
    this.initialSpeakerMuted = false,
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
    this.e2eeKeyProvider,
    this.refreshE2eeKeys,
    this.attachE2eeRoom,
    this.detachE2eeRoom,
    this.adaptiveStream = true,
    this.remoteReactionCue,
    OrexLiveKitCredentialsClient? credentialsClient,
  }) : _credentialsClient =
           credentialsClient ?? const OrexLiveKitCredentialsClient() {
    _micRequestedOn = initialMicOn;
    speakerMuted = initialSpeakerMuted;
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
  final bool initialSpeakerMuted;
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
  final Future<lk.BaseKeyProvider>? e2eeKeyProvider;
  final Future<void> Function(
    int expectedRemoteParticipants,
    Set<String> forceRemoteParticipantIds,
  )?
  refreshE2eeKeys;
  final Future<void> Function(lk.Room room)? attachE2eeRoom;
  final void Function(lk.Room room)? detachE2eeRoom;
  final bool adaptiveStream;
  final FutureOr<void> Function()? remoteReactionCue;
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
  Timer? _reconnectTimer;
  Future<void>? _reconnectInFlight;
  final Set<Future<void>> _mediaConnectOperations = <Future<void>>{};
  final Set<Future<void>> _mediaRestoreOperations = <Future<void>>{};
  Future<void>? _hangUpOperation;
  Future<void>? _mediaOperationsDrainBarrier;
  int _connectGeneration = 0;
  Future<void>? _keyRefreshInFlight;
  Timer? _keyRefreshRetryTimer;
  int _keyRefreshRetryAttempt = 0;
  Future<void>? _backgroundRecoveryInFlight;
  Future<void>? _coldAnswerCameraRecoveryInFlight;
  Future<void>? _cameraToggleInFlight;
  bool _coldAnswerCameraRecoveryDone = false;
  lk.EventsListener<lk.RoomEvent>? _roomEvents;
  int _reconnectAttempt = 0;
  bool _cameraRequestedOn = false;
  String? _lastAppliedInputDeviceId;
  bool speakerMuted = false;
  Future<void> _speakerMuteApplyTail = Future<void>.value();
  late bool _micRequestedOn;
  bool _systemMuted = false;
  bool _systemInactive = false;
  bool _proximityEnabled = false;
  bool _readinessDeferred = false;
  bool _hasReachedMediaReady = false;
  int _lastRemoteParticipantCount = 0;
  int _remoteReactionBaselineMs = 0;
  final Map<String, int?> _lastRemoteReactionTs = <String, int?>{};
  final Map<String, Set<String>> _failedE2eeTracks = <String, Set<String>>{};

  VoiceParticipantState voiceStateForUser(String userId) {
    return _voiceStates.stateForUser(userId);
  }

  VoiceParticipantState get localVoiceState => _voiceStates.localState;

  /// Подключался ли хоть кто-то ещё (для итогового сообщения «ответили/пропущен»).
  bool sawRemote = false;
  int get remoteParticipantCount => _room?.remoteParticipants.length ?? 0;

  bool get micOn => _room?.localParticipant?.isMicrophoneEnabled() ?? false;
  bool get microphoneRequestedOn => canPublishMedia && _micRequestedOn;
  bool get camOn => _room?.localParticipant?.isCameraEnabled() ?? false;
  bool get cameraRequestedOn => _cameraRequestedOn;
  bool get canPublishMedia => canUseMic && !listenOnly;
  bool get mediaTransportConnected =>
      _room?.connectionState == lk.ConnectionState.connected;
  bool get hasReachedMediaReady => _hasReachedMediaReady;

  /// Once hang-up starts this is the full native Room teardown barrier, not
  /// merely a snapshot of connection futures. MatrixRTC must retain its E2EE
  /// provider until this future settles.
  Future<void> get mediaOperationsFullyDrained {
    final mediaTeardown = _hangUpOperation;
    if (mediaTeardown == null) return _waitForMediaOperationsToDrain();
    return _mediaOperationsDrainBarrier ??= orexWaitForMediaProviderRelease(
      mediaTeardown: mediaTeardown,
      waitForPendingMediaOperations: _waitForMediaOperationsToDrain,
    );
  }

  List<lk.Participant> get participants => [
    if (_room?.localParticipant != null) _room!.localParticipant!,
    ...?_room?.remoteParticipants.values,
  ];

  Future<void> connect({required bool video, bool deferReady = false}) async {
    _cameraRequestedOn = video;
    _readinessDeferred = deferReady;
    _cancelReconnect();
    status = CallStatus.connecting;
    error = null;
    notifyListeners();
    try {
      await _startFreshRoomConnection(completeReadiness: !deferReady);
    } catch (e) {
      if (_disposed || status == CallStatus.ended) return;
      OrexLog.d('Call', 'secure media connect failed room=$matrixRoomId', e);
      error = 'Не удалось подключиться к защищённому звонку';
      status = CallStatus.failed;
      await _syncProximitySensor(forceOff: true);
      notifyListeners();
    }
  }

  bool _isCurrentConnection(int generation) =>
      !_disposed &&
      status != CallStatus.ended &&
      generation == _connectGeneration;

  Future<void> _startFreshRoomConnection({bool completeReadiness = true}) {
    final generation = ++_connectGeneration;
    late final Future<void> operation;
    operation = _connectFreshRoom(
      generation: generation,
      completeReadiness: completeReadiness,
    ).whenComplete(() => _mediaConnectOperations.remove(operation));
    _mediaConnectOperations.add(operation);
    return operation;
  }

  Future<void> _connectFreshRoom({
    required int generation,
    bool completeReadiness = true,
  }) async {
    final creds = await _fetchCredentials();
    if (!_isCurrentConnection(generation)) return;
    final providerFuture = e2eeKeyProvider;
    if (providerFuture == null) {
      throw StateError('Media E2EE key provider is unavailable');
    }
    final provider = await providerFuture;
    if (!_isCurrentConnection(generation)) return;
    final candidate = lk.Room(
      roomOptions: lk.RoomOptions(
        adaptiveStream: adaptiveStream,
        dynacast: adaptiveStream,
        encryption: lk.E2EEOptions(keyProvider: provider),
      ),
    );

    try {
      await candidate.prepareConnection(creds.url, creds.jwt);
      if (!_isCurrentConnection(generation)) {
        await _disposeRoom(candidate);
        return;
      }
      await candidate.connect(
        creds.url,
        creds.jwt,
        connectOptions: _orexMobileConnectOptions,
      );
      if (!_isCurrentConnection(generation)) {
        await _disposeRoom(candidate);
        return;
      }

      if (!await _adoptRoom(candidate, generation: generation)) return;
      // Matrix key delivery is a second, eventually-consistent control plane.
      // A temporary /sync/DNS failure must not destroy a LiveKit transport that
      // is already connected. The key provider still drops encrypted frames
      // until the matching keys arrive, so this is fail-closed, not plaintext.
      await _refreshRemoteEncryptionKeysBestEffort();
      if (!_isCurrentConnection(generation) || !identical(_room, candidate)) {
        return;
      }
      await _restoreMediaState(
        expectedRoom: candidate,
        connectGeneration: generation,
      );
      if (!_isCurrentConnection(generation) || !identical(_room, candidate)) {
        return;
      }

      _startVoiceStateRefresh();
      _cancelReconnect();
      error = null;
      if (completeReadiness) {
        await markReady();
      } else {
        await _syncProximitySensor(forceOff: true);
        notifyListeners();
      }
    } catch (_) {
      if (!identical(_room, candidate)) {
        await _disposeRoom(candidate);
      } else {
        await _detachAndDisposeCurrentRoom(candidate);
      }
      rethrow;
    }
  }

  Future<bool> _adoptRoom(lk.Room room, {required int generation}) async {
    if (!_isCurrentConnection(generation)) {
      await _disposeRoom(room);
      return false;
    }
    final previous = _room;
    if (identical(previous, room)) return true;

    if (previous != null) {
      detachE2eeRoom?.call(previous);
      previous.removeListener(_onRoom);
      await _disposeRoomEvents();
      await _voiceGate.stop(resetTrack: true);
      if (!_isCurrentConnection(generation)) {
        await _disposeRoom(room);
        return false;
      }
    }

    _room = room;
    _failedE2eeTracks.clear();
    _cancelEncryptionKeyRefreshRetry();
    _remoteReactionBaselineMs = DateTime.now().millisecondsSinceEpoch;
    _lastRemoteReactionTs.clear();
    _lastRemoteParticipantCount = room.remoteParticipants.length;
    if (_lastRemoteParticipantCount > 0) sawRemote = true;
    room.addListener(_onRoom);
    _bindRoomEvents(room);
    try {
      await attachE2eeRoom?.call(room);
    } finally {
      // Even an E2EE-provider attachment failure must not leak the replaced
      // PeerConnection. The outer connect rollback will dispose [room].
      if (previous != null) await _disposeRoom(previous);
    }
    if (!_isCurrentConnection(generation) || !identical(_room, room)) {
      if (identical(_room, room)) {
        await _detachAndDisposeCurrentRoom(room);
      }
      return false;
    }
    return true;
  }

  void _bindRoomEvents(lk.Room room) {
    final listener = room.createListener()
      ..on<lk.RoomReconnectingEvent>((_) {
        if (_disposed || !identical(_room, room)) return;
        _markMediaReconnecting();
      })
      ..on<lk.RoomReconnectedEvent>((_) {
        if (_disposed || !identical(_room, room)) return;
        unawaited(_handleSdkReconnected(room));
      })
      ..on<lk.RoomDisconnectedEvent>((_) {
        if (_disposed || !identical(_room, room)) return;
        _handleTerminalRoomDisconnect(room);
      })
      ..on<lk.TrackE2EEStateEvent>((event) {
        if (_disposed || !identical(_room, room)) return;
        _handleTrackE2eeState(event);
      });
    _roomEvents = listener;
  }

  void _markMediaReconnecting() {
    if (_disposed || status == CallStatus.ended) return;
    status = CallStatus.connecting;
    error = null;
    unawaited(_syncProximitySensor(forceOff: true));
    notifyListeners();
  }

  Future<void> _handleSdkReconnected(lk.Room room) async {
    if (_disposed || status == CallStatus.ended || !identical(_room, room)) {
      return;
    }
    try {
      await _refreshRemoteEncryptionKeysBestEffort();
      await _restoreMediaState(expectedRoom: room);
      if (_disposed || !identical(_room, room)) return;
      _cancelReconnect();
      error = null;
      if (_readinessDeferred) {
        status = CallStatus.connecting;
        await _syncProximitySensor(forceOff: true);
        notifyListeners();
      } else {
        await markReady();
      }
    } catch (e) {
      OrexLog.d('Call', 'media restore after SDK reconnect failed', e);
      _handleTerminalRoomDisconnect(room);
    }
  }

  void _handleTerminalRoomDisconnect(lk.Room room) {
    if (_disposed || status == CallStatus.ended || !identical(_room, room)) {
      return;
    }
    OrexLog.d('Call', 'terminal media disconnect room=$matrixRoomId');
    _markMediaReconnecting();
    _scheduleFullReconnect();
  }

  void _scheduleFullReconnect() {
    if (_disposed || status == CallStatus.ended || _reconnectTimer != null) {
      return;
    }
    const delays = <Duration>[
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 15),
    ];
    final index = _reconnectAttempt < delays.length
        ? _reconnectAttempt
        : delays.length - 1;
    final delay = delays[index];
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_attemptFullReconnect());
    });
  }

  Future<void> _attemptFullReconnect() {
    final inFlight = _reconnectInFlight;
    if (inFlight != null) return inFlight;
    if (_disposed || status == CallStatus.ended) return Future<void>.value();

    late final Future<void> operation;
    operation = _startFreshRoomConnection()
        .catchError((Object error, StackTrace stack) {
          if (_disposed || status == CallStatus.ended) return;
          OrexLog.d(
            'Call',
            'full media reconnect failed room=$matrixRoomId',
            error,
          );
          status = CallStatus.connecting;
          this.error = 'Восстанавливаем соединение…';
          notifyListeners();
          _scheduleFullReconnect();
        })
        .whenComplete(() {
          if (identical(_reconnectInFlight, operation)) {
            _reconnectInFlight = null;
          }
        });
    _reconnectInFlight = operation;
    return operation;
  }

  Future<void> recoverAfterBackground(Duration backgroundDuration) async {
    if (_disposed || status == CallStatus.ended) return;

    final connectionState = _room?.connectionState;
    if (orexShouldReconnectCallAfterBackground(
      connectionState: connectionState,
      hasReachedMediaReady: _hasReachedMediaReady,
    )) {
      OrexLog.d(
        'Call',
        'reconnecting media after background room=$matrixRoomId '
            'duration=${backgroundDuration.inSeconds}s state=$connectionState',
      );
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _markMediaReconnecting();
      await _attemptFullReconnect();
      return;
    }

    if (!orexShouldRefreshPublishedMediaAfterBackground(
      connectionState: connectionState,
      backgroundDuration: backgroundDuration,
    )) {
      return;
    }
    await _recoverConnectedMediaAfterBackground(backgroundDuration);
  }

  Future<void> _recoverConnectedMediaAfterBackground(
    Duration backgroundDuration,
  ) {
    final inFlight = _backgroundRecoveryInFlight;
    if (inFlight != null) return inFlight;

    late final Future<void> operation;
    operation =
        (() async {
              OrexLog.d(
                'Call',
                'rebuilding published media after background room=$matrixRoomId '
                    'duration=${backgroundDuration.inSeconds}s',
              );
              await _refreshRemoteEncryptionKeysBestEffort();
              if (_disposed ||
                  status == CallStatus.ended ||
                  !mediaTransportConnected) {
                return;
              }
              await applyAudioOutput();
              await _restartMicIfInputChanged(force: true);
              final participant = _room?.localParticipant;
              if (participant != null &&
                  canPublishMedia &&
                  orexShouldEnsureCameraAfterBackground(
                    cameraRequestedOn: _cameraRequestedOn,
                    cameraEnabled: participant.isCameraEnabled(),
                  )) {
                // A lifecycle resume may leave a requested camera disabled, but an
                // already-enabled publication must be left untouched. Rebuilding it on
                // every resume/room event causes the camera-open/camera-close loop seen
                // on Android and replaceTrack() against a closed peer on web.
                try {
                  await participant.setCameraEnabled(
                    true,
                    cameraCaptureOptions: _camera.captureOptions(),
                  );
                  cameraError = null;
                } catch (e) {
                  OrexLog.d(
                    'Call',
                    'camera resume failed room=$matrixRoomId',
                    e,
                  );
                  cameraError = 'Камера недоступна';
                }
              }
              await _voiceGate.sync();
              await _applySpeakerMute();
              if (!_disposed) notifyListeners();
            })()
            .catchError((Object error, StackTrace stackTrace) {
              OrexLog.d(
                'Call',
                'published media recovery after background failed room=$matrixRoomId',
                error,
              );
            })
            .whenComplete(() {
              if (identical(_backgroundRecoveryInFlight, operation)) {
                _backgroundRecoveryInFlight = null;
              }
            });
    _backgroundRecoveryInFlight = operation;
    return operation;
  }

  /// Incoming video calls can be answered while Android is launching the app
  /// from a notification. The initial LiveKit sender may be connected before
  /// foreground camera access is usable, so rebuild it once the call UI/media
  /// session is ready and after MatrixRTC keys have settled.
  Future<void> recoverCameraAfterColdAnswer() {
    if (_disposed ||
        status == CallStatus.ended ||
        !_cameraRequestedOn ||
        !canPublishMedia ||
        _coldAnswerCameraRecoveryDone) {
      return Future<void>.value();
    }
    final inFlight = _coldAnswerCameraRecoveryInFlight;
    if (inFlight != null) return inFlight;

    late final Future<void> operation;
    operation =
        (() async {
          try {
            await _refreshRemoteEncryptionKeysBestEffort();
            await Future<void>.delayed(const Duration(milliseconds: 350));
            if (_disposed ||
                status == CallStatus.ended ||
                !mediaTransportConnected ||
                !_cameraRequestedOn) {
              return;
            }
            final result = await _camera.recoverCapture(
              participant: _room?.localParticipant,
              canPublishMedia: canPublishMedia,
            );
            _applyCameraResult(result);
            if (result.error == null) _coldAnswerCameraRecoveryDone = true;
            if (!_disposed) notifyListeners();
          } catch (e) {
            OrexLog.d(
              'Call',
              'cold-answer camera recovery failed room=$matrixRoomId',
              e,
            );
            cameraError = 'Камера недоступна';
            if (!_disposed) notifyListeners();
          }
        })().whenComplete(() {
          if (identical(_coldAnswerCameraRecoveryInFlight, operation)) {
            _coldAnswerCameraRecoveryInFlight = null;
          }
        });
    _coldAnswerCameraRecoveryInFlight = operation;
    return operation;
  }

  Future<void> _restoreMediaState({
    lk.Room? expectedRoom,
    int? connectGeneration,
  }) {
    late final Future<void> operation;
    operation = _restoreMediaStateInternal(
      expectedRoom: expectedRoom,
      connectGeneration: connectGeneration,
    ).whenComplete(() => _mediaRestoreOperations.remove(operation));
    _mediaRestoreOperations.add(operation);
    return operation;
  }

  Future<void> _restoreMediaStateInternal({
    lk.Room? expectedRoom,
    int? connectGeneration,
  }) async {
    final room = expectedRoom ?? _room;
    if (room == null) return;
    bool isCurrent() =>
        !_disposed &&
        status != CallStatus.ended &&
        identical(_room, room) &&
        (connectGeneration == null || connectGeneration == _connectGeneration);
    if (!isCurrent()) return;
    await _applySpeakerMute();
    await applyAudioOutput();
    if (!isCurrent()) return;
    await _applyMicrophonePolicy(forceCaptureOptions: true);
    if (!isCurrent()) return;
    await _voiceGate.sync();
    if (!isCurrent()) return;

    if (_cameraRequestedOn && canPublishMedia) {
      try {
        await room.localParticipant?.setCameraEnabled(
          true,
          cameraCaptureOptions: _camera.captureOptions(),
        );
        cameraError = null;
      } catch (e) {
        OrexLog.d('Call', 'camera restore failed room=$matrixRoomId', e);
        cameraError = 'Камера недоступна';
      }
    }
    if (!isCurrent()) return;
    await _applySpeakerMute();
  }

  Future<void> _disposeRoomEvents() async {
    final events = _roomEvents;
    _roomEvents = null;
    if (events == null) return;
    try {
      await events.dispose();
    } catch (e) {
      OrexLog.d('Call', 'room event listener dispose failed', e);
    }
  }

  Future<void> _disposeRoom(lk.Room room) async {
    try {
      await room.disconnect();
    } catch (e) {
      OrexLog.d('Call', 'room disconnect during cleanup failed', e);
    }
    try {
      await room.dispose();
    } catch (e) {
      OrexLog.d('Call', 'room dispose during cleanup failed', e);
    }
  }

  Future<void> _detachAndDisposeCurrentRoom(lk.Room room) async {
    if (!identical(_room, room)) return;
    detachE2eeRoom?.call(room);
    room.removeListener(_onRoom);
    await _disposeRoomEvents();
    _room = null;
    await _disposeRoom(room);
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
  }

  Future<void> _drainMediaOperations() async {
    try {
      await _waitForMediaOperationsToDrain().timeout(
        const Duration(seconds: 5),
      );
    } on TimeoutException {
      // Generation checks still own eventual candidate cleanup. Never hold the
      // user's hang-up UI indefinitely on a stuck network/plugin future.
      OrexLog.d('Call', 'timed out draining media connection operations');
    }
  }

  Future<void> _waitForMediaOperationsToDrain() async {
    while (true) {
      final operations = <Future<void>>{
        ..._mediaConnectOperations,
        ..._mediaRestoreOperations,
      };
      if (operations.isEmpty) return;
      await Future.wait<void>(
        operations.map(
          (operation) => operation.catchError((Object _, StackTrace _) {}),
        ),
      );
    }
  }

  void _onRoom() {
    // Livekit при teardown комнаты шлёт события уже после dispose() — иначе
    // получаем «CallSession used after being disposed».
    if (_disposed) return;
    final remoteCount = _room?.remoteParticipants.length ?? 0;
    final previousRemoteCount = _lastRemoteParticipantCount;
    final remoteCountChanged = remoteCount != previousRemoteCount;
    _lastRemoteParticipantCount = remoteCount;
    if (remoteCount > 0) sawRemote = true;
    // Joins need the existing sender key; leaves may rotate it for every
    // remaining device. Reconcile both transitions against key revision.
    if (remoteCountChanged) {
      _queueRemoteEncryptionKeyRefresh();
    }
    unawaited(_applySpeakerMute());
    _scheduleMediaRecovery();
    notifyListeners();
  }

  void _handleTrackE2eeState(lk.TrackE2EEStateEvent event) {
    if (event.participant is lk.LocalParticipant) return;
    final participantId = event.participant.identity;
    final trackId = event.publication.sid;
    switch (event.state) {
      case lk.E2EEState.kMissingKey:
      case lk.E2EEState.kDecryptionFailed:
        final added = (_failedE2eeTracks[participantId] ??= <String>{}).add(
          trackId,
        );
        if (added) _keyRefreshRetryAttempt = 0;
        if (_keyRefreshInFlight == null && _keyRefreshRetryTimer == null) {
          _queueRemoteEncryptionKeyRefresh();
        }
        break;
      case lk.E2EEState.kOk:
      case lk.E2EEState.kKeyRatcheted:
        final tracks = _failedE2eeTracks[participantId];
        tracks?.remove(trackId);
        if (tracks?.isEmpty ?? false) _failedE2eeTracks.remove(participantId);
        if (_failedE2eeTracks.isEmpty) _cancelEncryptionKeyRefreshRetry();
        break;
      case lk.E2EEState.kNew:
      case lk.E2EEState.kEncryptionFailed:
      case lk.E2EEState.kInternalError:
        break;
    }
  }

  void _scheduleMediaRecovery() {
    _mediaRecoveryTimer?.cancel();
    _mediaRecoveryTimer = Timer(const Duration(milliseconds: 450), () async {
      if (_disposed || status != CallStatus.connected) return;
      try {
        await applyAudioOutput();
        await _restartMicIfInputChanged();
        // Camera publication changes are themselves RoomEvents. Restarting the
        // camera here creates a feedback loop: publish -> event -> restart ->
        // event -> restart. Device changes are handled only by explicit camera
        // selection/cycle actions and the one-shot cold-answer recovery.
        await _voiceGate.sync();
        await _applySpeakerMute();
      } catch (e) {
        OrexLog.d('Call', 'media recovery failed', e);
      }
    });
  }

  Future<void> _refreshRemoteEncryptionKeys() {
    final refresh = refreshE2eeKeys;
    if (refresh == null || _disposed || status == CallStatus.ended) {
      return Future<void>.value();
    }

    final previous = _keyRefreshInFlight;
    late final Future<void> operation;
    operation =
        (() async {
          if (previous != null) {
            try {
              await previous;
            } catch (_) {
              // A later participant-count request must still run after an earlier
              // failed request; each caller observes the failure of its own refresh.
            }
          }
          if (_disposed || status == CallStatus.ended) return;
          final activeRemoteIds =
              _room?.remoteParticipants.values
                  .map((participant) => participant.identity)
                  .toSet() ??
              const <String>{};
          _failedE2eeTracks.removeWhere(
            (participantId, _) => !activeRemoteIds.contains(participantId),
          );
          await refresh(activeRemoteIds.length, _failedE2eeTracks.keys.toSet());
        })().whenComplete(() {
          if (identical(_keyRefreshInFlight, operation)) {
            _keyRefreshInFlight = null;
          }
        });
    _keyRefreshInFlight = operation;
    return operation;
  }

  Future<bool> _refreshRemoteEncryptionKeysBestEffort({
    bool scheduleRetry = true,
  }) async {
    try {
      await _refreshRemoteEncryptionKeys();
      if (_failedE2eeTracks.isEmpty) {
        _cancelEncryptionKeyRefreshRetry();
      } else {
        // A successful key request is not the terminal signal. Keep a bounded
        // backoff running until LiveKit reports kOk for every failed track.
        _scheduleEncryptionKeyRefreshRetry();
      }
      return true;
    } catch (error) {
      OrexLog.d(
        'Call',
        'remote media key refresh deferred room=$matrixRoomId',
        error,
      );
      if (scheduleRetry) _scheduleEncryptionKeyRefreshRetry();
      return false;
    }
  }

  void _queueRemoteEncryptionKeyRefresh() {
    unawaited(_refreshRemoteEncryptionKeysBestEffort());
  }

  void _scheduleEncryptionKeyRefreshRetry() {
    if (_disposed ||
        status == CallStatus.ended ||
        _keyRefreshRetryTimer != null ||
        _keyRefreshRetryAttempt >= 6) {
      return;
    }
    final delay = orexEncryptionKeyRetryDelay(_keyRefreshRetryAttempt);
    _keyRefreshRetryAttempt++;
    _keyRefreshRetryTimer = Timer(delay, () {
      _keyRefreshRetryTimer = null;
      if (_disposed || status == CallStatus.ended) return;
      unawaited(_refreshRemoteEncryptionKeysBestEffort());
    });
  }

  void _cancelEncryptionKeyRefreshRetry({bool resetAttempt = true}) {
    _keyRefreshRetryTimer?.cancel();
    _keyRefreshRetryTimer = null;
    if (resetAttempt) _keyRefreshRetryAttempt = 0;
  }

  Future<bool> markReady() async {
    if (_disposed || status == CallStatus.ended) return false;
    if (!mediaTransportConnected) {
      _markMediaReconnecting();
      return false;
    }
    _readinessDeferred = false;
    error = null;
    status = CallStatus.connected;
    _hasReachedMediaReady = true;
    await _syncProximitySensor();
    notifyListeners();
    return true;
  }

  void _startVoiceStateRefresh() {
    _voiceStateRefreshTimer?.cancel();
    _voiceStateRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_disposed || status != CallStatus.connected) return;
      final connectionState = _room?.connectionState;
      if (connectionState != lk.ConnectionState.connected) {
        OrexLog.d(
          'Call',
          'media health check detected stale room=$matrixRoomId '
              'state=$connectionState',
        );
        _markMediaReconnecting();
        _scheduleFullReconnect();
        return;
      }
      // Voice participant state comes from Matrix room state, not LiveKit
      // media events. Poll lightly so remote hands/reactions appear in the
      // call UI without writing them to the chat timeline. Permission changes
      // are checked here too, so admins can accept a raised-hand request while
      // the listener stays in the current channel call.
      unawaited(refreshVoicePermissions());
      _detectRemoteReactions();
      notifyListeners();
    });
  }

  void _detectRemoteReactions() {
    final room = _room;
    if (room == null) return;

    final activeUsers = <String>{};
    for (final participant in room.remoteParticipants.values) {
      final userId = _matrixUserIdFromParticipantIdentity(participant.identity);
      activeUsers.add(userId);
      final nextTs = _voiceStates.stateForUser(userId).reactionTs;
      final knownParticipant = _lastRemoteReactionTs.containsKey(userId);
      final previousTs = _lastRemoteReactionTs[userId];

      if (orexShouldPlayRemoteReactionCue(
        knownParticipant: knownParticipant,
        previousTs: previousTs,
        nextTs: nextTs,
        baselineTs: _remoteReactionBaselineMs,
      )) {
        unawaited(_playRemoteReactionCue());
      }
      if (nextTs != null || !knownParticipant) {
        _lastRemoteReactionTs[userId] = nextTs;
      }
    }
    _lastRemoteReactionTs.removeWhere(
      (userId, _) => !activeUsers.contains(userId),
    );
  }

  Future<void> _playRemoteReactionCue() async {
    final cue = remoteReactionCue;
    if (cue == null || _disposed) return;
    try {
      await cue();
    } catch (e) {
      OrexLog.d('Call', 'remote reaction cue failed room=$matrixRoomId', e);
    }
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
        _cameraRequestedOn = false;
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
    await _applySpeakerMute();
    if (!_disposed) notifyListeners();
  }

  Future<void> _applyMicrophonePolicy({
    bool forceCaptureOptions = false,
  }) async {
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

  Future<void> syncAudioSettingsFromSettings({
    bool refreshVoiceGateCapture = true,
  }) async {
    await applyAudioOutput();
    await _restartMicIfInputChanged();
    await _restartCameraIfInputChanged();
    if (refreshVoiceGateCapture) {
      await _voiceGate.restart(resetTrack: false);
    } else {
      await _voiceGate.sync();
    }
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
      OrexLog.d('Call', 'microphone recovery failed room=$matrixRoomId', e);
      error = 'Не удалось восстановить микрофон';
    }
    await _voiceGate.sync();
  }

  Future<void> applyAudioOutput() async {
    final id = audioOutputDeviceIdProvider?.call()?.trim();

    if (orexIsMobileNativePlatform) {
      await OrexNativeAudioDevices.selectOutput(id, inCall: true);
      await _syncProximitySensor();
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

  Future<void> _syncProximitySensor({bool forceOff = false}) async {
    if (!orexIsAndroidNativePlatform) return;
    final outputId = audioOutputDeviceIdProvider?.call()?.trim();
    final shouldEnable =
        !forceOff &&
        !_disposed &&
        status == CallStatus.connected &&
        !camOn &&
        orexIsAndroidEarpieceOutputDeviceId(outputId);
    if (!forceOff && shouldEnable == _proximityEnabled) return;

    final applied = await OrexNativeAudioDevices.setProximityEnabled(
      shouldEnable,
    );
    _proximityEnabled = shouldEnable && applied;
  }

  Future<void> syncVoiceGateFromSettings() => _voiceGate.sync();

  Future<void> toggleSpeakerMute() async {
    speakerMuted = !speakerMuted;
    if (!_disposed) notifyListeners();
    await _applySpeakerMute();
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

  Future<void> _applySpeakerMute() {
    final previous = _speakerMuteApplyTail;
    late final Future<void> operation;
    operation = (() async {
      try {
        await previous;
      } catch (_) {
        // A later user/system audio decision must still be applied.
      }
      if (_disposed) return;
      final room = _room;
      if (room == null) return;
      final enabled = !speakerMuted && !_systemInactive;
      for (final participant in room.remoteParticipants.values) {
        await OrexLiveKitTrackAccess.setParticipantAudioEnabled(
          participant,
          enabled,
        );
      }
    })();
    _speakerMuteApplyTail = operation;
    return operation;
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
      OrexLog.d('Call', 'voice participant state publish failed', e);
      error = 'Не удалось обновить состояние голосового канала';
      // Voice participant state is UX-only; failed state publish must not break
      // the media session.
    }
  }

  Future<void> toggleCam() {
    final current = _cameraToggleInFlight;
    if (current != null) return current;

    late final Future<void> operation;
    operation =
        (() async {
          final lp = _room?.localParticipant;
          if (lp == null || _disposed || status == CallStatus.ended) return;
          if (!canPublishMedia) {
            cameraError = 'В режиме просмотра камера недоступна';
            if (!_disposed) notifyListeners();
            return;
          }
          final previousRequested = _cameraRequestedOn;
          final next = !lp.isCameraEnabled();
          // Publish intent before awaiting WebRTC so lifecycle/room callbacks cannot
          // infer the opposite state while replaceTrack is still in flight.
          _cameraRequestedOn = next;
          try {
            await lp.setCameraEnabled(
              next,
              cameraCaptureOptions: next ? _camera.captureOptions() : null,
            );
            cameraError = null;
            if (next) _coldAnswerCameraRecoveryDone = true;
          } catch (e) {
            _cameraRequestedOn = previousRequested;
            OrexLog.d('Call', 'camera toggle failed room=$matrixRoomId', e);
            cameraError = 'Камера недоступна';
          }
          await _syncProximitySensor();
          if (!_disposed) notifyListeners();
        })().whenComplete(() {
          if (identical(_cameraToggleInFlight, operation)) {
            _cameraToggleInFlight = null;
          }
        });
    _cameraToggleInFlight = operation;
    return operation;
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

  Future<void> selectCameraDevice(
    String? deviceId, {
    String? deviceCategory,
  }) async {
    _applyCameraResult(
      await _camera.selectDevice(
        participant: _room?.localParticipant,
        canPublishMedia: canPublishMedia,
        deviceId: deviceId,
        deviceCategory: deviceCategory,
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

  Future<void> hangUp() => _hangUpOperation ??= _hangUpInternal();

  Future<void> _hangUpInternal() async {
    status = CallStatus.ended;
    _connectGeneration++;
    _cancelReconnect();
    await _drainMediaOperations();
    try {
      await _clearLocalVoiceUiState();
    } catch (e) {
      OrexLog.d('Call', 'hangup voice state cleanup failed', e);
    }
    _cancelEncryptionKeyRefreshRetry();
    _failedE2eeTracks.clear();
    _voiceStateRefreshTimer?.cancel();
    _voiceStateRefreshTimer = null;
    _mediaRecoveryTimer?.cancel();
    _mediaRecoveryTimer = null;
    try {
      await _voiceGate.stop(resetTrack: true);
    } catch (e) {
      OrexLog.d('Call', 'hangup voice gate cleanup failed', e);
    }
    final room = _room;
    _room = null;
    if (room != null) {
      // Снимаем listeners ДО teardown, чтобы clientInitiated disconnect не
      // запускал reconnect уже завершённого звонка.
      room.removeListener(_onRoom);
      detachE2eeRoom?.call(room);
      await _disposeRoomEvents();
      try {
        if (screenShareOn) {
          await _stopScreenShare(lp: room.localParticipant);
        }
      } catch (e) {
        OrexLog.d('Call', 'hangup screen share stop failed', e);
      }
      await _disposeRoom(room);
    }
    if (orexIsAndroidNativePlatform) {
      try {
        await _syncProximitySensor(forceOff: true);
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
    if (_disposed) return;
    _disposed = true;
    _connectGeneration++;
    _reactionClearTimer?.cancel();
    _cancelReconnect();
    _cancelEncryptionKeyRefreshRetry();
    _failedE2eeTracks.clear();
    _voiceStateRefreshTimer?.cancel();
    _mediaRecoveryTimer?.cancel();
    _voiceGate.dispose();
    unawaited(_screenShare.cleanupLocals());
    final room = _room;
    if (room != null) detachE2eeRoom?.call(room);
    room?.removeListener(_onRoom);
    unawaited(_disposeRoomEvents());
    if (room != null) unawaited(_disposeRoom(room));
    _room = null;
    if (orexIsAndroidNativePlatform) {
      unawaited(OrexNativeAudioDevices.setProximityEnabled(false));
      unawaited(OrexNativeAudioDevices.selectOutput(null, inCall: false));
    }
    super.dispose();
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
// Matrix SDK exports its own VoIP CallSession. Orex intentionally owns a
// separate media-session type below, so keep the SDK symbol out of this file.
import 'package:matrix/matrix.dart' hide CallSession;

import '../audio/audio_device_utils.dart';
import 'call_lifecycle_policy.dart';
import 'call_session.dart';
import 'call_start_watchdog.dart';
import 'system_call_integration.dart';
import 'voip_service.dart';
import '../matrix/matrix_service.dart';
import '../logging/orex_logger.dart';

export 'call_lifecycle_policy.dart';

enum OrexCallSetupPhase {
  idle,
  preparing,
  signaling,
  systemIntegration,
  media,
  ready,
}

/// Долгоживущий «активный звонок»: владеет медиа-сессией ([CallSession]) и
/// сигналингом ([VoipService]), чтобы звонок переживал сворачивание экрана.
///
/// Раньше [CallSession] жил внутри экрана звонка и умирал при выходе. Теперь
/// экран — лишь «вид» на этот контроллер: свернуть = выйти с экрана, не вешая
/// трубку; над чатом показывается мини-панель управления.
class CallController extends ChangeNotifier {
  CallController(this.matrix) {
    matrix.audio.addListener(_onAudioSettingsChanged);
    _systemCalls.setActionHandler(this, _onSystemCallAction);
    _incomingDismissSub = matrix.voip?.onDismissIncoming.listen(
      _onIncomingDismissed,
    );
    _remoteAcceptedSub = matrix.voip?.onRemoteCallAccepted.listen(
      _onRemoteCallAccepted,
    );
    _remoteTerminationSub = matrix.voip?.onRemoteCallTermination.listen(
      _onRemoteCallTermination,
    );
    _instancePromotionSub = matrix.voip?.onCallInstancePromotion.listen(
      _onCallInstancePromotion,
    );
  }

  final MatrixService matrix;
  final OrexSystemCallIntegration _systemCalls =
      OrexSystemCallIntegration.instance;
  StreamSubscription<OrexIncomingCallDismissal>? _incomingDismissSub;
  StreamSubscription<OrexRemoteCallAccepted>? _remoteAcceptedSub;
  StreamSubscription<OrexRemoteCallTermination>? _remoteTerminationSub;
  StreamSubscription<OrexCallInstancePromotion>? _instancePromotionSub;
  final StreamController<OrexCallInstance> _systemIncomingAccepted =
      StreamController<OrexCallInstance>.broadcast();
  OrexCallInstance? _pendingAcceptedIncomingCallUi;

  /// Requests the expanded mobile call route as soon as an accepted call has a
  /// local session. The session may still be connecting.
  Stream<OrexCallInstance> get onAcceptedIncomingCallUiRequested =>
      _systemIncomingAccepted.stream;

  /// Replays an accepted-call route request that was emitted while Flutter's
  /// root navigator was still bootstrapping after a cold notification answer.
  OrexCallInstance? takePendingAcceptedIncomingCallUiRequest() {
    final instance = _pendingAcceptedIncomingCallUi;
    _pendingAcceptedIncomingCallUi = null;
    return instance;
  }

  void _requestAcceptedIncomingCallUi(OrexCallInstance instance) {
    if (_disposed) return;
    if (!_isCurrentControllerInstance(instance)) return;
    _pendingAcceptedIncomingCallUi = instance;
    _systemIncomingAccepted.add(instance);
  }

  void _onAudioSettingsChanged() {
    if (_disposed) return;
    unawaited(
      _session?.syncAudioSettingsFromSettings(refreshVoiceGateCapture: true),
    );
    notifyListeners();
  }

  void _onSessionChanged() {
    if (_disposed) return;
    final session = _session;
    final rid = roomId;
    _callAnswered = orexNextAnsweredState(
      alreadyAnswered: _callAnswered,
      answerAccepted: false,
      mediaConnected: session?.status == CallStatus.connected,
    );
    if (_initiator && session?.sawRemote == true && rid != null) {
      _cancelUnansweredTimeout();
      // Media presence is an independent acceptance signal. If the explicit
      // accepted to-device event was delayed/lost, still stop the same user's
      // other devices from ringing. The ring token is consumed only once.
      final instance = currentCallInstance;
      if (instance != null) {
        unawaited(matrix.voip?.cancelOutstandingRing(instance));
      }
    }
    unawaited(_syncSystemCallControls());
    unawaited(_syncForegroundCall());
    notifyListeners();
  }

  Future<void> _setAndroidTelecomAudioPolicy(bool enabled) async {
    if (!orexIsAndroidNativePlatform ||
        _androidTelecomAudioPolicyApplied == enabled) {
      return;
    }
    try {
      if (enabled) {
        // Telecom owns the physical endpoint. LiveKit stays in manual mode for
        // the registered system-call lifetime, but unlike the old implementation
        // it receives a complete communication session first (mode/focus/stream
        // and active recording/playout policy). This keeps background media alive
        // without letting LiveKit repeatedly re-assert its own speaker route.
        await lk.AudioManager.instance.setAudioSessionOptions(
          const lk.AudioSessionOptions.communication(),
        );
      } else {
        await lk.AudioManager.instance.setAudioSessionManagementMode(
          lk.AudioSessionManagementMode.automatic,
        );
      }
      _androidTelecomAudioPolicyApplied = enabled;
      OrexLog.d(
        'Call',
        'LiveKit Android audio policy=${enabled ? 'telecom-managed' : 'automatic'}',
      );
    } catch (e) {
      OrexLog.d(
        'Call',
        'failed to apply LiveKit Android Telecom audio policy',
        e,
      );
    }
  }

  Future<void> _syncSystemCallControls() async {
    final session = _session;
    final instance = _systemCallInstance;
    if (session == null ||
        instance == null ||
        !_isCurrentControllerInstance(instance)) {
      return;
    }
    final micEnabled = session.status == CallStatus.connected
        ? session.micOn
        : session.microphoneRequestedOn;
    final audioEnabled = !session.speakerMuted;
    final cameraEnabled = session.cameraRequestedOn;
    if (_lastSystemMicEnabled == micEnabled &&
        _lastSystemAudioEnabled == audioEnabled &&
        _lastSystemCameraEnabled == cameraEnabled) {
      return;
    }
    final applied = await _systemCalls.updateControls(
      instance.roomId,
      ringEventId: instance.ringEventId,
      micEnabled: micEnabled,
      audioEnabled: audioEnabled,
      cameraEnabled: cameraEnabled,
    );
    if (!applied || !_sameCallInstance(_systemCallInstance, instance)) return;
    _lastSystemMicEnabled = micEnabled;
    _lastSystemAudioEnabled = audioEnabled;
    _lastSystemCameraEnabled = cameraEnabled;
  }

  Future<void> _syncForegroundCall({bool force = false}) async {
    if (!orexIsAndroidNativePlatform) return;
    final session = _session;
    final instance = currentCallInstance;
    final callId = instance?.roomId;
    final startedAt = _start;
    final room = callId == null ? null : matrix.client.getRoomById(callId);
    if (session == null ||
        callId == null ||
        startedAt == null ||
        room == null) {
      return;
    }

    // Answering is a user/signaling transition, not a transport-health state.
    // Once latched it must survive LiveKit reconnects; otherwise Android sees an
    // established call move back to an incoming/answering presentation.
    final answered = _callAnswered;
    final micEnabled = answered ? session.micOn : session.microphoneRequestedOn;
    final audioEnabled = !session.speakerMuted;
    final cameraEnabled = session.cameraRequestedOn;
    if (!force &&
        _sameCallInstance(_foregroundCallInstance, instance) &&
        _lastForegroundAnswered == answered &&
        _lastForegroundMicEnabled == micEnabled &&
        _lastForegroundAudioEnabled == audioEnabled &&
        _lastForegroundCameraEnabled == cameraEnabled) {
      return;
    }

    final applied = await _systemCalls.updateForegroundCall(
      callId: callId,
      displayName: room.getLocalizedDisplayname(),
      incoming: !_initiator,
      video: video,
      answered: answered,
      startedAt: startedAt,
      micEnabled: micEnabled,
      audioEnabled: audioEnabled,
      cameraEnabled: cameraEnabled,
      ringEventId: instance?.ringEventId,
    );
    if (!applied ||
        _session != session ||
        instance == null ||
        !_isCurrentControllerInstance(instance)) {
      return;
    }
    _foregroundCallInstance = instance;
    _lastForegroundAnswered = answered;
    _lastForegroundMicEnabled = micEnabled;
    _lastForegroundAudioEnabled = audioEnabled;
    _lastForegroundCameraEnabled = cameraEnabled;
  }

  Future<void> _stopForegroundCall(OrexCallInstance? instance) async {
    if (instance == null) return;
    if (_sameCallInstance(_foregroundCallInstance, instance)) {
      _clearForegroundCallState();
    }
    await _systemCalls.stopForegroundCall(
      instance.roomId,
      ringEventId: instance.ringEventId,
    );
  }

  void _clearForegroundCallState() {
    _foregroundCallInstance = null;
    _lastForegroundAnswered = null;
    _lastForegroundMicEnabled = null;
    _lastForegroundAudioEnabled = null;
    _lastForegroundCameraEnabled = null;
  }

  CallSession? _session;
  CallSession? get session => _session;

  String? roomId;
  bool video = false;
  bool listenOnly = false;
  bool minimized = false;
  bool _initiator = false; // мы начали этот звонок (а не присоединились)
  DateTime? _start;
  String? focusedParticipantIdentity;
  String? lastError;
  String? _currentRingEventId;
  OrexCallInstance? _systemCallInstance;
  OrexCallInstance? _systemPreparationInstance;
  Future<bool>? _systemPreparationFuture;
  bool _systemCallVideo = false;
  bool _systemMutedByTelecom = false;
  bool _systemActiveByTelecom = true;
  bool? _lastSystemMicEnabled;
  bool? _lastSystemAudioEnabled;
  bool? _lastSystemCameraEnabled;
  OrexCallInstance? _foregroundCallInstance;
  bool? _lastForegroundAnswered;
  bool? _lastForegroundMicEnabled;
  bool? _lastForegroundAudioEnabled;
  bool? _lastForegroundCameraEnabled;
  bool _androidTelecomAudioPolicyApplied = false;
  OrexCallInstance? _systemAnswerInProgress;
  OrexCallInstance? _systemTerminationInProgress;
  OrexCallInstance? _incomingAcceptInstance;
  Future<void>? _incomingAcceptFuture;
  int _incomingAcceptGeneration = 0;
  Timer? _unansweredCallTimer;
  Future<void>? _recoveryInFlight;
  Future<void>? _startOperation;
  Future<void>? _hangUpOperation;
  Future<void> _shutdownComplete = Future<void>.value();
  bool _recoveryResolved = false;
  Duration? _deferredInitialMediaRecovery;
  bool _callAnswered = false;
  int _lifecycleGeneration = 0;
  int _startCancellationGeneration = 0;
  bool _disposed = false;
  OrexCallSetupPhase setupPhase = OrexCallSetupPhase.idle;

  String get setupCaption => switch (setupPhase) {
    OrexCallSetupPhase.idle => 'Подготавливаем звонок…',
    OrexCallSetupPhase.preparing => 'Подготавливаем звонок…',
    OrexCallSetupPhase.signaling => 'Подключаем защищённый канал…',
    OrexCallSetupPhase.systemIntegration => 'Настраиваем системный звонок…',
    OrexCallSetupPhase.media => 'Подключаем медиа…',
    OrexCallSetupPhase.ready => 'Соединение…',
  };

  void _setSetupPhase(OrexCallSetupPhase value) {
    if (_disposed || setupPhase == value) return;
    setupPhase = value;
    notifyListeners();
  }

  OrexCallInstance _instanceForRoom(String roomId) => OrexCallInstance(
    roomId: roomId,
    ringEventId: this.roomId == roomId
        ? _currentRingEventId
        : matrix.voip?.incomingRingEventId(roomId),
  );

  bool isAcceptingIncoming(String roomId) =>
      _incomingAcceptInstance?.roomId == roomId &&
      _incomingAcceptFuture != null;

  bool isAcceptingIncomingInstance(OrexCallInstance instance) =>
      _incomingAcceptFuture != null &&
      _sameCallInstance(_incomingAcceptInstance, instance);

  OrexCallInstance? get currentCallInstance {
    final rid = roomId;
    return rid == null
        ? null
        : OrexCallInstance(roomId: rid, ringEventId: _currentRingEventId);
  }

  bool _sameCallInstance(OrexCallInstance? left, OrexCallInstance? right) =>
      left != null &&
      right != null &&
      left.roomId == right.roomId &&
      orexCallInstanceIdsMatch(left.ringEventId, right.ringEventId);

  bool _isCurrentControllerInstance(OrexCallInstance instance) =>
      roomId == instance.roomId &&
      orexCallInstanceIdsMatch(_currentRingEventId, instance.ringEventId);

  OrexCallInstance? _promoteOwnedInstance(
    OrexCallInstance? owned,
    OrexCallInstancePromotion promotion,
  ) => _sameCallInstance(owned, promotion.previous) ? promotion.current : owned;

  void _onCallInstancePromotion(OrexCallInstancePromotion promotion) {
    if (_disposed ||
        promotion.previous.ringEventId != null ||
        promotion.current.ringEventId == null ||
        promotion.previous.roomId != promotion.current.roomId) {
      return;
    }

    final systemWasPromoted = _sameCallInstance(
      _systemCallInstance,
      promotion.previous,
    );
    var changed = systemWasPromoted;

    OrexCallInstance? migrate(OrexCallInstance? owned) {
      final promoted = _promoteOwnedInstance(owned, promotion);
      if (!identical(promoted, owned)) changed = true;
      return promoted;
    }

    _systemCallInstance = migrate(_systemCallInstance);
    // Keep an in-flight legacy registration scoped to its original identity.
    // A concurrent exact prepare may then replace it; promoting this field in
    // place would make accept await the stale null-token registration instead.
    _foregroundCallInstance = migrate(_foregroundCallInstance);
    _systemAnswerInProgress = migrate(_systemAnswerInProgress);
    _systemTerminationInProgress = migrate(_systemTerminationInProgress);
    _incomingAcceptInstance = migrate(_incomingAcceptInstance);
    _pendingAcceptedIncomingCallUi = migrate(_pendingAcceptedIncomingCallUi);
    if (roomId == promotion.previous.roomId && _currentRingEventId == null) {
      _currentRingEventId = promotion.current.ringEventId;
      changed = true;
    }
    if (!changed) return;

    if (systemWasPromoted) {
      unawaited(_promoteNativeSystemCall(promotion.current));
    }
    if (_isCurrentControllerInstance(promotion.current)) {
      unawaited(_syncForegroundCall(force: true));
    }
    notifyListeners();
  }

  void _adoptTrustedExactInstance(OrexCallInstance instance) {
    if (instance.ringEventId == null) return;
    _onCallInstancePromotion(
      OrexCallInstancePromotion(
        previous: OrexCallInstance(roomId: instance.roomId),
        current: instance,
      ),
    );
  }

  Future<void> _promoteNativeSystemCall(OrexCallInstance instance) async {
    final room = matrix.client.getRoomById(instance.roomId);
    if (room == null || !_sameCallInstance(_systemCallInstance, instance)) {
      return;
    }
    final session = _isCurrentControllerInstance(instance) ? _session : null;
    final micEnabled = session == null
        ? true
        : session.status == CallStatus.connected
        ? session.micOn
        : session.microphoneRequestedOn;
    final audioEnabled = session == null ? true : !session.speakerMuted;
    final cameraEnabled = session == null
        ? _systemCallVideo
        : session.cameraRequestedOn;
    final incoming = session == null || !_initiator;
    final registered = incoming
        ? await _systemCalls.reportIncomingCall(
            callId: instance.roomId,
            ringEventId: instance.ringEventId,
            displayName: room.getLocalizedDisplayname(),
            video: _systemCallVideo,
            avatarCacheKey: _conversationAvatarCacheKey(room),
            startedAt: _start,
            micEnabled: micEnabled,
            audioEnabled: audioEnabled,
            cameraEnabled: cameraEnabled,
          )
        : await _systemCalls.reportOutgoingCall(
            callId: instance.roomId,
            ringEventId: instance.ringEventId,
            displayName: room.getLocalizedDisplayname(),
            video: _systemCallVideo,
            avatarCacheKey: _conversationAvatarCacheKey(room),
            startedAt: _start,
            micEnabled: micEnabled,
            audioEnabled: audioEnabled,
            cameraEnabled: cameraEnabled,
          );
    if (!registered) return;
    if (!_sameCallInstance(_systemCallInstance, instance)) {
      await _systemCalls.endCall(
        instance.roomId,
        ringEventId: instance.ringEventId,
        reason: 'remote',
      );
      return;
    }
    _refreshSystemCallAvatar(
      room,
      instance: instance,
      video: _systemCallVideo,
      incoming: incoming,
    );
  }

  Future<void> get shutdownComplete => _shutdownComplete;

  void focusParticipant(String? identity) {
    if (_disposed) return;
    if (focusedParticipantIdentity == identity) return;
    focusedParticipantIdentity = identity;
    notifyListeners();
  }

  bool _canUseMicNowFor(String roomId) {
    final room = matrix.client.getRoomById(roomId);
    if (room == null) return true;
    final kind = matrix.roomKind(room);
    return kind != OrexRoomKind.channel ||
        matrix.voicePermissions.canSpeak(room, matrix.client.userID);
  }

  Future<void> recoverMediaAfterBackground(Duration backgroundDuration) async {
    final session = _session;
    if (session == null) return;
    // Answering from a notification resumes MainActivity while the initial
    // LiveKit connection is still running. Recovery must never start a second
    // WebRTC room over that first connection, but the device/media refresh must
    // still run once that connection becomes ready.
    if (!session.hasReachedMediaReady) {
      final pending = _deferredInitialMediaRecovery;
      if (pending == null || backgroundDuration > pending) {
        _deferredInitialMediaRecovery = backgroundDuration;
      }
      return;
    }
    await session.recoverAfterBackground(backgroundDuration);
    if (!identical(_session, session)) return;
    await _syncSystemCallControls();
    notifyListeners();
  }

  Future<void> refreshVoicePermissions() async {
    await _session?.refreshVoicePermissions();
    if (_disposed) return;
    final rid = roomId;
    listenOnly = rid == null ? false : !_canUseMicNowFor(rid);
    if (!_disposed) notifyListeners();
  }

  bool get isActive => _session != null;

  /// A start request can wait behind teardown or Telecom before it creates the
  /// media session. Mobile presentation stays expanded during that interval.
  bool get isStarting =>
      _startOperation != null && setupPhase != OrexCallSetupPhase.idle;

  bool _isPersonalCall(Room? room) =>
      room != null &&
      (matrix.voip?.isPersonalCallRoom(room) ?? room.isDirectChat);

  bool _isSystemCallEligible(Room? room) => _isPersonalCall(room);

  String? _conversationAvatarCacheKey(Room room) {
    final avatar = matrix.conversationAvatar(room);
    return avatar == null ? null : matrix.avatarCacheKey(avatar);
  }

  void _refreshSystemCallAvatar(
    Room room, {
    required OrexCallInstance instance,
    required bool video,
    required bool incoming,
  }) {
    final avatar = matrix.conversationAvatar(room);
    if (avatar == null) return;
    unawaited(
      matrix.ensureConversationAvatarCached(room).then((cacheKey) async {
        if (cacheKey == null ||
            !_sameCallInstance(_systemCallInstance, instance)) {
          return;
        }
        // Avatar resolution can finish after the user has already answered.
        // Never resurrect an incoming Telecom presentation for an active media
        // call; ongoing state is maintained by updateForegroundCall instead.
        if (incoming && isActive && _isCurrentControllerInstance(instance)) {
          return;
        }
        if (incoming) {
          await _systemCalls.reportIncomingCall(
            callId: room.id,
            ringEventId: instance.ringEventId,
            displayName: room.getLocalizedDisplayname(),
            video: video,
            avatarCacheKey: cacheKey,
          );
        } else {
          await _systemCalls.reportOutgoingCall(
            callId: room.id,
            ringEventId: instance.ringEventId,
            displayName: room.getLocalizedDisplayname(),
            video: video,
            avatarCacheKey: cacheKey,
          );
        }
      }),
    );
  }

  /// Регистрирует входящий личный вызов в Android Telecom до показа Flutter UI.
  ///
  /// Для одного callId существует только один in-flight запрос. Это закрывает
  /// гонку, когда пользователь успевает ответить/отклонить вызов или Matrix
  /// присылает remote-dismiss, пока Core-Telecom ещё создаёт системную сессию.
  Future<bool> prepareIncoming(
    Room room, {
    bool video = false,
    OrexCallInstance? instance,
  }) {
    final callInstance = instance ?? _instanceForRoom(room.id);
    if (!_isSystemCallEligible(room)) return Future<bool>.value(false);
    _systemCallVideo = video;
    if (isActive) {
      // An already-running media call must never be re-registered as incoming.
      // If Core-Telecom disappeared, keep the call alive without system UI
      // instead of surfacing another ringing session for the same Matrix room.
      return Future<bool>.value(
        _isCurrentControllerInstance(callInstance) &&
            _sameCallInstance(_systemCallInstance, callInstance),
      );
    }
    final existingSystemCall = _systemCallInstance;
    if (existingSystemCall != null &&
        !_sameCallInstance(existingSystemCall, callInstance)) {
      return (() async {
        await _systemCalls.endCall(
          existingSystemCall.roomId,
          ringEventId: existingSystemCall.ringEventId,
          reason: 'remote',
        );
        if (_sameCallInstance(_systemCallInstance, existingSystemCall)) {
          _clearSystemCallState();
        }
        return prepareIncoming(room, video: video, instance: callInstance);
      })();
    }

    final pending = _systemPreparationFuture;
    if (_sameCallInstance(_systemPreparationInstance, callInstance) &&
        pending != null) {
      return pending;
    }

    if (!_sameCallInstance(_systemCallInstance, callInstance)) {
      _systemCallInstance = callInstance;
      _systemMutedByTelecom = false;
      _systemActiveByTelecom = true;
    }

    late final Future<bool> registration;
    registration = _registerIncomingSystemCall(room, video, callInstance)
        .whenComplete(() {
          if (identical(_systemPreparationFuture, registration)) {
            _systemPreparationInstance = null;
            _systemPreparationFuture = null;
          }
        });
    _systemPreparationInstance = callInstance;
    _systemPreparationFuture = registration;
    return registration;
  }

  Future<bool> _registerIncomingSystemCall(
    Room room,
    bool video,
    OrexCallInstance instance,
  ) async {
    final registered = await _systemCalls.reportIncomingCall(
      callId: room.id,
      ringEventId: instance.ringEventId,
      displayName: room.getLocalizedDisplayname(),
      video: video,
      avatarCacheKey: _conversationAvatarCacheKey(room),
    );
    if (!registered) {
      if (_sameCallInstance(_systemCallInstance, instance)) {
        _clearSystemCallState();
      }
      return false;
    }

    // Владение могло быть снято, пока native addCall ожидал Telecom. Не даём
    // запоздавшей регистрации оставить фантомный CallStyle/системный звонок.
    if (!_sameCallInstance(_systemCallInstance, instance)) {
      await _systemCalls.endCall(
        room.id,
        ringEventId: instance.ringEventId,
        reason: 'remote',
      );
      return false;
    }
    _refreshSystemCallAvatar(
      room,
      instance: instance,
      video: video,
      incoming: true,
    );
    return true;
  }

  Future<bool> _rejectPreparedSystemCall(OrexCallInstance instance) async {
    final pending = _sameCallInstance(_systemPreparationInstance, instance)
        ? _systemPreparationFuture
        : null;
    if (pending != null && !await pending) return true;
    if (!_sameCallInstance(_systemCallInstance, instance)) return true;
    return _systemCalls.rejectCall(
      instance.roomId,
      ringEventId: instance.ringEventId,
    );
  }

  Future<void> acceptIncoming(
    Room room, {
    required bool video,
    OrexCallInstance? instance,
    bool fromSystem = false,
    bool requestExpandedUi = false,
  }) {
    if (_disposed) return Future<void>.value();
    final callInstance = instance ?? _instanceForRoom(room.id);
    _adoptTrustedExactInstance(callInstance);
    if (isActive && _isCurrentControllerInstance(callInstance)) {
      return Future<void>.value();
    }
    final pending = _incomingAcceptFuture;
    if (_sameCallInstance(_incomingAcceptInstance, callInstance) &&
        pending != null) {
      return pending;
    }

    final acceptGeneration = ++_incomingAcceptGeneration;
    late final Future<void> operation;
    operation =
        (() async {
          try {
            await orexRunCallStage<void>(
              stage: 'incoming-accept',
              timeout: const Duration(seconds: 55),
              operation: () => _acceptIncomingImpl(
                room,
                video: video,
                fromSystem: fromSystem,
                requestExpandedUi: requestExpandedUi,
                acceptGeneration: acceptGeneration,
                instance: callInstance,
              ),
            );
          } on OrexCallStageTimeout catch (e) {
            if (_incomingAcceptGeneration == acceptGeneration) {
              _incomingAcceptGeneration++;
              lastError =
                  'Подключение заняло слишком много времени. Проверьте сеть и повторите звонок.';
              OrexLog.d('Call', 'incoming accept timed out room=${room.id}', e);
              try {
                await hangUp().timeout(const Duration(seconds: 10));
              } on TimeoutException {
                OrexLog.d(
                  'Call',
                  'incoming timeout cleanup continues asynchronously room=${room.id}',
                );
              }
            }
            rethrow;
          }
        })().whenComplete(() {
          if (identical(_incomingAcceptFuture, operation)) {
            _incomingAcceptInstance = null;
            _incomingAcceptFuture = null;
          }
        });
    _incomingAcceptInstance = callInstance;
    _incomingAcceptFuture = operation;
    return operation;
  }

  Future<void> _acceptIncomingImpl(
    Room room, {
    required bool video,
    required bool fromSystem,
    required bool requestExpandedUi,
    required int acceptGeneration,
    required OrexCallInstance instance,
  }) async {
    var currentInstance = instance;
    bool refreshOwnership() {
      final refreshed = _currentIncomingAcceptInstance(
        instance,
        acceptGeneration,
      );
      if (refreshed == null) return false;
      currentInstance = refreshed;
      return true;
    }

    matrix.audio.stopIncomingRingtone();
    // Persist ANSWERING before any potentially slow Telecom/Matrix operation,
    // so a delayed duplicate FCM delivery cannot ring again in the meantime.
    await matrix.push.notifyCallAnswering(
      room.id,
      ringEventId: currentInstance.ringEventId,
    );
    if (!refreshOwnership()) return;
    if (isActive && roomId != room.id) await hangUp();
    if (!refreshOwnership()) return;
    final otherSystemCall = _systemCallInstance;
    if (otherSystemCall != null && otherSystemCall.roomId != room.id) {
      await _systemCalls.endCall(
        otherSystemCall.roomId,
        ringEventId: otherSystemCall.ringEventId,
        reason: 'local',
      );
      if (_sameCallInstance(_systemCallInstance, otherSystemCall)) {
        _clearSystemCallState();
      }
    }
    if (!refreshOwnership()) return;
    if (fromSystem) {
      matrix.voip?.dismissIncomingFromSystem(currentInstance);
    }

    var nativeAlreadyAnswered = false;
    var hasPreparedIncomingCall =
        _sameCallInstance(_systemCallInstance, currentInstance) ||
        _sameCallInstance(_systemPreparationInstance, currentInstance);
    final nativeCallExists = await _systemCalls.hasCall(
      room.id,
      ringEventId: currentInstance.ringEventId,
    );
    if (!refreshOwnership()) return;
    if (nativeCallExists && !hasPreparedIncomingCall) {
      final nativeCall = await _systemCalls.recoverableCall();
      if (!refreshOwnership()) return;
      final nativeInstance = nativeCall == null
          ? null
          : OrexCallInstance(
              roomId: nativeCall.callId,
              ringEventId: nativeCall.ringEventId,
            );
      if (nativeCall == null ||
          (_sameCallInstance(nativeInstance, currentInstance) &&
              nativeCall.incoming)) {
        hasPreparedIncomingCall = true;
        nativeAlreadyAnswered = nativeCall?.answered == true;
        _systemCallInstance = currentInstance;
      }
    }
    // A persisted PendingIntent can cold-start Flutter after Android killed the
    // process-local CallControl. Trust the native manager, not [fromSystem],
    // before enabling Telecom ownership and its audio policy.
    var registered = orexShouldReusePreparedIncomingSystemCall(
      fromSystem: fromSystem,
      hasPreparedIncomingCall: hasPreparedIncomingCall,
      nativeCallExists: nativeCallExists,
    );
    if (hasPreparedIncomingCall && !fromSystem && !nativeAlreadyAnswered) {
      // Tell native code that the user accepted before waiting for an in-flight
      // addCall. It silences the app-owned ring immediately and its setup scope
      // answers before completing the registration future.
      final nativeAnswer = _systemCalls.answerCall(
        room.id,
        ringEventId: currentInstance.ringEventId,
        video: video,
      );
      if (_sameCallInstance(_systemPreparationInstance, currentInstance)) {
        registered = await prepareIncoming(
          room,
          video: video,
          instance: currentInstance,
        );
      }
      final answered = await nativeAnswer;
      if (!refreshOwnership()) return;
      if (!answered) {
        await _systemCalls.endCall(
          room.id,
          ringEventId: currentInstance.ringEventId,
          reason: 'error',
        );
        if (_sameCallInstance(_systemCallInstance, currentInstance)) {
          _clearSystemCallState();
        }
        registered = false;
      }
    }
    if (!refreshOwnership()) return;

    // Stop this account's sibling devices immediately, but do not tell the
    // remote caller that media was accepted until our MatrixRTC membership is
    // actually published. Sending `accepted` before enterCall() caused the
    // caller to return an exact `handled` cancellation while this start was
    // still pending, which cancelled the very accept operation that produced it.
    final acceptedInstance = currentInstance;
    final handledSync = _markIncomingHandled(acceptedInstance);
    Future<void>? acceptedSync;
    void publishAccepted(OrexCallInstance signalingInstance) {
      acceptedSync ??= _notifyIncomingAccepted(signalingInstance);
    }

    // Never create a fresh Core-Telecom incoming call after the user answered.
    // If no native incoming existed, the independent foreground-call owner is
    // sufficient and avoids a second system RINGING transition by construction.
    final shouldRequestExpandedUi =
        fromSystem ||
        requestExpandedUi ||
        (!kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS));
    final mediaStart = start(
      room.id,
      video: video,
      systemIncoming: true,
      systemCallPrepared: registered,
      initialAnswered: true,
      ringEventId: acceptedInstance.ringEventId,
      onSignalingReady: publishAccepted,
    );
    await mediaStart;
    if (shouldRequestExpandedUi) {
      final session = _session;
      final uiInstance = currentCallInstance;
      if (session?.status == CallStatus.connected &&
          uiInstance != null &&
          uiInstance.roomId == acceptedInstance.roomId) {
        _requestAcceptedIncomingCallUi(uiInstance);
      }
    }
    try {
      await handledSync.timeout(const Duration(seconds: 4));
    } on TimeoutException {
      OrexLog.d(
        'Call',
        'sibling-device handled sync deferred room=${room.id}',
      );
    }
    final remoteAcceptedSync = acceptedSync;
    if (remoteAcceptedSync != null) {
      try {
        await remoteAcceptedSync.timeout(const Duration(seconds: 4));
      } on TimeoutException {
        OrexLog.d('Call', 'remote accepted sync deferred room=${room.id}');
      }
    }
  }

  OrexCallInstance? _currentIncomingAcceptInstance(
    OrexCallInstance initial,
    int generation,
  ) {
    if (_disposed ||
        _incomingAcceptInstance?.roomId != initial.roomId ||
        _incomingAcceptGeneration != generation) {
      return null;
    }
    final current = _incomingAcceptInstance ?? initial;
    if (!(matrix.voip?.isCurrentCallInstance(current) ?? true)) return null;
    return current;
  }

  Future<void> rejectIncoming(
    Room room, {
    OrexCallInstance? instance,
    bool fromSystem = false,
  }) async {
    final callInstance = instance ?? _instanceForRoom(room.id);
    _adoptTrustedExactInstance(callInstance);
    matrix.audio.stopIncomingRingtone();
    await matrix.push.notifyCallEnded(
      room.id,
      ringEventId: callInstance.ringEventId,
    );
    if (fromSystem) matrix.voip?.dismissIncomingFromSystem(callInstance);
    final dispositionSync = Future.wait<void>([
      _markIncomingHandled(callInstance),
      _notifyIncomingRejected(callInstance),
    ]);
    final systemEnded =
        fromSystem || await _rejectPreparedSystemCall(callInstance);
    if (systemEnded && _sameCallInstance(_systemCallInstance, callInstance)) {
      _clearSystemCallState();
    }
    await dispositionSync;
  }

  OrexCallInstance _instanceFromSystemAction(OrexSystemCallAction action) =>
      OrexCallInstance(roomId: action.callId, ringEventId: action.ringEventId);

  bool _ownsSystemCall(OrexCallInstance instance) =>
      _sameCallInstance(_systemCallInstance, instance) ||
      _isCurrentControllerInstance(instance);

  /// Возвращаем native-layer подтверждение только после локальной обработки
  /// команды. Для hold/mute дожидаемся фактического изменения медиа. Долгие
  /// MatrixRTC/LiveKit операции answer/disconnect запускаем после синхронного
  /// перевода локального состояния, чтобы уложиться в Telecom callback timeout.
  Future<bool> _onSystemCallAction(OrexSystemCallAction action) async {
    try {
      final instance = _instanceFromSystemAction(action);
      _adoptTrustedExactInstance(instance);
      switch (action.type) {
        case OrexSystemCallActionType.answer:
          return _acceptIncomingFromSystem(action);
        case OrexSystemCallActionType.reject:
          return _terminateFromSystem(action, rejected: true);
        case OrexSystemCallActionType.disconnect:
          return _terminateFromSystem(action, rejected: false);
        case OrexSystemCallActionType.setActive:
          if (!_ownsSystemCall(instance)) return false;
          _systemActiveByTelecom = true;
          final session = _isCurrentControllerInstance(instance)
              ? _session
              : null;
          if (session != null) await session.setSystemActive(true);
          return true;
        case OrexSystemCallActionType.setInactive:
          if (!_ownsSystemCall(instance)) return false;
          _systemActiveByTelecom = false;
          final session = _isCurrentControllerInstance(instance)
              ? _session
              : null;
          if (session != null) await session.setSystemActive(false);
          return true;
        case OrexSystemCallActionType.muteChanged:
          final muted = action.muted;
          if (muted == null || !_ownsSystemCall(instance)) return false;
          _systemMutedByTelecom = muted;
          final session = _isCurrentControllerInstance(instance)
              ? _session
              : null;
          if (session != null) await session.setSystemMuted(muted);
          return true;
        case OrexSystemCallActionType.toggleMic:
          if (!_ownsSystemCall(instance)) return false;
          final session = _isCurrentControllerInstance(instance)
              ? _session
              : null;
          if (session == null) return false;
          await session.toggleMic();
          await _syncSystemCallControls();
          return true;
        case OrexSystemCallActionType.toggleAudio:
          if (!_ownsSystemCall(instance)) return false;
          final session = _isCurrentControllerInstance(instance)
              ? _session
              : null;
          if (session == null) return false;
          await session.toggleSpeakerMute();
          await _syncSystemCallControls();
          return true;
      }
    } catch (e) {
      OrexLog.d(
        'Call',
        'system action failed type=${action.type.name} call=${action.callId}',
        e,
      );
      return false;
    }
  }

  bool _acceptIncomingFromSystem(OrexSystemCallAction action) {
    final instance = _instanceFromSystemAction(action);
    if (isActive && _isCurrentControllerInstance(instance)) return true;
    final room = matrix.client.getRoomById(action.callId);
    if (room == null || !_isSystemCallEligible(room)) return false;
    if (!_ownsSystemCall(instance) &&
        !(matrix.voip?.isCurrentCallInstance(instance) ?? false)) {
      return false;
    }
    if (_sameCallInstance(_systemTerminationInProgress, instance)) return true;
    if (_sameCallInstance(_systemAnswerInProgress, instance)) return true;
    _systemAnswerInProgress = instance;
    unawaited(_runSystemAnswer(room, action, instance));
    return true;
  }

  Future<void> _runSystemAnswer(
    Room room,
    OrexSystemCallAction action,
    OrexCallInstance instance,
  ) async {
    try {
      await acceptIncoming(
        room,
        video: action.video ?? false,
        instance: instance,
        fromSystem: true,
      );
    } catch (e) {
      OrexLog.d('Call', 'system answer failed call=${action.callId}', e);
      if (_ownsSystemCall(instance)) {
        await _systemCalls.endCall(
          action.callId,
          ringEventId: instance.ringEventId,
          reason: 'error',
        );
        if (_sameCallInstance(_systemCallInstance, instance)) {
          _clearSystemCallState();
        }
      }
    } finally {
      if (_sameCallInstance(_systemAnswerInProgress, instance)) {
        _systemAnswerInProgress = null;
      }
    }
  }

  bool _terminateFromSystem(
    OrexSystemCallAction action, {
    required bool rejected,
  }) {
    final instance = _instanceFromSystemAction(action);
    if (!_ownsSystemCall(instance) &&
        !(matrix.voip?.isCurrentCallInstance(instance) ?? false)) {
      return false;
    }
    if (_sameCallInstance(_systemTerminationInProgress, instance)) return true;
    // Cancellation is latched synchronously, before the Telecom callback is
    // acknowledged. The async answer path checks this generation after every
    // native/network await and therefore cannot resurrect media afterwards.
    final acceptedInProgress = _sameCallInstance(
      _incomingAcceptInstance,
      instance,
    );
    if (acceptedInProgress) {
      _incomingAcceptGeneration++;
      _lifecycleGeneration++;
      _startCancellationGeneration++;
    }
    matrix.audio.stopIncomingRingtone();
    _systemTerminationInProgress = instance;
    unawaited(
      _runSystemTermination(
        instance,
        rejected: rejected,
        acceptedInProgress: acceptedInProgress,
      ),
    );
    return true;
  }

  Future<void> _runSystemTermination(
    OrexCallInstance instance, {
    required bool rejected,
    required bool acceptedInProgress,
  }) async {
    final callId = instance.roomId;
    try {
      if (_isCurrentControllerInstance(instance)) {
        await hangUp(fromSystem: true);
        return;
      }
      final room = matrix.client.getRoomById(callId);
      if (room != null) {
        if (rejected) {
          await rejectIncoming(room, instance: instance, fromSystem: true);
        } else {
          matrix.audio.stopIncomingRingtone();
          matrix.voip?.dismissIncomingFromSystem(instance);
          if (_sameCallInstance(_systemCallInstance, instance)) {
            _clearSystemCallState();
          }
          await _markIncomingHandled(instance);
          if (orexShouldNotifyEndedForSystemTermination(
            rejected: rejected,
            acceptedInProgress: acceptedInProgress,
          )) {
            await matrix.voip?.notifyEnded(instance);
          }
        }
      } else if (_sameCallInstance(_systemCallInstance, instance)) {
        _clearSystemCallState();
      }
    } catch (e) {
      OrexLog.d('Call', 'system termination failed call=$callId', e);
    } finally {
      if (_sameCallInstance(_systemTerminationInProgress, instance)) {
        _systemTerminationInProgress = null;
      }
    }
  }

  Future<void> _markIncomingHandled(OrexCallInstance instance) async {
    try {
      await matrix.voip?.markCallHandled(instance);
    } catch (e) {
      OrexLog.d(
        'Call',
        'failed to sync handled state call=${instance.roomId}',
        e,
      );
    }
  }

  Future<void> _notifyIncomingAccepted(OrexCallInstance instance) async {
    try {
      await matrix.voip?.notifyAccepted(instance);
    } catch (e) {
      OrexLog.d(
        'Call',
        'failed to sync accepted state call=${instance.roomId}',
        e,
      );
    }
  }

  Future<void> _notifyIncomingRejected(OrexCallInstance instance) async {
    try {
      await matrix.voip?.notifyRejected(instance);
    } catch (e) {
      OrexLog.d(
        'Call',
        'failed to sync rejected state call=${instance.roomId}',
        e,
      );
    }
  }

  void _cancelPendingIncomingAccept(OrexCallInstance instance) {
    if (!_sameCallInstance(_incomingAcceptInstance, instance)) return;
    _incomingAcceptGeneration++;
    _lifecycleGeneration++;
    _startCancellationGeneration++;
    if (_sameCallInstance(_pendingAcceptedIncomingCallUi, instance)) {
      _pendingAcceptedIncomingCallUi = null;
    }
  }

  void _onIncomingDismissed(OrexIncomingCallDismissal dismissal) {
    final instance = OrexCallInstance(
      roomId: dismissal.roomId,
      ringEventId: dismissal.ringEventId,
    );
    _adoptTrustedExactInstance(instance);
    if (dismissal.cancelsPendingAccept) {
      _cancelPendingIncomingAccept(instance);
    }
    if (_sameCallInstance(_systemAnswerInProgress, instance) ||
        _sameCallInstance(_systemTerminationInProgress, instance) ||
        (isActive && _isCurrentControllerInstance(instance))) {
      return;
    }

    // A direct FCM ring can exist before Core-Telecom/CallController owns the
    // call. `handled` from another device still has to cancel that native
    // notification/activity, otherwise the tablet keeps ringing forever even
    // though Flutter already removed its incoming route.
    unawaited(
      matrix.push.notifyCallEnded(
        instance.roomId,
        ringEventId: instance.ringEventId,
      ),
    );

    if (!_sameCallInstance(_systemCallInstance, instance)) return;
    _clearSystemCallState();
    unawaited(
      _systemCalls.endCall(
        instance.roomId,
        ringEventId: instance.ringEventId,
        reason: 'remote',
      ),
    );
  }

  void _onRemoteCallAccepted(OrexRemoteCallAccepted accepted) {
    if (_initiator && isActive && _isCurrentControllerInstance(accepted)) {
      _cancelUnansweredTimeout();
      // The accepting device already stopped itself locally. Send an exact
      // cancellation from the original caller so the same account's killed
      // tablet/secondary phone also stops ringing via FCM.
      unawaited(matrix.voip?.cancelOutstandingRing(accepted));
    }
  }

  void _onRemoteCallTermination(OrexRemoteCallTermination termination) {
    final instance = OrexCallInstance(
      roomId: termination.roomId,
      ringEventId: termination.ringEventId,
    );
    _adoptTrustedExactInstance(instance);
    _cancelPendingIncomingAccept(instance);
    if (_initiator && _isCurrentControllerInstance(instance)) {
      unawaited(matrix.voip?.cancelOutstandingRing(instance));
      if (termination.reason != OrexRemoteCallTerminationReason.ended) {
        _cancelUnansweredTimeout();
      }
    }
    if (isActive && _isCurrentControllerInstance(instance)) {
      if (!orexShouldEndEstablishedCallForRemoteDisposition(
        reason: termination.reason,
      )) {
        _callAnswered = true;
        unawaited(_syncForegroundCall(force: true));
        unawaited(_syncSystemCallControls());
        notifyListeners();
        OrexLog.d(
          'Call',
          'kept MatrixRTC channel open after ${termination.reason.name} '
              'room=${termination.roomId}',
        );
        return;
      }
      unawaited(hangUp(fromRemote: true));
      return;
    }
    if (_sameCallInstance(_systemCallInstance, instance)) {
      _clearSystemCallState();
      unawaited(
        _systemCalls.endCall(
          termination.roomId,
          ringEventId: termination.ringEventId,
          reason: 'remote',
        ),
      );
    }
  }

  static const Duration _outgoingAnswerTimeout = Duration(seconds: 45);

  void _scheduleUnansweredTimeout(CallSession session, String callId) {
    _unansweredCallTimer?.cancel();
    _unansweredCallTimer = Timer(_outgoingAnswerTimeout, () {
      _unansweredCallTimer = null;
      if (_session != session || roomId != callId || session.sawRemote) return;
      OrexLog.d('Call', 'outgoing call timed out without answer room=$callId');
      unawaited(hangUp());
    });
  }

  void _cancelUnansweredTimeout() {
    _unansweredCallTimer?.cancel();
    _unansweredCallTimer = null;
  }

  bool _shouldSendEndedSignal(Room room, CallSession? session) {
    if (!(matrix.voip?.isPersonalCallRoom(room) ?? room.isDirectChat)) {
      return false;
    }

    // Once a real peer has joined the media session, leaving is a local action:
    // the other participant may intentionally stay in the room and wait for a
    // reconnect. Do not let a temporarily stale Matrix membership cache turn
    // that local leave into a remote `ended` for the whole personal call.
    if (session?.sawRemote == true) return false;

    return !matrix.callMemberIds(room).any((id) => id != matrix.client.userID);
  }

  Future<void> recoverPendingCall() {
    if (_recoveryResolved) return Future<void>.value();
    final inFlight = _recoveryInFlight;
    if (inFlight != null) return inFlight;

    late final Future<void> operation;
    operation = _recoverPendingCall().whenComplete(() {
      if (identical(_recoveryInFlight, operation)) _recoveryInFlight = null;
    });
    _recoveryInFlight = operation;
    return operation;
  }

  Future<bool> discardRecoverableCall(
    String callId, {
    String? ringEventId,
  }) async {
    final cleared = await _systemCalls.clearRecoverableCall(
      callId,
      ringEventId: ringEventId,
    );
    if (cleared) _recoveryResolved = true;
    return cleared;
  }

  Future<void> _discardKnownRecoverableCall(
    OrexRecoverableSystemCall recoverable,
  ) async {
    final cleared = await _systemCalls.clearRecoverableCall(
      recoverable.callId,
      ringEventId: recoverable.ringEventId,
    );
    if (cleared) _recoveryResolved = true;
  }

  Future<void> _recoverPendingCall() async {
    if (isActive || !matrix.client.isLogged() || matrix.voip == null) return;
    final recoverable = await _systemCalls.recoverableCall();
    if (recoverable == null) {
      _recoveryResolved = true;
      return;
    }
    if (!recoverable.answered) {
      await _discardKnownRecoverableCall(recoverable);
      return;
    }

    final age = DateTime.now().difference(recoverable.updatedAt);
    if (age > const Duration(hours: 4)) {
      await _discardKnownRecoverableCall(recoverable);
      return;
    }

    final room = matrix.client.getRoomById(recoverable.callId);
    if (room == null || !matrix.roomHasActiveCall(room)) {
      await _discardKnownRecoverableCall(recoverable);
      return;
    }

    OrexLog.d('Call', 'recovering active call room=${recoverable.callId}');
    await start(
      recoverable.callId,
      video: recoverable.video,
      initialMicOn: recoverable.micEnabled,
      initialCameraOn: recoverable.cameraEnabled,
      initialAudioEnabled: recoverable.audioEnabled,
      recoveredStartedAt: recoverable.startedAt,
      // An answered call must never be restored as a fresh incoming call:
      // Core-Telecom would be allowed to surface ringing UI again. Register
      // the recreated system session as ongoing and mark it active only after
      // media reconnects successfully.
      systemIncoming: false,
      recovering: true,
      initialAnswered: true,
      ringEventId: recoverable.ringEventId,
    );
    if (isActive &&
        _isCurrentControllerInstance(
          OrexCallInstance(
            roomId: recoverable.callId,
            ringEventId: recoverable.ringEventId,
          ),
        )) {
      _recoveryResolved = true;
    }
  }

  /// Начать/присоединиться к звонку в комнате.
  Future<void> start(
    String roomId, {
    required bool video,
    String? ringEventId,
    bool? initialMicOn,
    bool? initialCameraOn,
    bool? initialAudioEnabled,
    DateTime? recoveredStartedAt,
    bool systemIncoming = false,
    bool? systemCallPrepared,
    bool recovering = false,
    bool initialAnswered = false,
    void Function()? onSessionCreated,
    void Function(OrexCallInstance instance)? onSignalingReady,
  }) {
    if (_disposed) return Future<void>.value();
    final startCancellationGeneration = _startCancellationGeneration;
    final previousStart = _startOperation;
    late final Future<void> operation;
    operation =
        (() async {
          if (previousStart != null) {
            try {
              await previousStart;
            } catch (_) {
              // The preceding start reports its own failure. A successor still
              // waits for all of its scoped cleanup before taking native ownership.
            }
          }
          if (orexIsCallStartRequestCancelled(
            disposed: _disposed,
            capturedGeneration: startCancellationGeneration,
            currentGeneration: _startCancellationGeneration,
          )) {
            return;
          }
          final promotedIncomingRingEventId =
              systemIncoming &&
                  ringEventId == null &&
                  _incomingAcceptInstance?.roomId == roomId
              ? _incomingAcceptInstance?.ringEventId
              : ringEventId;
          await _startInternal(
            roomId,
            startCancellationGeneration: startCancellationGeneration,
            video: video,
            ringEventId: promotedIncomingRingEventId,
            initialMicOn: initialMicOn,
            initialCameraOn: initialCameraOn,
            initialAudioEnabled: initialAudioEnabled,
            recoveredStartedAt: recoveredStartedAt,
            systemIncoming: systemIncoming,
            systemCallPrepared: systemCallPrepared,
            recovering: recovering,
            initialAnswered: initialAnswered,
            onSessionCreated: onSessionCreated,
            onSignalingReady: onSignalingReady,
          );
        })().whenComplete(() {
          if (identical(_startOperation, operation)) {
            _startOperation = null;
            if (!_disposed) notifyListeners();
          }
        });
    _startOperation = operation;
    if (_session == null) {
      setupPhase = OrexCallSetupPhase.preparing;
      notifyListeners();
    }
    return operation;
  }

  Future<void> _startInternal(
    String roomId, {
    required int startCancellationGeneration,
    required bool video,
    required String? ringEventId,
    bool? initialMicOn,
    bool? initialCameraOn,
    bool? initialAudioEnabled,
    DateTime? recoveredStartedAt,
    bool systemIncoming = false,
    bool? systemCallPrepared,
    bool recovering = false,
    bool initialAnswered = false,
    void Function()? onSessionCreated,
    void Function(OrexCallInstance instance)? onSignalingReady,
  }) async {
    bool wasCancelled() => orexIsCallStartRequestCancelled(
      disposed: _disposed,
      capturedGeneration: startCancellationGeneration,
      currentGeneration: _startCancellationGeneration,
    );
    if (wasCancelled()) return;
    while (_hangUpOperation != null) {
      await _hangUpOperation;
      if (wasCancelled()) return;
    }
    if (_session != null) {
      if (this.roomId == roomId) return;
      await hangUp(cancelPendingStarts: false);
      if (wasCancelled()) return;
    }
    _cancelUnansweredTimeout();
    final generation = ++_lifecycleGeneration;
    lastError = null;
    _setSetupPhase(OrexCallSetupPhase.preparing);
    this.roomId = roomId;
    _currentRingEventId = ringEventId;
    this.video = video;
    minimized = false;
    // Инициатор = в комнате ещё не было активного звонка до нас.
    final room = matrix.client.getRoomById(roomId);
    final kind = room != null ? matrix.roomKind(room) : OrexRoomKind.group;
    if (room != null && kind == OrexRoomKind.channel) {
      await matrix.voicePermissions.ensureParticipantStatePowerLevels(room);
      if (wasCancelled() || generation != _lifecycleGeneration) return;
    }
    final canSpeak = _canUseMicNowFor(roomId);
    listenOnly = !canSpeak;
    final micInitiallyOn =
        initialMicOn ??
        matrix.audio.callMicEnabledOverride ??
        (room?.isDirectChat == true ? true : false);
    _initiator = orexShouldInitiateCall(
      systemIncoming: systemIncoming,
      recovering: recovering,
      roomExists: room != null,
      roomHasActiveCall: room != null && matrix.roomHasActiveCall(room),
    );
    _start = recoveredStartedAt ?? DateTime.now();
    _callAnswered = orexNextAnsweredState(
      alreadyAnswered: false,
      answerAccepted: initialAnswered,
      mediaConnected: false,
    );
    final cameraInitiallyOn = initialCameraOn ?? video;
    final audioInitiallyEnabled = initialAudioEnabled ?? true;
    final mediaKeyProvider = matrix.voip?.e2eeKeyProvider;
    final mediaKeySession = mediaKeyProvider?.prepareSession();
    final s = CallSession(
      client: matrix.client,
      matrixRoomId: roomId,
      initialMicOn: canSpeak && micInitiallyOn,
      initialSpeakerMuted: !audioInitiallyEnabled,
      canUseMic: canSpeak,
      listenOnly: listenOnly,
      canUseMicNow: () => _canUseMicNowFor(roomId),
      audioInputDeviceIdProvider: () => matrix.audio.inputDeviceId,
      audioOutputDeviceIdProvider: () => matrix.audio.outputDeviceId,
      videoInputDeviceIdProvider: () => matrix.audio.cameraDeviceId,
      cameraDeviceIdSink: (deviceId) =>
          matrix.audio.setCameraDeviceId(deviceId),
      speakingThresholdDbProvider: () => matrix.audio.speakingThresholdDb,
      speakingThresholdEnabledProvider: () =>
          matrix.audio.speakingThresholdEnabled,
      callMicPreferenceSink: (enabled) =>
          matrix.audio.setCallMicEnabled(enabled),
      e2eeKeyProvider: mediaKeySession,
      attachE2eeRoom: mediaKeyProvider?.attachLiveKitRoom,
      detachE2eeRoom: mediaKeyProvider?.detachLiveKitRoom,
      refreshE2eeKeys:
          (expectedRemoteParticipants, forceRemoteParticipantIds) async {
            await matrix.voip?.ensureActiveCallEncryptionKeys(
              expectedRemoteParticipants: expectedRemoteParticipants,
              forceRemoteParticipantIds: forceRemoteParticipantIds,
              // A temporary Matrix /sync or DNS outage must not hold a working
              // LiveKit transport in the initial CONNECTING state for many seconds.
              // CallSession retries this best-effort; encrypted frames remain
              // blocked by the key provider until the keys are actually present.
              timeout: const Duration(milliseconds: 1200),
              maxAttempts: 1,
            );
          },
      adaptiveStream: !_isPersonalCall(room),
      remoteReactionCue: matrix.audio.playReaction,
    );
    focusedParticipantIdentity = null;
    _session = s;
    s.addListener(_onSessionChanged);
    notifyListeners();
    onSessionCreated?.call();

    // Claim foreground execution before signaling/Telecom/network waits. A
    // user may background the app while the call is still connecting; delaying
    // the service until after MatrixRTC enter() would make that race depend on
    // Android's background-start exemptions. Any start failure below rolls this
    // owner back through _failStart().
    try {
      await orexRunCallStage<void>(
        stage: 'foreground-owner',
        timeout: const Duration(seconds: 8),
        operation: () => _syncForegroundCall(force: true),
      );
    } on OrexCallStageTimeout catch (e) {
      OrexLog.d('Call', 'foreground call owner timed out room=$roomId', e);
    }
    if (wasCancelled() || generation != _lifecycleGeneration || _session != s) {
      await _stopForegroundCall(
        OrexCallInstance(roomId: roomId, ringEventId: _currentRingEventId),
      );
      await s.hangUp();
      s.dispose();
      mediaKeyProvider?.discardPreparedSession(mediaKeySession);
      return;
    }

    // Сигналинг (membership) — чтобы у собеседника зазвонило. Если он
    // не прошёл, медиа не подключаем: иначе можно получить локальный фантомный
    // звонок и зависшее состояние MatrixRTC.
    final voip = matrix.voip;
    if (voip == null) {
      OrexLog.d('Call', 'signaling unavailable room=$roomId');
      mediaKeyProvider?.discardPreparedSession(mediaKeySession);
      await _failStart(
        s,
        'Звонки сейчас недоступны: MatrixRTC signaling не запущен',
      );
      return;
    }
    _setSetupPhase(OrexCallSetupPhase.signaling);
    try {
      await orexRunCallStage<GroupCallSession>(
        stage: 'matrixrtc-signaling',
        timeout: const Duration(seconds: 25),
        operation: () => voip.enterCall(
        roomId,
        owner: s,
        ring: _initiator,
        video: video,
        expectedRingEventId: ringEventId,
        ),
      );
      _currentRingEventId = voip.activeRingEventId(roomId) ?? ringEventId;
      final signalingInstance = OrexCallInstance(
        roomId: roomId,
        ringEventId: _currentRingEventId,
      );
      // The first explicit Matrix ring id may only become known after enter().
      // Promote the native foreground descriptor to the strong identity before
      // any further asynchronous work can observe it as a second call.
      await _syncForegroundCall(force: true);
      if (!wasCancelled() &&
          generation == _lifecycleGeneration &&
          _session == s) {
        onSignalingReady?.call(signalingInstance);
      }
    } catch (e) {
      mediaKeyProvider?.discardPreparedSession(mediaKeySession);
      if (wasCancelled() ||
          generation != _lifecycleGeneration ||
          _session != s) {
        return;
      }
      OrexLog.d('Call', 'signaling failed room=$roomId', e);
      final message = orexIsMatrixRateLimitError(e)
          ? 'Сервер временно ограничил запросы. '
                'Повторите звонок через несколько секунд.'
          : 'Не удалось запустить сигналинг звонка';
      await _failStart(s, message, leaveSignaling: true);
      return;
    }
    if (wasCancelled() || generation != _lifecycleGeneration || _session != s) {
      await _stopForegroundCall(
        OrexCallInstance(roomId: roomId, ringEventId: _currentRingEventId),
      );
      await _tearDownStaleStart(voip, s);
      return;
    }
    if (_initiator && room != null && _isSystemCallEligible(room)) {
      _scheduleUnansweredTimeout(s, roomId);
    }

    _setSetupPhase(OrexCallSetupPhase.systemIntegration);
    var systemRegistered = systemCallPrepared == true;
    final systemInstance = OrexCallInstance(
      roomId: roomId,
      ringEventId: _currentRingEventId,
    );
    if (_isSystemCallEligible(room) && systemCallPrepared != false) {
      _systemCallVideo = video;
      if (!systemRegistered) {
        if (!_sameCallInstance(_systemCallInstance, systemInstance)) {
          _systemCallInstance = systemInstance;
          _systemMutedByTelecom = false;
          _systemActiveByTelecom = true;
          _lastSystemMicEnabled = null;
          _lastSystemAudioEnabled = null;
          _lastSystemCameraEnabled = null;
        }
        final systemRegistration = systemIncoming
            ? _systemCalls.reportIncomingCall(
                callId: roomId,
                ringEventId: systemInstance.ringEventId,
                displayName: room!.getLocalizedDisplayname(),
                video: video,
                avatarCacheKey: _conversationAvatarCacheKey(room),
                startedAt: _start,
                micEnabled: canSpeak && micInitiallyOn,
                audioEnabled: audioInitiallyEnabled,
                cameraEnabled: cameraInitiallyOn,
              )
            : _systemCalls.reportOutgoingCall(
                callId: roomId,
                ringEventId: systemInstance.ringEventId,
                displayName: room!.getLocalizedDisplayname(),
                video: video,
                avatarCacheKey: _conversationAvatarCacheKey(room),
                startedAt: _start,
                micEnabled: canSpeak && micInitiallyOn,
                audioEnabled: audioInitiallyEnabled,
                cameraEnabled: cameraInitiallyOn,
              );
        try {
          systemRegistered = await orexRunCallStage<bool>(
            stage: 'system-call-registration',
            timeout: const Duration(seconds: 12),
            operation: () => systemRegistration,
          );
        } on OrexCallStageTimeout catch (e) {
          OrexLog.d(
            'Call',
            'system call registration timed out room=$roomId',
            e,
          );
          systemRegistered = false;
          if (_sameCallInstance(_systemCallInstance, systemInstance)) {
            _clearSystemCallState();
          }
          unawaited(
            systemRegistration.then((registered) async {
              if (registered &&
                  !_sameCallInstance(_systemCallInstance, systemInstance)) {
                await _systemCalls.endCall(
                  roomId,
                  ringEventId: systemInstance.ringEventId,
                  reason: 'error',
                );
              }
            }),
          );
        }
        if (!systemRegistered &&
            _sameCallInstance(_systemCallInstance, systemInstance)) {
          _clearSystemCallState();
        }
      }
      if (systemRegistered) {
        _systemCallInstance = systemInstance;
        _refreshSystemCallAvatar(
          room!,
          instance: systemInstance,
          video: video,
          incoming: systemIncoming,
        );
      }
    }

    // Регистрация в Android Telecom может занять несколько секунд. За это
    // время пользователь уже мог завершить звонок или открыть другой — тогда
    // запрещаем запоздалой операции оживлять старую медиа-сессию.
    if (wasCancelled() || generation != _lifecycleGeneration || _session != s) {
      if (systemRegistered &&
          _sameCallInstance(_systemCallInstance, systemInstance)) {
        await _systemCalls.endCall(
          roomId,
          ringEventId: systemInstance.ringEventId,
        );
        _clearSystemCallState();
      }
      await _stopForegroundCall(systemInstance);
      await _tearDownStaleStart(voip, s);
      return;
    }

    // Core-Telecom must be the only Android route owner while a registered
    // self-managed call is active. LiveKit otherwise applies its own Android
    // audio-session route policy (speaker-preferred by default), which races
    // requestEndpointChange() and can immediately undo earpiece selection.
    if (systemRegistered) {
      await _setAndroidTelecomAudioPolicy(true);
      if (wasCancelled() ||
          generation != _lifecycleGeneration ||
          _session != s) {
        if (_sameCallInstance(_systemCallInstance, systemInstance)) {
          await _systemCalls.endCall(
            roomId,
            ringEventId: systemInstance.ringEventId,
          );
          _clearSystemCallState();
        }
        await _setAndroidTelecomAudioPolicy(false);
        await _stopForegroundCall(systemInstance);
        await _tearDownStaleStart(voip, s);
        return;
      }
    }

    _setSetupPhase(OrexCallSetupPhase.media);
    try {
      await orexRunCallStage<void>(
        stage: 'livekit-media',
        timeout: const Duration(seconds: 30),
        operation: () => s.connect(
          video: cameraInitiallyOn,
          deferReady: true,
        ),
      );
    } on OrexCallStageTimeout catch (e) {
      OrexLog.d('Call', 'media connect timed out room=$roomId', e);
      await _failStart(
        s,
        'Не удалось подключить медиа за отведённое время',
        leaveSignaling: true,
      );
      return;
    }
    if (wasCancelled() || generation != _lifecycleGeneration || _session != s) {
      await _stopForegroundCall(systemInstance);
      await _tearDownStaleStart(voip, s);
      return;
    }
    if (s.status == CallStatus.failed || !s.mediaTransportConnected) {
      final message = s.error?.trim().isNotEmpty == true
          ? s.error!.trim()
          : 'Не удалось подключиться к медиа звонка';
      OrexLog.d(
        'Call',
        'media connect failed room=$roomId status=${s.status} error=$message',
      );
      await _failStart(s, message, leaveSignaling: true);
      return;
    }

    if (systemRegistered &&
        _sameCallInstance(_systemCallInstance, systemInstance)) {
      await s.setSystemMuted(_systemMutedByTelecom);
      await s.setSystemActive(_systemActiveByTelecom);
      if (_systemActiveByTelecom) {
        await _systemCalls.setActive(
          roomId,
          ringEventId: systemInstance.ringEventId,
        );
      }
      await _syncSystemCallControls();
    } else {
      // Do not start a second Android media player after Telecom activation:
      // audioplayers owns a separate native audio context and can overwrite the
      // call mode/speaker route immediately after requestEndpointChange().
      await matrix.audio.playVoiceJoin();
    }

    if (wasCancelled() || generation != _lifecycleGeneration || _session != s) {
      await _tearDownStaleStart(voip, s);
      return;
    }
    bool mediaReady;
    try {
      mediaReady = await orexRunCallStage<bool>(
        stage: 'media-readiness',
        timeout: const Duration(seconds: 12),
        operation: s.markReady,
      );
    } on OrexCallStageTimeout catch (e) {
      OrexLog.d('Call', 'media readiness timed out room=$roomId', e);
      await _failStart(
        s,
        'Не удалось завершить защищённое подключение вовремя',
        leaveSignaling: true,
      );
      return;
    }
    if (wasCancelled() || generation != _lifecycleGeneration || _session != s) {
      await _tearDownStaleStart(voip, s);
      return;
    }
    if (!mediaReady) {
      await _failStart(
        s,
        'Не удалось завершить подключение к медиа звонка',
        leaveSignaling: true,
      );
      return;
    }
    _setSetupPhase(OrexCallSetupPhase.ready);
    final deferredRecovery = _deferredInitialMediaRecovery;
    _deferredInitialMediaRecovery = null;
    if (deferredRecovery != null && identical(_session, s)) {
      await s.recoverAfterBackground(deferredRecovery);
    }
    if ((systemIncoming || recovering) && cameraInitiallyOn) {
      await s.recoverCameraAfterColdAnswer();
    }
  }

  Future<void> _tearDownStaleStart(
    VoipService voip,
    CallSession session,
  ) async {
    final cleanup = (() async {
      try {
        await Future.wait<void>([
          session.hangUp(),
          voip.leaveCurrent(
            owner: session,
            preparedKeyProvider: session.e2eeKeyProvider,
            mediaOperationsDrained: session.mediaOperationsFullyDrained,
          ),
        ]);
      } finally {
        session.dispose();
      }
    })();
    try {
      await cleanup.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      OrexLog.d(
        'Call',
        'stale call cleanup continues asynchronously room=${session.matrixRoomId}',
      );
      unawaited(cleanup);
    }
  }

  Future<void> _failStart(
    CallSession session,
    String message, {
    bool leaveSignaling = false,
  }) async {
    if (!identical(_session, session)) {
      final voip = matrix.voip;
      if (voip != null) {
        await _tearDownStaleStart(voip, session);
      } else {
        await session.hangUp();
        session.dispose();
      }
      return;
    }
    _cancelUnansweredTimeout();
    lastError = message;
    final failedInstance = OrexCallInstance(
      roomId: session.matrixRoomId,
      ringEventId: _currentRingEventId,
    );
    final failedSystemCall = _systemCallInstance;
    final failedRoom = matrix.client.getRoomById(session.matrixRoomId);
    final shouldNotifyEnded =
        failedRoom != null && _shouldSendEndedSignal(failedRoom, session);

    // Release presentation ownership before any network/native teardown. The
    // cleanup may be delayed by an offline homeserver or plugin, but the user
    // must never remain trapped on "Подключаем звонок...".
    session.removeListener(_onSessionChanged);
    _session = null;
    minimized = false;
    roomId = null;
    _currentRingEventId = null;
    video = false;
    listenOnly = false;
    _initiator = false;
    _start = null;
    _callAnswered = false;
    setupPhase = OrexCallSetupPhase.idle;
    _deferredInitialMediaRecovery = null;
    if (_sameCallInstance(_pendingAcceptedIncomingCallUi, failedInstance)) {
      _pendingAcceptedIncomingCallUi = null;
    }
    focusedParticipantIdentity = null;
    _clearSystemCallState();
    _lifecycleGeneration++;
    if (!_disposed) notifyListeners();

    // Start native ownership release immediately; Matrix/media teardown may be
    // slow or permanently stalled while the device is offline.
    final foregroundStop = _stopForegroundCall(failedInstance);
    final systemEnd = failedSystemCall == null
        ? null
        : _systemCalls.endCall(
            failedSystemCall.roomId,
            ringEventId: failedSystemCall.ringEventId,
            reason: 'error',
          );

    final mediaTeardown = session.hangUp();
    final signalingTeardown = leaveSignaling
        ? matrix.voip?.leaveCurrent(
            owner: session,
            preparedKeyProvider: session.e2eeKeyProvider,
            mediaOperationsDrained: session.mediaOperationsFullyDrained,
          )
        : null;
    try {
      await matrix.push
          .notifyCallEnded(
            session.matrixRoomId,
            ringEventId: failedInstance.ringEventId,
          )
          .timeout(const Duration(seconds: 4));
    } catch (e) {
      OrexLog.d('Call', 'failed to persist start rollback', e);
    }
    if (shouldNotifyEnded) {
      unawaited(matrix.voip?.notifyEnded(failedInstance));
    }

    final cleanup = (() async {
      try {
        await Future.wait<void>([mediaTeardown, ?signalingTeardown]);
      } catch (error) {
        OrexLog.d('Call', 'leave failed after start rollback', error);
      }
    })().whenComplete(session.dispose);
    try {
      await cleanup.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      OrexLog.d(
        'Call',
        'start rollback continues in background room=${session.matrixRoomId}',
      );
      unawaited(cleanup);
    }

    await foregroundStop.timeout(
      const Duration(seconds: 4),
      onTimeout: () {},
    );
    if (systemEnd != null) {
      await systemEnd.timeout(
        const Duration(seconds: 4),
        onTimeout: () => false,
      );
    }
    await _setAndroidTelecomAudioPolicy(false);
  }

  void minimize() {
    if (_disposed) return;
    if (_session == null && _startOperation == null) return;
    minimized = true;
    notifyListeners();
  }

  void expand() {
    if (_disposed) return;
    minimized = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> hangUp({
    bool fromSystem = false,
    bool fromRemote = false,
    bool cancelPendingStarts = true,
  }) {
    if (cancelPendingStarts) _startCancellationGeneration++;
    final pending = _hangUpOperation;
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _hangUpInternal(fromSystem: fromSystem, fromRemote: fromRemote)
        .whenComplete(() {
          if (identical(_hangUpOperation, operation)) _hangUpOperation = null;
        });
    _hangUpOperation = operation;
    return operation;
  }

  Future<void> _hangUpInternal({
    required bool fromSystem,
    required bool fromRemote,
  }) async {
    _lifecycleGeneration++;
    _cancelUnansweredTimeout();
    final s = _session;
    final rid = roomId;
    final callInstance = rid == null
        ? null
        : OrexCallInstance(roomId: rid, ringEventId: _currentRingEventId);
    final room = rid == null ? null : matrix.client.getRoomById(rid);
    final systemCallInstance = _systemCallInstance;
    final initiator = _initiator;
    final start = _start;
    final sawRemote = s?.sawRemote ?? false;
    final shouldSendEndedSignal =
        !fromRemote && room != null && _shouldSendEndedSignal(room, s);
    final shouldPostSummary =
        initiator && rid != null && (fromRemote || shouldSendEndedSignal);
    Future<void>? remoteEndSync;
    if (shouldSendEndedSignal && callInstance != null) {
      remoteEndSync = matrix.voip
          ?.notifyEnded(callInstance)
          .timeout(const Duration(seconds: 4), onTimeout: () {});
    }
    _session = null;
    minimized = false;
    roomId = null;
    _currentRingEventId = null;
    video = false;
    listenOnly = false;
    _initiator = false;
    _start = null;
    _callAnswered = false;
    setupPhase = OrexCallSetupPhase.idle;
    _deferredInitialMediaRecovery = null;
    if (_sameCallInstance(_pendingAcceptedIncomingCallUi, callInstance)) {
      _pendingAcceptedIncomingCallUi = null;
    }
    focusedParticipantIdentity = null;
    _clearSystemCallState();
    s?.removeListener(_onSessionChanged);
    // Start native Room teardown before the first network await below. Any
    // stale start continuation then observes the same idempotent barrier and
    // cannot release the E2EE provider while LiveKit still uses it.
    final mediaTeardown = s?.hangUp();
    final leaveSignaling = s == null
        ? null
        : matrix.voip?.leaveCurrent(
            owner: s,
            preparedKeyProvider: s.e2eeKeyProvider,
            mediaOperationsDrained: s.mediaOperationsFullyDrained,
          );
    if (rid != null) {
      try {
        await matrix.push.notifyCallEnded(
          rid,
          ringEventId: callInstance?.ringEventId,
        );
      } catch (e) {
        OrexLog.d('Call', 'failed to persist call hangup', e);
      }
    }
    if (!_disposed) notifyListeners();
    if (s != null && mediaTeardown != null) {
      try {
        await Future.wait<void>([mediaTeardown, ?leaveSignaling]);
      } catch (e) {
        OrexLog.d('Call', 'call teardown failed', e);
      } finally {
        s.dispose();
      }
    } else if (leaveSignaling != null) {
      await leaveSignaling;
    }
    if (remoteEndSync != null) {
      try {
        await remoteEndSync;
      } catch (e) {
        OrexLog.d('Call', 'remote ended sync failed', e);
      }
    }
    if (!fromSystem && systemCallInstance != null) {
      await _systemCalls.endCall(
        systemCallInstance.roomId,
        ringEventId: systemCallInstance.ringEventId,
      );
    }
    await _stopForegroundCall(callInstance);
    await _setAndroidTelecomAudioPolicy(false);
    if (callInstance != null) {
      await _systemCalls.clearRecoverableCall(
        callInstance.roomId,
        ringEventId: callInstance.ringEventId,
      );
    }
    // Итоговое сообщение о звонке постит ТОЛЬКО инициатор — без дублей.
    // Если пользователь лишь временно вышел из уже подключённого личного
    // звонка, summary не публикуем: в комнате всё ещё может ждать собеседник.
    if (shouldPostSummary) {
      await _postCallSummary(rid, sawRemote, start);
    }
  }

  void _clearSystemCallState() {
    _systemCallInstance = null;
    _systemCallVideo = false;
    _systemMutedByTelecom = false;
    _systemActiveByTelecom = true;
    _lastSystemMicEnabled = null;
    _lastSystemAudioEnabled = null;
    _lastSystemCameraEnabled = null;
  }

  Future<void> _postCallSummary(
    String roomId,
    bool answered,
    DateTime? start,
  ) async {
    final room = matrix.client.getRoomById(roomId);
    if (room == null || matrix.roomKind(room) == OrexRoomKind.channel) return;
    String outcome;
    String text;
    if (answered) {
      outcome = 'answered';
      final secs = start != null
          ? DateTime.now().difference(start).inSeconds
          : 0;
      text = secs > 0 ? '📞 Звонок · ${_fmtDur(secs)}' : '📞 Звонок';
    } else if (matrix.voip?.wasBusy(roomId) ?? false) {
      outcome = 'busy';
      text = '📞 Абонент занят';
    } else if (matrix.voip?.wasRejected(roomId) ?? false) {
      outcome = 'rejected';
      text = '📞 Отклонённый вызов';
    } else {
      outcome = 'missed';
      text = '📞 Пропущенный вызов';
    }
    matrix.voip?.clearBusy(roomId);
    matrix.voip?.clearRejected(roomId);
    try {
      await room.sendEvent({
        'msgtype': 'm.notice',
        'body': text,
        'com.orex.call_outcome': outcome,
      });
    } catch (e) {
      OrexLog.d('Call', 'post call summary failed room=$roomId', e);
    }
  }

  String _fmtDur(int secs) {
    final m = secs ~/ 60;
    final s = secs % 60;
    return m > 0 ? '$m мин ${s.toString().padLeft(2, '0')} с' : '$s с';
  }

  @override
  void dispose() {
    _disposed = true;
    _lifecycleGeneration++;
    _incomingAcceptGeneration++;
    _startCancellationGeneration++;
    _cancelUnansweredTimeout();
    matrix.audio.removeListener(_onAudioSettingsChanged);
    final systemCallInstance = _systemCallInstance;
    if (systemCallInstance != null) {
      unawaited(
        _systemCalls.endCall(
          systemCallInstance.roomId,
          ringEventId: systemCallInstance.ringEventId,
          reason: 'local',
        ),
      );
    }
    unawaited(_stopForegroundCall(currentCallInstance));
    unawaited(_setAndroidTelecomAudioPolicy(false));
    _clearSystemCallState();
    _systemCalls.clearActionHandler(this);
    _incomingDismissSub?.cancel();
    _remoteAcceptedSub?.cancel();
    _remoteTerminationSub?.cancel();
    _instancePromotionSub?.cancel();
    _systemIncomingAccepted.close();
    _systemAnswerInProgress = null;
    _systemTerminationInProgress = null;
    final session = _session;
    _session = null;
    roomId = null;
    session?.removeListener(_onSessionChanged);
    final mediaTeardown = session?.hangUp();
    final signalingTeardown = session == null
        ? null
        : matrix.voip?.leaveCurrent(
            owner: session,
            preparedKeyProvider: session.e2eeKeyProvider,
            mediaOperationsDrained: session.mediaOperationsFullyDrained,
          );
    final teardown = <Future<void>>[
      ?_startOperation,
      ?_hangUpOperation,
      ?mediaTeardown,
      ?signalingTeardown,
    ];
    _shutdownComplete = Future.wait<void>(
      teardown.map(
        (operation) => operation.catchError((Object error, StackTrace _) {
          OrexLog.d('Call', 'controller shutdown cleanup failed', error);
        }),
      ),
    ).whenComplete(() => session?.dispose());
    super.dispose();
  }
}

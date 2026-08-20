part of 'call_controller.dart';

/// Heavy start/accept/failure paths stay in the CallController library while
/// the controller file keeps the state model and public lifecycle surface.
extension _CallControllerStartFlow on CallController {
  Future<void> _acceptIncomingImplBody(
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

    OrexLog.d(
      'Call',
      'incoming accept entered room=${instance.roomId} '
          'ring=${instance.ringEventId}',
    );
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
    final acceptedUiHandoff = OrexAcceptedCallUiHandoff(
      enabled: shouldRequestExpandedUi,
      acceptedRoomId: acceptedInstance.roomId,
      currentInstance: () => currentCallInstance,
      requestUi: _requestAcceptedIncomingCallUi,
    );

    // Do not latch the one-shot UI handoff before [start]: at this point
    // [currentCallInstance] still has no local room identity, so the root
    // would correctly discard the request and the later session callback
    // would be suppressed. [onSessionCreated] below runs as soon as the local
    // session exists, while media is still connecting.
    OrexLog.d(
      'Call',
      'incoming accept starting local session room=${acceptedInstance.roomId} '
          'ring=${acceptedInstance.ringEventId}',
    );
    final mediaStart = start(
      room.id,
      video: video,
      systemIncoming: true,
      systemCallPrepared: registered,
      initialAnswered: true,
      ringEventId: acceptedInstance.ringEventId,
      onSessionCreated: acceptedUiHandoff.requestIfReady,
      onSignalingReady: publishAccepted,
    );
    await mediaStart;
    // Fallback for an implementation that completed without invoking the
    // session callback. Normal mobile flow requests the expanded route much
    // earlier, while CallSession is still CONNECTING.
    acceptedUiHandoff.requestIfReady();
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

  Future<void> _startInternalBody(
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
    _notifyFlowListeners();
    OrexLog.d(
      'Call',
      'local CallSession created room=$roomId ring=$ringEventId',
    );
    onSessionCreated?.call();

    // Claim foreground execution before signaling/Telecom/network waits. A
    // user may background the app while the call is still connecting; delaying
    // the service until after MatrixRTC enter() would make that race depend on
    // Android's background-start exemptions. Any start failure below rolls this
    // owner back through _failStart().
    try {
      final foregroundOwned = await orexRunCallStage<bool>(
        stage: 'foreground-owner',
        timeout: const Duration(seconds: 8),
        operation: () => _applyForegroundCall(force: true),
      );
      if (!foregroundOwned) {
        mediaKeyProvider?.discardPreparedSession(mediaKeySession);
        await _failStart(
          s,
          'Не удалось запустить звонок. Повторите попытку.',
        );
        return;
      }
    } on OrexCallStageTimeout catch (e) {
      OrexLog.d('Call', 'foreground call owner timed out room=$roomId', e);
      mediaKeyProvider?.discardPreparedSession(mediaKeySession);
      await _failStart(
        s,
        'Запуск звонка занял слишком много времени. Повторите попытку.',
      );
      return;
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

  Future<void> _failStartBody(
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
    if (!_disposed) _notifyFlowListeners();

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

}

part of 'voip_service.dart';

extension _VoipServiceMembershipFlow on VoipService {
  Future<void> _cleanupStaleRoomStateBody(
    Room room, {
    required String operationName,
    _StaleMembershipCleanupScope? staleMembershipCleanupScope,
  }) async {
    bool canContinue() =>
        staleMembershipCleanupScope == null ||
        _isStaleMembershipCleanupCurrent(staleMembershipCleanupScope);
    if (!canContinue()) return;
    final userId = staleMembershipCleanupScope?.userId ?? client.userID;
    final deviceId = staleMembershipCleanupScope?.deviceId ?? client.deviceID;
    if (userId == null ||
        userId.isEmpty ||
        deviceId == null ||
        deviceId.isEmpty) {
      return;
    }
    final protectedCallIds = <String>{
      if (active?.room.id == room.id) active!.groupCallId,
      if (_keyShareState?.groupCall.room.id == room.id)
        _keyShareState!.groupCall.groupCallId,
      if (_enterRequestRoomId == room.id &&
          _enterRequestRingEventId != null &&
          _enterRequestRingEventId!.isNotEmpty)
        _enterRequestRingEventId!,
    };

    final localMembershipCallIds = room
        .getCallMembershipsForUser(userId, deviceId, voip)
        .where(
          (membership) =>
              !membership.isExpired &&
              !protectedCallIds.contains(membership.callId),
        )
        .map((membership) => membership.callId)
        .toSet();
    final staleSessions = voip.groupCalls.values
        .where(
          (gc) =>
              gc.room.id == room.id &&
              !identical(gc, active) &&
              !identical(gc, _keyShareState?.groupCall) &&
              !protectedCallIds.contains(gc.groupCallId) &&
              (localMembershipCallIds.contains(gc.groupCallId) ||
                  (gc.state != GroupCallState.localCallFeedUninitialized &&
                      gc.state != GroupCallState.localCallFeedInitialized &&
                      gc.state != GroupCallState.ended)),
        )
        .toList(growable: false);
    final callIdsWithoutSession = <String>{...localMembershipCallIds}
      ..removeAll(staleSessions.map((gc) => gc.groupCallId));
    if (staleSessions.isEmpty && callIdsWithoutSession.isEmpty) return;

    var allRemoved = true;
    for (final gc in staleSessions) {
      if (!canContinue()) return;
      // All paths that touch the same SDK session share one cleanup tail. The
      // first-call hangup and a second-call preflight can therefore never run
      // two leave/dispose sequences against one GroupCallSession concurrently.
      final cleanup = _queueGroupCallCleanup(
        gc,
        operationName: '$operationName-stale-session',
        staleMembershipCleanupScope: staleMembershipCleanupScope,
      );
      try {
        await cleanup.timeout(const Duration(seconds: 10));
      } on TimeoutException catch (error) {
        allRemoved = false;
        OrexLog.d(
          'Voip',
          'stale SDK cleanup continues asynchronously room=${room.id} '
              'call=${gc.groupCallId}',
          error,
        );
      } catch (error) {
        allRemoved = false;
        OrexLog.d(
          'Voip',
          'stale SDK cleanup failed room=${room.id} call=${gc.groupCallId}',
          error,
        );
      }
    }

    // A process restart can leave a Matrix membership without a live SDK
    // object. Remove only those exact generations; never use room.id as a
    // wildcard because a replacement call may already be publishing its own
    // generation in the same room.
    for (final callId in callIdsWithoutSession) {
      if (!canContinue()) return;
      try {
        await OrexMatrixRequestGate.shared.run<void>(
          operationName: '$operationName-orphan-membership-cleanup',
          coalesceKey: 'membership-cleanup:${room.id}:$callId',
          maxAttempts: 1,
          operationTimeout: const Duration(seconds: 8),
          operation: () async {
            if (!canContinue()) return;
            await room.removeFamedlyCallMemberEvent(callId, voip);
          },
        );
      } catch (error) {
        allRemoved = false;
        OrexLog.d(
          'Voip',
          'orphan membership cleanup deferred room=${room.id} call=$callId',
          error,
        );
      }
    }

    if (!canContinue()) return;
    if (allRemoved) {
      _pendingMembershipCleanupRooms.remove(room.id);
      OrexLog.d('Voip', 'removed phantom call membership room=${room.id}');
    } else {
      _pendingMembershipCleanupRooms.add(room.id);
      OrexLog.d('Voip', 'cleanup stale membership deferred room=${room.id}');
    }
  }

  Future<void> _ensureActiveCallEncryptionKeysBody({
    required int expectedRemoteParticipants,
    Set<String> forceRemoteParticipantIds = const <String>{},
    Duration timeout = const Duration(seconds: 3),
    int maxAttempts = 4,
  }) async {
    final groupCall = active;
    if (groupCall == null) return;
    final state = _keyShareState;
    if (state == null || !identical(state.groupCall, groupCall)) return;

    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      var completed = false;
      try {
        await state.run(() async {
          await groupCall.onMemberStateChanged();
          if (!state.active ||
              !identical(_keyShareState, state) ||
              !identical(active, groupCall)) {
            return;
          }

          final participants = groupCall.participants.toList(growable: false);
          final localParticipant = groupCall.localParticipant;
          if (localParticipant == null) {
            throw StateError(
              'MatrixRTC local participant is not ready for media encryption',
            );
          }
          final remoteParticipants = participants
              .where((participant) => !participant.isLocal)
              .toList(growable: false);
          final remoteById = <String, CallParticipant>{
            for (final participant in remoteParticipants)
              participant.id: participant,
          };

          // On a cold answer, LiveKit can already have a remote track while
          // `/sync` has not hydrated its `m.call.member` into
          // [groupCall.participants]. Verify the SFU identity against direct
          // room state before using it for either sender-key replay or a key
          // request; never share a key to an unverified identity.
          if (groupCall.backend is OrexLiveKitBackend) {
            final backend = groupCall.backend as OrexLiveKitBackend;
            for (final identity in forceRemoteParticipantIds) {
              if (remoteById.containsKey(identity)) continue;
              final participant = await backend
                  .resolveActiveParticipantByIdentity(groupCall, identity);
              if (participant != null) {
                remoteById[participant.id] = participant;
              }
            }
          }
          final observedRemoteParticipants = remoteById.values.toList(
            growable: false,
          );
          final activeRemoteIds = remoteById.keys.toSet();
          final forcedIds = forceRemoteParticipantIds.intersection(
            activeRemoteIds,
          );
          await _shareLocalMediaKeyWithNewParticipants(
            state,
            observedRemoteParticipants,
            forceReplayParticipantIds: forcedIds,
          );
          if (!state.active || !identical(_keyShareState, state)) return;

          final knownRemoteMemberships = _callMembers(
            groupCall.room,
          ).where((userId) => userId != client.userID).length;
          final minimumRemoteParticipants =
              knownRemoteMemberships > expectedRemoteParticipants
              ? knownRemoteMemberships
              : expectedRemoteParticipants;
          if (observedRemoteParticipants.length < minimumRemoteParticipants) {
            throw StateError(
              'MatrixRTC membership lag: expected $minimumRemoteParticipants '
              'remote participant(s), saw ${observedRemoteParticipants.length}',
            );
          }

          final localParticipants = <CallParticipant>[localParticipant];
          final missingLocal = localParticipants
              .where((participant) => !e2eeKeyProvider.hasKeyFor(participant))
              .toList(growable: false);
          final missingRemote = observedRemoteParticipants
              .where((participant) => !e2eeKeyProvider.hasKeyFor(participant))
              .toList(growable: false);
          final forcedRemote = observedRemoteParticipants
              .where((participant) => forcedIds.contains(participant.id))
              .toList(growable: false);
          final forcedRevisions = <String, int>{
            for (final participant in forcedRemote)
              participant.id: e2eeKeyProvider.keyRevisionFor(participant.id),
          };
          final missing = <CallParticipant>[...missingLocal, ...missingRemote];
          if (missing.isEmpty && forcedRemote.isEmpty) {
            completed = true;
            return;
          }

          final requestParticipants = <CallParticipant>{
            ...missingRemote,
            ...forcedRemote,
          }.toList(growable: false);
          if (requestParticipants.isNotEmpty) {
            await groupCall.backend.requestEncrytionKey(
              groupCall,
              requestParticipants,
            );
          }
          final readiness = await Future.wait<bool>([
            e2eeKeyProvider.waitForKeys(missing, timeout: timeout),
            e2eeKeyProvider.waitForKeyUpdates(
              forcedRevisions,
              timeout: timeout,
            ),
          ]);
          if (readiness.every((ready) => ready)) {
            completed = true;
            return;
          }
          throw StateError(
            'Timed out waiting for ${missingLocal.length} local and '
            '${missingRemote.length} remote MatrixRTC media key(s); '
            '${forcedRemote.length} forced refresh(es)',
          );
        });
        if (!state.active || !identical(_keyShareState, state)) return;
        if (completed) return;
      } catch (error) {
        lastError = error;
      }

      if (attempt + 1 < maxAttempts) {
        await Future<void>.delayed(Duration(milliseconds: 350 * (attempt + 1)));
      }
    }

    OrexLog.d(
      'Voip',
      'MatrixRTC media key refresh failed room=${groupCall.room.id}',
      lastError,
    );
    throw StateError('Не удалось получить ключи защищённого медиапотока');
  }

  Future<GroupCallSession> _enterCallSerializedBody(
    String roomId, {
    required Object owner,
    required bool ring,
    required bool video,
    required String? expectedRingEventId,
    required int enterGeneration,
  }) async {
    final room = client.getRoomById(roomId);
    if (room == null) {
      throw StateError('Комната $roomId не найдена');
    }
    if (!orexCanEnterCallRoom(
      roomEncrypted: room.encrypted,
      allowUnencryptedCalls: OrexConfig.allowUnencryptedCalls,
    )) {
      throw StateError(
        'Звонок заблокирован: Matrix-комната не защищена сквозным шифрованием',
      );
    }

    final incomingRingEventId = ring ? null : expectedRingEventId;
    if (!ring &&
        _incomingRingEventIds.containsKey(roomId) &&
        !orexCallInstanceIdsMatch(
          _incomingRingEventIds[roomId],
          expectedRingEventId,
        )) {
      throw StateError('Incoming call attempt changed before MatrixRTC enter');
    }

    // A previous call must be locally detached and have its renewal timer
    // cancelled before a replacement call can publish membership.
    final staleCleanup = _cleanupStaleRoomState(
      room,
      operationName: 'pre-enter',
    );
    try {
      await staleCleanup.timeout(const Duration(seconds: 4));
    } on TimeoutException catch (error) {
      // _cleanupStaleRoomState detaches SDK ownership synchronously before its
      // remote writes. The old exact generation may finish deleting in the
      // background without being able to touch the new generation.
      OrexLog.d(
        'Voip',
        'pre-enter cleanup continues asynchronously room=$roomId',
        error,
      );
    }
    if (enterGeneration != _enterGeneration) {
      throw StateError('MatrixRTC call enter was cancelled');
    }

    _clearPersistedLeftCall(roomId);
    _dispositions.clearLegacy(roomId);
    _clearCallSuppression(roomId);

    String? outgoingRingEventId;
    var outgoingRingPending = false;
    if (ring && isPersonalCallRoom(room)) {
      _outgoingRingPendingRooms.add(room.id);
      outgoingRingPending = true;
      outgoingRingEventId = await _sendPersonalCallRing(room, video: video);
      if (outgoingRingEventId == null) {
        _outgoingRingPendingRooms.remove(room.id);
        throw StateError('Не удалось создать точную попытку звонка');
      }
      // The Matrix event id is the call generation. Sequential calls in one
      // room no longer share room.id as call_id, so a delayed cleanup from the
      // previous call cannot remove or renew the replacement membership.
      _enterRequestRingEventId = outgoingRingEventId;
      _promoteLegacyCallInstance(
        room.id,
        outgoingRingEventId,
        occurredAt: DateTime.now(),
      );
      _ringEventIds[room.id] = _OutgoingRing(outgoingRingEventId);
    }

    final groupCallId =
        outgoingRingEventId ??
        _resolveMatrixRtcCallId(room, expectedRingEventId: expectedRingEventId);
    OrexLog.d(
      'Voip',
      'MatrixRTC generation selected room=$roomId call=$groupCallId '
          'ring=${outgoingRingEventId ?? expectedRingEventId}',
    );

    voip.currentSessionId = client.generateUniqueTransactionId();
    final backend = OrexLiveKitBackend(
      livekitServiceUrl: OrexConfig.jwtServiceUri.toString(),
      livekitAlias: roomId,
      membershipEpoch: voip.currentSessionId,
      e2eeEnabled: true,
    );

    late GroupCallSession gc;
    try {
      gc = await voip.fetchOrCreateGroupCall(
        groupCallId,
        room,
        backend,
        'm.call',
        'm.room',
        preShareKey: false,
      );

      if (!identical(gc.backend, backend)) {
        if (gc.state != GroupCallState.localCallFeedUninitialized &&
            gc.state != GroupCallState.localCallFeedInitialized) {
          throw StateError(
            'Cannot replace an already-entered MatrixRTC backend for $roomId '
            'call=$groupCallId',
          );
        }
        gc = GroupCallSession(
          client: client,
          voip: voip,
          room: room,
          backend: backend,
          groupCallId: groupCallId,
          application: gc.application,
          scope: gc.scope,
        );
        voip.setGroupCallById(gc);
      }
    } catch (_) {
      // The backend has not been entered yet. There is no SDK session to
      // dispose here; constructing a synthetic GroupCallSession only to call
      // dispose can create a second, unrelated lifecycle. Cancel the exact
      // ring and let the prepared key provider be discarded by the caller.
      if (outgoingRingEventId != null) {
        _ringEventIds.remove(room.id);
        unawaited(_cancelSentRing(room, outgoingRingEventId, action: 'ended'));
      }
      if (outgoingRingPending) {
        _outgoingRingPendingRooms.remove(room.id);
        _deferredRemoteDispositions.remove(room.id);
      }
      rethrow;
    }

    if (enterGeneration != _enterGeneration) {
      _detachGroupCallSession(gc);
      unawaited(
        backend.dispose(gc).catchError((Object error, StackTrace _) {
          OrexLog.d(
            'Voip',
            'cancelled pre-enter backend cleanup failed room=$roomId '
                'call=${gc.groupCallId}',
            error,
          );
        }),
      );
      if (outgoingRingEventId != null) {
        _ringEventIds.remove(room.id);
        unawaited(_cancelSentRing(room, outgoingRingEventId, action: 'ended'));
      }
      if (outgoingRingPending) {
        _outgoingRingPendingRooms.remove(room.id);
        _deferredRemoteDispositions.remove(room.id);
      }
      throw StateError('MatrixRTC call enter was cancelled');
    }

    final keyState = _CallKeyShareState(gc, owner);
    _keyShareState?.invalidate();
    _keyShareState = keyState;
    var abandonedEnter = false;

    try {
      keyState.keyProviderLease = e2eeKeyProvider.activatePreparedSession();
      await backend.prepareLocalKey(gc).timeout(const Duration(seconds: 5));
      if (enterGeneration != _enterGeneration || !keyState.active) {
        throw StateError('MatrixRTC call enter was cancelled');
      }

      // Do not put GroupCallSession.enter() into the global Matrix write gate.
      // enter() is a compound SDK lifecycle Future (state write, participant
      // reconciliation, delegate callbacks). In +9 a stalled enter permanently
      // occupied the gate tail, so every later leave and membership cleanup was
      // queued behind it and timed out without even starting.
      final rawEnter = gc.enter();
      unawaited(
        rawEnter.then<void>((_) async {
          if (abandonedEnter ||
              enterGeneration != _enterGeneration ||
              !keyState.active) {
            await _queueGroupCallCleanup(
              gc,
              operationName: 'late-matrixrtc-enter',
              repeatAfterExisting: true,
            );
          }
        }, onError: (Object _, StackTrace _) {}),
      );
      await rawEnter.timeout(const Duration(seconds: 18));
      if (enterGeneration != _enterGeneration || !keyState.active) {
        throw StateError('MatrixRTC call enter was cancelled');
      }
    } catch (error) {
      abandonedEnter = true;
      keyState.invalidate();
      if (identical(_keyShareState, keyState)) _keyShareState = null;
      OrexLog.d(
        'Voip',
        'enter call failed room=$roomId call=${gc.groupCallId}',
        error,
      );
      unawaited(
        _queueGroupCallCleanup(
          gc,
          operationName: 'matrixrtc-enter-rollback',
        ).catchError((Object cleanupError, StackTrace _) {
          OrexLog.d(
            'Voip',
            'enter rollback failed room=$roomId call=${gc.groupCallId}',
            cleanupError,
          );
        }),
      );
      _releaseKeyProviderLease(keyState);
      if (outgoingRingEventId != null) {
        _ringEventIds.remove(room.id);
        unawaited(_cancelSentRing(room, outgoingRingEventId, action: 'ended'));
      }
      if (outgoingRingPending) {
        _outgoingRingPendingRooms.remove(room.id);
        _deferredRemoteDispositions.remove(room.id);
      }
      rethrow;
    }

    final resolvedRingEventId =
        outgoingRingEventId ??
        (identical(_enterRequestOwner, owner) && _enterRequestRoomId == roomId
            ? _enterRequestRingEventId
            : incomingRingEventId);
    active = gc;
    _activeOwner = owner;
    OrexLog.d(
      'Voip',
      'MatrixRTC generation entered room=$roomId call=${gc.groupCallId}',
    );
    _activeRingEventId = resolvedRingEventId;
    if (!ring) {
      _removeIncomingAttempt(
        OrexCallInstance(roomId: roomId, ringEventId: resolvedRingEventId),
      );
    }
    _notifyFlowListeners();

    try {
      try {
        await keyState
            .run(() async {
              await gc.onMemberStateChanged();
              if (!keyState.active || !identical(active, gc)) return;
              final remoteParticipants = gc.participants
                  .where((participant) => !participant.isLocal)
                  .toList(growable: false);
              await _shareLocalMediaKeyWithNewParticipants(
                keyState,
                remoteParticipants,
              );
            })
            .timeout(const Duration(seconds: 4));
      } catch (error) {
        OrexLog.d(
          'Voip',
          'initial media-key share deferred room=$roomId',
          error,
        );
      }

      if (enterGeneration != _enterGeneration ||
          !keyState.active ||
          !identical(active, gc)) {
        throw StateError('MatrixRTC call enter was cancelled');
      }
      return gc;
    } finally {
      if (outgoingRingPending) {
        _outgoingRingPendingRooms.remove(room.id);
        if (identical(active, gc) && keyState.active) {
          _drainDeferredRemoteDispositions(room.id);
        } else {
          _deferredRemoteDispositions.remove(room.id);
        }
      }
    }
  }

}

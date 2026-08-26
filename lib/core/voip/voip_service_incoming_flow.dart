part of 'voip_service.dart';

extension _VoipServiceIncomingFlow on VoipService {
  void _applyRemoteDispositionBody(_DeferredRemoteDisposition disposition) {
    if (_disposed) return;
    final validated = _validatedRemoteDisposition(disposition);
    if (validated == null) return;
    final instance = OrexCallInstance(
      roomId: validated.roomId,
      ringEventId: validated.ringEventId,
    );
    if (disposition.type == VoipService._handledEventType) {
      _tombstoneAndDismissCallAttempt(
        instance,
        occurredAt: disposition.occurredAt,
        // This is the original caller cancelling the outstanding ring UI after
        // receiving `accepted`. It must close stale/sibling presentations, but
        // must never invalidate the accepting device's in-flight MatrixRTC join.
        cancelsPendingAccept: false,
      );
      return;
    }
    if (disposition.type == VoipService._acceptedEventType) {
      if (validated.ringEventId != null) {
        _tombstoneAndDismissCallAttempt(
          instance,
          occurredAt: disposition.occurredAt,
        );
      }
      _remoteAccepted.add(
        OrexRemoteCallAccepted(
          roomId: validated.roomId,
          ringEventId: validated.ringEventId,
        ),
      );
      return;
    }
    if (disposition.type == VoipService._rejectedEventType) {
      _recordRejected(validated.roomId);
      _handleRemoteTermination(
        validated.roomId,
        OrexRemoteCallTerminationReason.rejected,
        occurredAt: disposition.occurredAt,
        ringEventId: validated.ringEventId,
      );
      return;
    }
    if (disposition.type == VoipService._busyEventType) {
      _recordBusy(validated.roomId);
      _handleRemoteTermination(
        validated.roomId,
        OrexRemoteCallTerminationReason.busy,
        occurredAt: disposition.occurredAt,
        ringEventId: validated.ringEventId,
      );
      return;
    }
    _handleRemoteTermination(
      validated.roomId,
      OrexRemoteCallTerminationReason.ended,
      occurredAt: disposition.occurredAt,
      ringEventId: validated.ringEventId,
    );
  }

  bool _promoteLegacyCallInstanceBody(
    String roomId,
    String ringEventId, {
    DateTime? occurredAt,
  }) {
    final exactRingEventId = ringEventId.trim();
    if (exactRingEventId.isEmpty) return false;

    final activeInRoom = active?.room.id == roomId;
    final enterInRoom =
        _enterRequestOwner != null && _enterRequestRoomId == roomId;
    final hasIncoming = _incomingRingEventIds.containsKey(roomId);
    final shown = _shownAttempts[roomId];
    final strongCurrentIds = <String>[
      if (activeInRoom && _activeRingEventId != null) _activeRingEventId!,
      if (enterInRoom && _enterRequestRingEventId != null)
        _enterRequestRingEventId!,
      if (hasIncoming && _incomingRingEventIds[roomId] != null)
        _incomingRingEventIds[roomId]!,
      if (shown?.ringEventId != null) shown!.ringEventId!,
    ];
    if (strongCurrentIds.any((current) => current != exactRingEventId)) {
      return false;
    }

    final promoteActive = activeInRoom && _activeRingEventId == null;
    final promoteEnter = enterInRoom && _enterRequestRingEventId == null;
    final promoteIncoming =
        hasIncoming && _incomingRingEventIds[roomId] == null;
    final promoteShown = shown != null && shown.ringEventId == null;
    final hasRuntimePromotion =
        promoteActive || promoteEnter || promoteIncoming || promoteShown;
    final hasLegacySuppression =
        _legacySuppressedRooms.contains(roomId) &&
        !_exactFallbackSuppressedRooms.contains(roomId);
    final legacyDispositionAt = _dispositions.legacyTimestamp(roomId);
    final hasPersistedLegacyAttempt =
        _persistedLeftAt.containsKey(roomId) &&
        _persistedLeftRingEventIds[roomId] == null;
    final storedAttemptBoundary =
        legacyDispositionAt ?? _persistedLeftAt[roomId];
    final storedAttemptMatches = orexShouldPromoteStoredLegacyCallInstance(
      exactAttemptAt: occurredAt,
      legacyDispositionAt: storedAttemptBoundary,
    );
    final hasStoredLegacyAttempt =
        hasLegacySuppression ||
        legacyDispositionAt != null ||
        hasPersistedLegacyAttempt;
    if (!hasRuntimePromotion &&
        (!hasStoredLegacyAttempt || !storedAttemptMatches)) {
      return false;
    }

    if (promoteActive) _activeRingEventId = exactRingEventId;
    if (promoteEnter) _enterRequestRingEventId = exactRingEventId;
    if (promoteIncoming) {
      _incomingRingEventIds[roomId] = exactRingEventId;
    }
    if (promoteShown) {
      _shownAttempts[roomId] = _ShownIncomingRing(
        exactRingEventId,
        occurredAt ?? shown.occurredAt,
      );
    }
    if (_legacySuppressedRooms.remove(roomId)) {
      _suppressCall(roomId, exactRingEventId);
    }
    if (legacyDispositionAt != null) {
      _dispositions.promoteLegacy(
        roomId,
        exactRingEventId,
        cleanupAfter: _persistedLeftAt.containsKey(roomId)
            ? null
            : const Duration(minutes: 2),
      );
    }
    if (hasPersistedLegacyAttempt) {
      _persistedLeftRingEventIds[roomId] = exactRingEventId;
      unawaited(_persistLeftCalls());
    }

    if (hasRuntimePromotion) {
      final exactKey = _exactAttemptKey(roomId, exactRingEventId);
      if (_emittedPromotionAttempts.add(exactKey)) {
        while (_emittedPromotionAttempts.length >
            VoipService._maxRememberedExactCallAttempts) {
          _emittedPromotionAttempts.remove(_emittedPromotionAttempts.first);
        }
        if (!_disposed) {
          _instancePromotions.add(
            OrexCallInstancePromotion(
              previous: OrexCallInstance(roomId: roomId),
              current: OrexCallInstance(
                roomId: roomId,
                ringEventId: exactRingEventId,
              ),
            ),
          );
          _notifyFlowListeners();
        }
      }
    }
    OrexLog.d(
      'Voip',
      'promoted legacy call attempt room=$roomId ring=$exactRingEventId',
    );
    return true;
  }

  void _handleTimelineEventBody(Event event) {
    if (_disposed || event.senderId == client.userID) return;
    final notificationType = event
        .tryParseRtcNotificationContent()
        ?.notificationType;
    if (notificationType == null) return;
    final age = DateTime.now().difference(event.originServerTs);
    if (age > VoipService._timelineCallFallbackTtl) return;

    if (notificationType == RtcNotificationType.notification) {
      final action = orexParseWakeCancellationAction(
        event.content['orex_call_action'],
      );
      final dispositionType = switch (action) {
        OrexWakeCancellationAction.handled => VoipService._handledEventType,
        OrexWakeCancellationAction.ended => VoipService._endedEventType,
        null => null,
      };
      final ringEventId = _ringEventIdFromContent(event.content);
      if (dispositionType == null || ringEventId == null) return;
      _applyWakeCancellation(
        _DeferredRemoteDisposition(
          type: dispositionType,
          roomId: event.room.id,
          sender: event.senderId,
          ringEventId: ringEventId,
          occurredAt: event.originServerTs,
        ),
      );
      return;
    }
    if (notificationType != RtcNotificationType.ring) return;
    if (!orexShouldPresentExplicitRing(
      roomHasActiveCall: _roomHasCall(event.room),
      eventAge: age,
    )) {
      final staleEventId = event.eventId.trim();
      if (staleEventId.isNotEmpty) {
        _recordCallDisposition(
          event.room.id,
          occurredAt: event.originServerTs,
          ringEventId: staleEventId,
        );
        _suppressCall(event.room.id, staleEventId);
      }
      OrexLog.d(
        'Voip',
        'ignored delayed ring without active membership '
            'room=${event.room.id} age=${age.inSeconds}s',
      );
      return;
    }

    final eventId = event.eventId.trim();
    if (eventId.isEmpty || !_rememberIncomingRingEventId(eventId)) return;

    if (!_suppressionRestored) {
      _pendingFreshRingRooms[event.room.id] = _PendingIncomingRing(
        event.room,
        event.originServerTs,
        eventId,
      );
      return;
    }
    _presentFreshIncomingRing(event.room, event.originServerTs, eventId);
  }

  void _considerIncomingRoomBody(
    Room room, {
    required bool markExistingAsSeen,
    DateTime? freshExplicitRingAt,
    String? freshExplicitRingEventId,
  }) {
    final hasFreshExplicitRing = freshExplicitRingAt != null;
    final ringEventId = freshExplicitRingEventId;
    final myId = client.userID;
    if (ringEventId != null &&
        (_hasExactCallDisposition(room.id, ringEventId) ||
            _hasExactCallSuppression(room.id, ringEventId))) {
      return;
    }
    if (ringEventId != null &&
        _promoteLegacyCallInstance(
          room.id,
          ringEventId,
          occurredAt: freshExplicitRingAt,
        )) {
      return;
    }
    final retainedIncomingRingEventId = _incomingRingEventIds[room.id];
    if (ringEventId == null &&
        retainedIncomingRingEventId != null &&
        (_hasExactCallDisposition(room.id, retainedIncomingRingEventId) ||
            _hasExactCallSuppression(room.id, retainedIncomingRingEventId))) {
      return;
    }
    if (_enterRequestOwner != null && _enterRequestRoomId == room.id) {
      if (orexIsDifferentExactCallAttempt(
            previousRingEventId: _enterRequestRingEventId,
            nextRingEventId: ringEventId,
          ) &&
          _suppressCall(room.id, ringEventId)) {
        _recordCallDisposition(room.id, ringEventId: ringEventId);
        unawaited(
          notifyBusy(
            OrexCallInstance(roomId: room.id, ringEventId: ringEventId),
          ),
        );
      }
      return;
    }
    final currentCall = active;
    if (currentCall != null) {
      if (currentCall.room.id == room.id) {
        if (orexIsDifferentExactCallAttempt(
              previousRingEventId: _activeRingEventId,
              nextRingEventId: ringEventId,
            ) &&
            _suppressCall(room.id, ringEventId)) {
          _recordCallDisposition(room.id, ringEventId: ringEventId);
          unawaited(
            notifyBusy(
              OrexCallInstance(roomId: room.id, ringEventId: ringEventId),
            ),
          );
        }
        return;
      }
      // Orex supports one personal media session at a time. Never stack a
      // second incoming UI on top of an active call; answer the second attempt
      // once with an explicit busy disposition instead.
      if (_shouldRingForRoom(room) && _suppressCall(room.id, ringEventId)) {
        OrexLog.d(
          'Voip',
          'incoming call rejected as busy while another call is active room=${room.id}',
        );
        _recordCallDisposition(room.id, ringEventId: ringEventId);
        unawaited(
          notifyBusy(
            OrexCallInstance(roomId: room.id, ringEventId: ringEventId),
          ),
        );
      }
      return;
    }
    final shown = _shownAttempts[room.id];
    if (shown != null) {
      if (!orexShouldSupersedeShownIncomingCall(
        shownRingEventId: shown.ringEventId,
        shownAt: shown.occurredAt,
        candidateRingEventId: ringEventId,
        candidateAt: freshExplicitRingAt,
      )) {
        return;
      }
      final previous = OrexCallInstance(
        roomId: room.id,
        ringEventId: shown.ringEventId,
      );
      _shownAttempts[room.id] = _ShownIncomingRing(
        ringEventId,
        freshExplicitRingAt,
      );
      _incomingRingEventIds[room.id] = ringEventId;
      _dismiss.add(
        OrexIncomingCallDismissal(
          roomId: previous.roomId,
          ringEventId: previous.ringEventId,
        ),
      );
      _incoming.add(OrexIncomingCall(room: room, ringEventId: ringEventId));
      return;
    }
    if (_isCallSuppressed(room.id, ringEventId)) {
      if (ringEventId != null &&
          (_hasExactCallDisposition(room.id, ringEventId) ||
              _hasExactCallSuppression(room.id, ringEventId))) {
        return;
      }
      final resumed = _resumeAfterNewRemoteCall(
        room,
        freshExplicitRingAt: freshExplicitRingAt,
        freshExplicitRingEventId: ringEventId,
      );
      if (!resumed) {
        final mayBypassStartupSuppress =
            hasFreshExplicitRing &&
            !_persistedLeftAt.containsKey(room.id) &&
            !_dispositions.hasLegacy(room.id);
        if (!mayBypassStartupSuppress) return;
        _clearCallSuppression(room.id);
      }
    }
    final others = _callMembers(room).where((id) => id != myId).toSet();
    if (others.isEmpty && !hasFreshExplicitRing) {
      return; // только моё членство — не входящий
    }
    if (!_shouldRingForRoom(room)) {
      // В группах, каналах и чатах супергруппы звонок — это голосовой канал:
      // не показываем системный входящий вызов всем участникам. Комната всё
      // равно помечается активной, поэтому UI покажет «Идёт звонок · Войти».
      _suppressCall(room.id, ringEventId);
      return;
    }
    if (markExistingAsSeen && !hasFreshExplicitRing) {
      _suppressCall(
        room.id,
        ringEventId,
      ); // активен на старте → не звоним (покажет панель «войти»)
      return;
    }
    OrexLog.d(
      'Voip',
      'incoming direct call room=${room.id} '
          'from=${others.isEmpty ? 'explicit-ring' : others.join(',')}',
    );
    _shownAttempts[room.id] = _ShownIncomingRing(
      ringEventId,
      freshExplicitRingAt,
    );
    _incomingRingEventIds[room.id] = ringEventId;
    _incoming.add(OrexIncomingCall(room: room, ringEventId: ringEventId));
  }

}

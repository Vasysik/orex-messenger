part of 'voip_service.dart';

class _PendingIncomingRing {
  const _PendingIncomingRing(this.room, this.occurredAt, this.ringEventId);

  final Room room;
  final DateTime occurredAt;
  final String ringEventId;
}

class _FreshIncomingRing {
  const _FreshIncomingRing(this.occurredAt, this.ringEventId);

  final DateTime occurredAt;
  final String ringEventId;
}

class _ShownIncomingRing {
  const _ShownIncomingRing(this.ringEventId, this.occurredAt);

  final String? ringEventId;
  final DateTime? occurredAt;
}

class _ValidatedDisposition {
  const _ValidatedDisposition(this.roomId, this.ringEventId);

  final String roomId;
  final String? ringEventId;
}

class _DeferredRemoteDisposition {
  const _DeferredRemoteDisposition({
    required this.type,
    required this.roomId,
    required this.sender,
    required this.ringEventId,
    required this.occurredAt,
  });

  final String type;
  final String roomId;
  final String sender;
  final String? ringEventId;
  final DateTime? occurredAt;
}

class _OutgoingRing {
  const _OutgoingRing(this.eventId);

  final String eventId;
}

class _StaleMembershipCleanupScope {
  const _StaleMembershipCleanupScope({
    required this.generation,
    required this.userId,
    required this.deviceId,
  });

  final int generation;
  final String userId;
  final String deviceId;
}

/// A background stale-membership cleanup belongs to the Matrix credentials
/// that scheduled it.  It must not continue after logout or after another
/// account has taken over the same process.
bool orexShouldContinueStaleMembershipCleanup({
  required bool disposed,
  required bool accountTransitionInProgress,
  required int scheduledGeneration,
  required int currentGeneration,
  required bool loggedIn,
  required String scheduledUserId,
  required String? currentUserId,
  required String scheduledDeviceId,
  required String? currentDeviceId,
}) =>
    !disposed &&
    !accountTransitionInProgress &&
    scheduledGeneration == currentGeneration &&
    loggedIn &&
    scheduledUserId.isNotEmpty &&
    scheduledUserId == currentUserId &&
    scheduledDeviceId.isNotEmpty &&
    scheduledDeviceId == currentDeviceId;

class OrexIncomingCall {
  const OrexIncomingCall({required this.room, this.ringEventId});

  final Room room;
  final String? ringEventId;

  OrexCallInstance get instance =>
      OrexCallInstance(roomId: room.id, ringEventId: ringEventId);
}

class OrexIncomingCallDismissal extends OrexCallInstance {
  const OrexIncomingCallDismissal({
    required super.roomId,
    super.ringEventId,
    this.cancelsPendingAccept = true,
  });

  final bool cancelsPendingAccept;
}

class OrexRemoteCallAccepted extends OrexCallInstance {
  const OrexRemoteCallAccepted({required super.roomId, super.ringEventId});
}

class _CallKeyShareState {
  _CallKeyShareState(this.groupCall, this.owner);

  final GroupCallSession groupCall;
  final Object owner;
  final Set<String> sharedParticipantIds = <String>{};
  int sharedLocalKeyRevision = -1;
  Future<lk.BaseKeyProvider>? keyProviderLease;
  Future<void>? mediaOperationsDrained;
  Future<void> _tail = Future<void>.value();
  bool active = true;

  Future<void> run(Future<void> Function() operation) {
    final previous = _tail;
    late final Future<void> next;
    next = (() async {
      try {
        await previous;
      } catch (_) {
        // Each reconciliation attempt reports its own error.
      }
      if (!active) return;
      await operation();
    })();
    _tail = next;
    return next;
  }

  void invalidate() {
    active = false;
    sharedParticipantIds.clear();
  }
}

class OrexRemoteCallTermination {
  const OrexRemoteCallTermination({
    required this.roomId,
    required this.reason,
    this.ringEventId,
  });

  final String roomId;
  final OrexRemoteCallTerminationReason reason;
  final String? ringEventId;
}

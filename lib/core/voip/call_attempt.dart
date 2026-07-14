import 'package:flutter/foundation.dart' show immutable;

enum OrexRemoteCallTerminationReason { ended, rejected, busy }

/// Stable identity of one personal-call attempt inside a Matrix room.
///
/// A room can be called repeatedly, so [roomId] alone is never sufficient for
/// delayed accepted/rejected/ended signals. For wakeable MatrixRTC calls the
/// ring event id is the canonical attempt id. `null` is retained only for
/// membership-only/legacy calls that never produced an explicit ring event.
@immutable
class OrexCallInstance {
  const OrexCallInstance({required this.roomId, this.ringEventId});

  final String roomId;
  final String? ringEventId;

  String get routeKey => '$roomId\u001f${ringEventId ?? 'legacy'}';
}

/// Announces that one already-present legacy call gained its canonical Matrix
/// ring event id. Consumers must migrate the existing UI/session identity
/// instead of presenting a second incoming call.
@immutable
class OrexCallInstancePromotion {
  const OrexCallInstancePromotion({
    required this.previous,
    required this.current,
  });

  final OrexCallInstance previous;
  final OrexCallInstance current;
}

bool orexCallInstanceIdsMatch(String? expected, String? received) =>
    expected == received;

/// Applies a disposition only to the attempt that is current at receipt time.
///
/// A tokenless legacy disposition is deliberately ignored once the current
/// call has a strong id: accepting it would let a delayed old hangup terminate
/// a same-room redial. If there is no current call, an exact disposition is
/// still recorded as a tombstone so its ring cannot surface afterwards.
bool orexShouldApplyCallDisposition({
  required bool hasCurrentCall,
  required String? expectedRingEventId,
  required String? receivedRingEventId,
}) {
  if (expectedRingEventId != null) {
    return expectedRingEventId == receivedRingEventId;
  }
  if (!hasCurrentCall) return true;
  if (receivedRingEventId == null) return true;
  return orexShouldPromoteLegacyCallInstance(
    hasCurrentCall: hasCurrentCall,
    expectedRingEventId: expectedRingEventId,
    receivedRingEventId: receivedRingEventId,
  );
}

/// The first exact ring id upgrades a tokenless live attempt; it does not
/// represent a same-room redial and must not trigger a second presentation.
bool orexShouldPromoteLegacyCallInstance({
  required bool hasCurrentCall,
  required String? expectedRingEventId,
  required String? receivedRingEventId,
}) =>
    hasCurrentCall &&
    expectedRingEventId == null &&
    receivedRingEventId != null &&
    receivedRingEventId.isNotEmpty;

bool orexShouldPromoteStoredLegacyCallInstance({
  required DateTime? exactAttemptAt,
  required DateTime? legacyDispositionAt,
}) =>
    legacyDispositionAt != null &&
    exactAttemptAt != null &&
    !exactAttemptAt.isAfter(legacyDispositionAt);

bool orexShouldRecordOutOfOrderExactTombstone({
  required String? currentRingEventId,
  required String? receivedRingEventId,
}) =>
    currentRingEventId != null &&
    receivedRingEventId != null &&
    currentRingEventId != receivedRingEventId;

/// Room membership can change between ring and disposition. A live exact call
/// attempt keeps its original control plane instead of dropping accept/reject
/// merely because the room no longer looks personal at receipt time.
bool orexShouldTrustRemoteDispositionForRoom({
  required bool isPersonalRoom,
  required bool hasCurrentCall,
}) => isPersonalRoom || hasCurrentCall;

bool orexIsDifferentExactCallAttempt({
  required String? previousRingEventId,
  required String? nextRingEventId,
}) =>
    previousRingEventId != null &&
    nextRingEventId != null &&
    previousRingEventId != nextRingEventId;

bool orexShouldSupersedeShownIncomingCall({
  required String? shownRingEventId,
  required DateTime? shownAt,
  required String? candidateRingEventId,
  required DateTime? candidateAt,
}) {
  if (!orexIsDifferentExactCallAttempt(
    previousRingEventId: shownRingEventId,
    nextRingEventId: candidateRingEventId,
  )) {
    return false;
  }
  if (candidateAt == null) return false;
  return shownAt == null || candidateAt.isAfter(shownAt);
}

bool orexShouldMarkStartupCallAsSeen({
  required bool existedAtStartup,
  required bool hasFreshExplicitRing,
}) => existedAtStartup && !hasFreshExplicitRing;

bool orexIsNewCallInstanceAfterPersistedLeave({
  required Set<String> previousMemberships,
  required Set<String> currentMemberships,
  required bool hasFreshRing,
}) {
  if (hasFreshRing) return true;
  if (previousMemberships.isEmpty) return false;
  return currentMemberships.any(
    (signature) => !previousMemberships.contains(signature),
  );
}

bool orexIsFreshRingAfterLeave({
  required DateTime? ringAt,
  required DateTime leftAt,
}) => ringAt != null && ringAt.isAfter(leftAt);

Set<String> orexPendingMediaKeyShareTargets({
  required Iterable<String> remoteParticipantIds,
  required Set<String> sharedParticipantIds,
  int sharedLocalKeyRevision = 0,
  int currentLocalKeyRevision = 0,
}) {
  final remoteIds = remoteParticipantIds.toSet();
  return sharedLocalKeyRevision == currentLocalKeyRevision
      ? remoteIds.difference(sharedParticipantIds)
      : remoteIds;
}

/// Rejects implausibly old or future-dated control events before they mutate
/// the current same-room call attempt. `null` stays valid for legacy clients;
/// exact attempt identity remains the primary anti-replay boundary.
bool orexIsPlausibleCallControlTimestamp(
  DateTime? occurredAt, {
  DateTime? now,
  Duration maxAge = const Duration(minutes: 5),
  Duration maxFutureSkew = const Duration(minutes: 1),
}) {
  if (occurredAt == null) return true;
  final reference = now ?? DateTime.now();
  if (occurredAt.isAfter(reference.add(maxFutureSkew))) return false;
  return !occurredAt.isBefore(reference.subtract(maxAge));
}

/// Selects the MatrixRTC `call_id` for a local join.
///
/// New Orex direct calls use the exact ring event id as a generation id. An
/// explicit ring is authoritative even while stale memberships from an older
/// call are still visible. With no exact ring, an active remote membership is
/// used for legacy room-scoped group calls, then [roomId] is the final fallback.
String orexSelectMatrixRtcCallId({
  required String roomId,
  required String? expectedRingEventId,
  required Iterable<String> remoteCallIds,
}) {
  final expected = expectedRingEventId?.trim();
  if (expected != null && expected.isNotEmpty) {
    // An explicit ring is the authoritative generation boundary. Never let a
    // single stale membership from the previous call override it: that was the
    // exact source of second-call joins getting attached to the first call.
    return expected;
  }
  final remoteIds = remoteCallIds
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  if (remoteIds.isNotEmpty) return remoteIds.first;
  return roomId;
}

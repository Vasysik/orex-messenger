package ru.orex.messenger

/**
 * Stable identity of one call attempt inside a Matrix room.
 *
 * Legacy clients did not carry the Matrix ring event id, so `(roomId, null)`
 * remains a valid legacy identity. Once either side has a non-null token we
 * require exact equality; a room-only action must never mutate a newer strong
 * attempt in the same room.
 */
internal fun normalizeRingEventId(value: String?): String? =
    value?.trim()?.takeIf { it.isNotEmpty() }

internal fun sameRingAttempt(current: String?, requested: String?): Boolean =
    normalizeRingEventId(current) == normalizeRingEventId(requested)

/** Safe one-way enrichment of a legacy/placeholder attempt identity. */
internal fun canPromoteRingAttempt(current: String?, requested: String?): Boolean =
    normalizeRingEventId(current) == null && normalizeRingEventId(requested) != null


/**
 * A strong ring may replace persisted answering/active presentation state only
 * when no process-local owner still backs that state.
 *
 * This is intentionally narrower than ordinary ring replacement: ringing state
 * already has timestamp ordering, while answering/active state must not survive
 * a killed Flutter process and poison the next exact call generation.
 */
internal fun shouldReplaceUnownedNonRingingAttempt(
    currentCallId: String,
    currentRingEventId: String?,
    currentIsRinging: Boolean,
    requestedCallId: String,
    requestedRingEventId: String?,
    hasLiveOwner: Boolean,
): Boolean {
    if (hasLiveOwner || currentIsRinging) return false
    val requested = normalizeRingEventId(requestedRingEventId) ?: return false
    if (currentCallId != requestedCallId) return true
    return normalizeRingEventId(currentRingEventId) != requested
}

internal fun sameCallAttempt(
    currentCallId: String,
    currentRingEventId: String?,
    requestedCallId: String,
    requestedRingEventId: String?,
): Boolean = currentCallId == requestedCallId &&
    sameRingAttempt(currentRingEventId, requestedRingEventId)


/** Exact identity, plus the one safe legacy -> exact promotion used by UI handoff. */
internal fun sameOrPromotableCallAttempt(
    currentCallId: String?,
    currentRingEventId: String?,
    requestedCallId: String,
    requestedRingEventId: String?,
): Boolean {
    val normalizedCurrentCallId = currentCallId?.trim().orEmpty()
    if (normalizedCurrentCallId.isEmpty() || normalizedCurrentCallId != requestedCallId) {
        return false
    }
    return sameCallAttempt(
        normalizedCurrentCallId,
        currentRingEventId,
        requestedCallId,
        requestedRingEventId,
    ) || canPromoteRingAttempt(currentRingEventId, requestedRingEventId)
}

/**
 * Whether an exact remote ring cancellation may close the fallback incoming UI.
 *
 * The Android notification can outlive the short presentation-state TTL. In
 * that window a non-null Matrix event id plus its persisted cancellation
 * tombstone is sufficient evidence even though there is no live state left.
 * A live answering/active call or a different strong attempt always wins.
 */
internal fun exactCancellationMatchesFallback(
    liveCallId: String?,
    liveRingEventId: String?,
    liveIsRinging: Boolean,
    requestedCallId: String,
    requestedRingEventId: String?,
): Boolean {
    val normalizedRequestedRingEventId = normalizeRingEventId(requestedRingEventId)
        ?: return false
    val normalizedLiveCallId = liveCallId?.trim()?.takeIf { it.isNotEmpty() }
        ?: return true
    if (!liveIsRinging) return false
    return sameCallAttempt(
        normalizedLiveCallId,
        liveRingEventId,
        requestedCallId,
        normalizedRequestedRingEventId,
    ) || (normalizedLiveCallId == requestedCallId &&
        canPromoteRingAttempt(liveRingEventId, normalizedRequestedRingEventId))
}

/**
 * A foreground stop is owned when either its persisted descriptor or its
 * presentation state matched the requested attempt.
 *
 * These lifecycles can legitimately diverge: after process recovery an old
 * exact descriptor may coexist with a newer incoming presentation. Refusing
 * to clear the owned descriptor merely because the presentation correctly
 * rejected that old attempt would leave recovery stuck forever.
 */
internal fun shouldApplyForegroundStop(
    descriptorMatched: Boolean,
    presentationMatched: Boolean,
): Boolean = descriptorMatched || presentationMatched

internal fun callAttemptRequestCode(
    base: Int,
    callId: String,
    ringEventId: String?,
): Int = base xor callId.hashCode() xor (normalizeRingEventId(ringEventId)?.hashCode() ?: 0)

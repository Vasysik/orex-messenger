package ru.orex.messenger

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * Cross-source call presentation state.
 *
 * One incoming Orex call can be observed through FCM, Matrix /sync and
 * Core-Telecom. Those sources are intentionally redundant, but the user must
 * see only one ring. This small persisted state machine makes the redundancy
 * idempotent even when Android recreates the process between deliveries.
 */
object OrexCallPresentationState {
    enum class IncomingDecision {
        FIRST_ALERT,
        SILENT_REFRESH,
        SUPPRESS,
    }

    private const val TAG = "OrexCallState"
    private const val PREFS = "orex_call_presentation_v1"
    private const val CANCEL_PREFS = "orex_call_cancel_tombstone_v1"
    private const val ENDED_PREFS = "orex_call_ended_tombstone_v1"
    private const val KEY_CALL_ID = "call_id"
    private const val KEY_PHASE = "phase"
    private const val KEY_EXPIRES_AT = "expires_at"
    private const val KEY_RING_TOKEN = "ring_token"
    private const val KEY_RING_SENT_AT = "ring_sent_at"
    private const val KEY_CANCEL_CALL_ID = "cancel_call_id"
    private const val KEY_CANCEL_RING_TOKEN = "cancel_ring_token"
    private const val KEY_CANCEL_EXPIRES_AT = "cancel_expires_at"
    private const val KEY_CANCEL_ENTRIES = "cancel_entries"
    private const val KEY_ENDED_CALL_ID = "ended_call_id"
    private const val KEY_ENDED_AT = "ended_at"
    private const val KEY_ENDED_EXPIRES_AT = "ended_expires_at"

    private const val PHASE_RINGING = "ringing"
    private const val PHASE_ANSWERING = "answering"
    private const val PHASE_ACTIVE = "active"

    private const val DEFAULT_RING_WINDOW_MS = 45_000L
    private const val CANCEL_TOMBSTONE_WINDOW_MS = 120_000L
    private const val MAX_CANCEL_TOMBSTONES = 16
    private const val ENDED_TOMBSTONE_WINDOW_MS = 120_000L
    private const val SENT_TIME_SLOP_MS = 1_500L
    private const val ANSWER_WINDOW_MS = 120_000L
    private const val ACTIVE_WINDOW_MS = 12 * 60 * 60 * 1000L

    private val lock = Any()

    fun claimPushRing(
        context: Context,
        callId: String,
        ringToken: String?,
        sentAt: Long?,
        timeoutAfterMs: Long,
        refreshOnly: Boolean = false,
    ): IncomingDecision = synchronized(lock) {
        val now = System.currentTimeMillis()
        // A strong Matrix event id identifies a fresh redial even when it was
        // sent inside the legacy timestamp slop window. Timestamp suppression
        // is only a compatibility fallback for tokenless clients.
        if (ringToken.isNullOrBlank() &&
            isLateRingForRecentlyEndedCall(context, callId, sentAt, now)
        ) {
            rememberSuppressedRingLocked(context, callId, ringToken, now)
            Log.i(TAG, "Late incoming push suppressed after local call end")
            return@synchronized IncomingDecision.SUPPRESS
        }
        if (!ringToken.isNullOrBlank() && isCancelledRing(context, callId, ringToken, now)) {
            Log.i(TAG, "Late ring suppressed by exact cancellation tombstone")
            return@synchronized IncomingDecision.SUPPRESS
        }
        val state = readLiveState(context, now)
        if (state == null && refreshOnly) {
            return@synchronized IncomingDecision.SUPPRESS
        }
        if (state != null) {
            if (state.callId == callId) {
                // Metadata resolution for the same exact ring may arrive after
                // the immediate FCM presentation (for example with an avatar).
                // Refresh silently, but never reopen/alert an answering call.
                if (state.phase == PHASE_RINGING) {
                    val currentToken = currentRingToken(context)
                    val normalizedRingToken = normalizeRingEventId(ringToken)
                    if (sameRingAttempt(currentToken, normalizedRingToken)) {
                        val normalizedSentAt = sentAt?.takeIf { it > 0L }
                        if (state.ringSentAt == null && normalizedSentAt != null) {
                            writeState(
                                context = context,
                                callId = state.callId,
                                phase = state.phase,
                                expiresAt = state.expiresAt,
                                ringToken = normalizedRingToken,
                                ringSentAt = normalizedSentAt,
                            )
                        }
                        return@synchronized IncomingDecision.SILENT_REFRESH
                    }
                    if (canPromoteRingAttempt(currentToken, normalizedRingToken)) {
                        writeState(
                            context = context,
                            callId = state.callId,
                            phase = state.phase,
                            expiresAt = state.expiresAt,
                            ringToken = normalizedRingToken,
                            ringSentAt = sentAt?.takeIf { it > 0L },
                        )
                        return@synchronized IncomingDecision.SILENT_REFRESH
                    }
                    if (currentToken != null && normalizedRingToken != null) {
                        val normalizedSentAt = sentAt?.takeIf { it > 0L }
                        val currentSentAt = state.ringSentAt
                        if (normalizedSentAt == null || currentSentAt == null) {
                            Log.i(TAG, "Strong ring replacement suppressed without ordering proof")
                            return@synchronized IncomingDecision.SUPPRESS
                        }
                        if (normalizedSentAt < currentSentAt) {
                            rememberCancelledRing(context, callId, normalizedRingToken, now)
                            return@synchronized IncomingDecision.SUPPRESS
                        }
                        if (normalizedSentAt == currentSentAt) {
                            return@synchronized IncomingDecision.SUPPRESS
                        }
                        // Same-room attempts can cross in transport: a fresh B
                        // ring may arrive before A's delayed end. While A is
                        // only ringing, atomically replace it without producing
                        // a second alert and tombstone A against redelivery.
                        rememberCancelledRing(context, callId, currentToken, now)
                        writeState(
                            context = context,
                            callId = state.callId,
                            phase = PHASE_RINGING,
                            expiresAt = now + timeoutAfterMs.coerceIn(
                                1_000L,
                                DEFAULT_RING_WINDOW_MS,
                            ),
                            ringToken = normalizedRingToken,
                            ringSentAt = normalizedSentAt,
                        )
                        return@synchronized IncomingDecision.SILENT_REFRESH
                    }
                    return@synchronized IncomingDecision.SUPPRESS
                }
                rememberSuppressedRingLocked(context, callId, ringToken, now)
                return@synchronized IncomingDecision.SUPPRESS
            } else {
                Log.i(TAG, "Incoming call suppressed while another call is ${state.phase}")
                return@synchronized IncomingDecision.SUPPRESS
            }
        }

        writeState(
            context = context,
            callId = callId,
            phase = PHASE_RINGING,
            expiresAt = now + timeoutAfterMs.coerceIn(1_000L, DEFAULT_RING_WINDOW_MS),
            ringToken = ringToken,
            ringSentAt = sentAt?.takeIf { it > 0L },
        )
        IncomingDecision.FIRST_ALERT
    }

    fun claimTelecomRing(
        context: Context,
        callId: String,
        ringEventId: String? = null,
    ): IncomingDecision = synchronized(lock) {
        val now = System.currentTimeMillis()
        val normalizedRingEventId = normalizeRingEventId(ringEventId)
        if (normalizedRingEventId != null &&
            isCancelledRing(context, callId, normalizedRingEventId, now)
        ) return@synchronized IncomingDecision.SUPPRESS
        val state = readLiveState(context, now)
        if (state != null) {
            if (state.callId == callId) {
                val currentRingEventId = currentRingToken(context)
                if (!sameRingAttempt(currentRingEventId, normalizedRingEventId)) {
                    if (canPromoteRingAttempt(currentRingEventId, normalizedRingEventId)) {
                        writeState(
                            context,
                            callId,
                            state.phase,
                            state.expiresAt,
                            normalizedRingEventId,
                            state.ringSentAt,
                        )
                        return@synchronized if (state.phase == PHASE_ACTIVE) {
                            IncomingDecision.SUPPRESS
                        } else {
                            IncomingDecision.SILENT_REFRESH
                        }
                    }
                    if (state.phase == PHASE_RINGING &&
                        currentRingEventId != null && normalizedRingEventId != null
                    ) {
                        rememberCancelledRing(context, callId, currentRingEventId, now)
                        writeState(
                            context,
                            callId,
                            PHASE_RINGING,
                            now + DEFAULT_RING_WINDOW_MS,
                            normalizedRingEventId,
                            null,
                        )
                        return@synchronized IncomingDecision.SILENT_REFRESH
                    }
                    Log.i(TAG, "Telecom ring suppressed for a different room attempt")
                    return@synchronized IncomingDecision.SUPPRESS
                }
                return@synchronized when (state.phase) {
                    PHASE_RINGING, PHASE_ANSWERING -> IncomingDecision.SILENT_REFRESH
                    PHASE_ACTIVE -> IncomingDecision.SUPPRESS
                    else -> IncomingDecision.SUPPRESS
                }
            }
            Log.i(TAG, "Telecom ring suppressed while another call is ${state.phase}")
            return@synchronized IncomingDecision.SUPPRESS
        }

        writeState(
            context = context,
            callId = callId,
            phase = PHASE_RINGING,
            expiresAt = now + DEFAULT_RING_WINDOW_MS,
            ringToken = normalizedRingEventId,
        )
        IncomingDecision.FIRST_ALERT
    }

    fun markAnswering(
        context: Context,
        callId: String,
        ringEventId: String? = null,
    ): Boolean = synchronized(lock) {
        val now = System.currentTimeMillis()
        val normalizedRingEventId = normalizeRingEventId(ringEventId)
        val state = readLiveState(context, now)
        if (state == null && normalizedRingEventId != null &&
            isCancelledRing(context, callId, normalizedRingEventId, now)
        ) return@synchronized false
        if (state != null) {
            val currentRingEventId = currentRingToken(context)
            val sameAttempt = sameCallAttempt(
                state.callId,
                currentRingEventId,
                callId,
                normalizedRingEventId,
            )
            val canPromoteAttempt = state.callId == callId &&
                canPromoteRingAttempt(currentRingEventId, normalizedRingEventId)
            if (!sameAttempt && !canPromoteAttempt) return@synchronized false
        }
        writeState(
            context = context,
            callId = callId,
            phase = PHASE_ANSWERING,
            expiresAt = now + ANSWER_WINDOW_MS,
            ringToken = normalizedRingEventId,
        )
        true
    }

    fun markActive(
        context: Context,
        callId: String,
        ringEventId: String? = null,
    ): Boolean = synchronized(lock) {
        val now = System.currentTimeMillis()
        val normalizedRingEventId = normalizeRingEventId(ringEventId)
        val state = readLiveState(context, now)
        if (state == null && normalizedRingEventId != null &&
            isCancelledRing(context, callId, normalizedRingEventId, now)
        ) return@synchronized false
        if (state != null) {
            val currentRingEventId = currentRingToken(context)
            val sameAttempt = sameCallAttempt(
                state.callId,
                currentRingEventId,
                callId,
                normalizedRingEventId,
            )
            val canPromoteAttempt = state.callId == callId &&
                canPromoteRingAttempt(currentRingEventId, normalizedRingEventId)
            if (!sameAttempt && !canPromoteAttempt) return@synchronized false
        }
        writeState(
            context = context,
            callId = callId,
            phase = PHASE_ACTIVE,
            expiresAt = now + ACTIVE_WINDOW_MS,
            ringToken = normalizedRingEventId,
        )
        true
    }

    fun markEnded(
        context: Context,
        callId: String? = null,
        ringEventId: String? = null,
        endedAt: Long = System.currentTimeMillis(),
    ): Boolean = synchronized(lock) {
        val prefs = prefs(context)
        val normalizedCallId = callId?.trim()?.takeIf { it.isNotEmpty() }
        val normalizedRingEventId = normalizeRingEventId(ringEventId)
        val liveState = readLiveState(context, System.currentTimeMillis())
        val currentCallId = liveState?.callId
        val currentRingEventId = currentRingToken(context)
        val sameOrPromotableAttempt = normalizedCallId == null ||
            currentCallId == null ||
            sameCallAttempt(
                currentCallId,
                currentRingEventId,
                normalizedCallId,
                normalizedRingEventId,
        ) || (currentCallId == normalizedCallId &&
                canPromoteRingAttempt(currentRingEventId, normalizedRingEventId))
        if (!sameOrPromotableAttempt) {
            if (normalizedRingEventId != null) {
                rememberCancelledRing(context, normalizedCallId, normalizedRingEventId, endedAt)
            } else if (currentRingEventId == null) {
                rememberEndedCall(context, normalizedCallId, endedAt)
            }
            return@synchronized false
        }

        // Always remember the explicitly ended room, even if presentation prefs
        // have already moved to another call. Do not clear that newer call below.
        val tombstoneCallId = currentCallId ?: normalizedCallId
        val tombstoneRingEventId = currentRingEventId ?: normalizedRingEventId
        if (!tombstoneCallId.isNullOrBlank()) {
            if (tombstoneRingEventId != null) {
                rememberCancelledRing(
                    context,
                    tombstoneCallId,
                    tombstoneRingEventId,
                    endedAt,
                )
            } else {
                rememberEndedCall(context, tombstoneCallId, endedAt)
            }
        }

        prefs.edit().clear().apply()
        true
    }

    fun isAnsweringOrActive(context: Context, callId: String): Boolean = synchronized(lock) {
        val state = readLiveState(context, System.currentTimeMillis()) ?: return@synchronized false
        state.callId == callId && (state.phase == PHASE_ANSWERING || state.phase == PHASE_ACTIVE)
    }

    fun canCancelPresentation(
        context: Context,
        callId: String,
        ringEventId: String? = null,
    ): Boolean = synchronized(lock) {
        val state = readLiveState(context, System.currentTimeMillis())
        if (state == null) return@synchronized true
        val currentRingEventId = currentRingToken(context)
        sameCallAttempt(state.callId, currentRingEventId, callId, ringEventId) ||
            (state.callId == callId && canPromoteRingAttempt(currentRingEventId, ringEventId))
    }

    fun cancelRingIfMatches(
        context: Context,
        callId: String,
        ringToken: String,
    ): Boolean = synchronized(lock) {
        val now = System.currentTimeMillis()
        val normalizedRingToken = normalizeRingEventId(ringToken)
            ?: return@synchronized false
        rememberCancelledRing(context, callId, normalizedRingToken, now)
        val state = readLiveState(context, now)
        val currentToken = if (state == null) null else currentRingToken(context)
        if (!exactCancellationMatchesFallback(
                liveCallId = state?.callId,
                liveRingEventId = currentToken,
                liveIsRinging = state?.phase == PHASE_RINGING,
                requestedCallId = callId,
                requestedRingEventId = normalizedRingToken,
            )
        ) return@synchronized false
        if (state != null) prefs(context).edit().clear().apply()
        true
    }


    fun rememberSuppressedRing(
        context: Context,
        callId: String,
        ringToken: String?,
    ) = synchronized(lock) {
        rememberSuppressedRingLocked(
            context = context,
            callId = callId,
            ringToken = ringToken,
            now = System.currentTimeMillis(),
        )
    }

    private fun rememberSuppressedRingLocked(
        context: Context,
        callId: String,
        ringToken: String?,
        now: Long,
    ) {
        if (!ringToken.isNullOrBlank()) {
            rememberCancelledRing(context, callId, ringToken, now)
        }
    }

    private fun rememberEndedCall(
        context: Context,
        callId: String,
        endedAt: Long,
    ) {
        endedPrefs(context).edit()
            .putString(KEY_ENDED_CALL_ID, callId)
            .putLong(KEY_ENDED_AT, endedAt)
            .putLong(KEY_ENDED_EXPIRES_AT, endedAt + ENDED_TOMBSTONE_WINDOW_MS)
            .apply()
    }

    private fun isLateRingForRecentlyEndedCall(
        context: Context,
        callId: String,
        sentAt: Long?,
        now: Long,
    ): Boolean {
        if (sentAt == null || sentAt <= 0L) return false
        val prefs = endedPrefs(context)
        val expiresAt = prefs.getLong(KEY_ENDED_EXPIRES_AT, 0L)
        if (expiresAt <= now) {
            if (expiresAt > 0L) prefs.edit().clear().apply()
            return false
        }
        val endedAt = prefs.getLong(KEY_ENDED_AT, 0L)
        return prefs.getString(KEY_ENDED_CALL_ID, null) == callId &&
            endedAt > 0L &&
            sentAt <= endedAt + SENT_TIME_SLOP_MS
    }

    private fun rememberCancelledRing(
        context: Context,
        callId: String,
        ringToken: String,
        now: Long,
    ) {
        if (callId.isBlank() || ringToken.isBlank()) return
        val entries = readCancelledRings(context, now)
        entries.removeAll { it.callId == callId && it.ringToken == ringToken }
        entries.add(
            CancelledRing(
                callId = callId,
                ringToken = ringToken,
                expiresAt = now + CANCEL_TOMBSTONE_WINDOW_MS,
            ),
        )
        persistCancelledRings(
            context,
            entries.sortedByDescending { it.expiresAt }.take(MAX_CANCEL_TOMBSTONES),
        )
    }

    private fun isCancelledRing(
        context: Context,
        callId: String,
        ringToken: String,
        now: Long,
    ): Boolean {
        return readCancelledRings(context, now).any {
            it.callId == callId && it.ringToken == ringToken
        }
    }

    private data class CancelledRing(
        val callId: String,
        val ringToken: String,
        val expiresAt: Long,
    )

    private fun readCancelledRings(context: Context, now: Long): MutableList<CancelledRing> {
        val prefs = cancelPrefs(context)
        val entries = mutableListOf<CancelledRing>()
        val serialized = prefs.getString(KEY_CANCEL_ENTRIES, null)
        if (!serialized.isNullOrBlank()) {
            try {
                val array = JSONArray(serialized)
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    val callId = item.optString("callId").trim()
                    val ringToken = item.optString("ringEventId").trim()
                    val expiresAt = item.optLong("expiresAt")
                    if (callId.isNotEmpty() && ringToken.isNotEmpty() && expiresAt > now) {
                        entries.add(CancelledRing(callId, ringToken, expiresAt))
                    }
                }
            } catch (error: Throwable) {
                Log.w(TAG, "Ignoring malformed call cancellation tombstones", error)
            }
        }

        // One-release migration from the original single-entry storage.
        val legacyCallId = prefs.getString(KEY_CANCEL_CALL_ID, null)?.trim().orEmpty()
        val legacyRingToken = prefs.getString(KEY_CANCEL_RING_TOKEN, null)?.trim().orEmpty()
        val legacyExpiresAt = prefs.getLong(KEY_CANCEL_EXPIRES_AT, 0L)
        if (legacyCallId.isNotEmpty() && legacyRingToken.isNotEmpty() && legacyExpiresAt > now) {
            entries.add(CancelledRing(legacyCallId, legacyRingToken, legacyExpiresAt))
        }

        val deduplicated = linkedMapOf<String, CancelledRing>()
        for (entry in entries.sortedBy { it.expiresAt }) {
            deduplicated["${entry.callId}\u0000${entry.ringToken}"] = entry
        }
        val live = deduplicated.values
            .sortedByDescending { it.expiresAt }
            .take(MAX_CANCEL_TOMBSTONES)
            .toMutableList()
        persistCancelledRings(context, live)
        return live
    }

    private fun persistCancelledRings(
        context: Context,
        entries: List<CancelledRing>,
    ) {
        val array = JSONArray()
        for (entry in entries) {
            array.put(
                JSONObject()
                    .put("callId", entry.callId)
                    .put("ringEventId", entry.ringToken)
                    .put("expiresAt", entry.expiresAt),
            )
        }
        cancelPrefs(context).edit()
            .putString(KEY_CANCEL_ENTRIES, array.toString())
            .remove(KEY_CANCEL_CALL_ID)
            .remove(KEY_CANCEL_RING_TOKEN)
            .remove(KEY_CANCEL_EXPIRES_AT)
            .commit()
    }

    private data class State(
        val callId: String,
        val phase: String,
        val expiresAt: Long,
        val ringSentAt: Long?,
    )

    private fun readLiveState(context: Context, now: Long): State? {
        val prefs = prefs(context)
        val callId = prefs.getString(KEY_CALL_ID, null)?.trim().orEmpty()
        val phase = prefs.getString(KEY_PHASE, null)?.trim().orEmpty()
        val expiresAt = prefs.getLong(KEY_EXPIRES_AT, 0L)
        val ringSentAt = prefs.getLong(KEY_RING_SENT_AT, 0L).takeIf { it > 0L }
        if (callId.isEmpty() || phase.isEmpty() || expiresAt <= now) {
            if (callId.isNotEmpty() || phase.isNotEmpty() || expiresAt > 0L) {
                prefs.edit().clear().apply()
            }
            return null
        }
        return State(
            callId = callId,
            phase = phase,
            expiresAt = expiresAt,
            ringSentAt = ringSentAt,
        )
    }

    fun ringEventIdForCall(context: Context, callId: String): String? = synchronized(lock) {
        val state = readLiveState(context, System.currentTimeMillis()) ?: return@synchronized null
        if (state.callId != callId) return@synchronized null
        normalizeRingEventId(currentRingToken(context))
    }

    fun canPresentCallAttempt(
        context: Context,
        callId: String,
        ringEventId: String?,
    ): Boolean = synchronized(lock) {
        val now = System.currentTimeMillis()
        val normalizedRingEventId = normalizeRingEventId(ringEventId)
        val state = readLiveState(context, now)
        if (state != null) {
            return@synchronized sameCallAttempt(
                state.callId,
                currentRingToken(context),
                callId,
                normalizedRingEventId,
            ) || (state.callId == callId &&
                canPromoteRingAttempt(currentRingToken(context), normalizedRingEventId))
        }
        normalizedRingEventId == null ||
            !isCancelledRing(context, callId, normalizedRingEventId, now)
    }

    private fun currentRingToken(context: Context): String? =
        normalizeRingEventId(prefs(context).getString(KEY_RING_TOKEN, null))

    private fun writeState(
        context: Context,
        callId: String,
        phase: String,
        expiresAt: Long,
        ringToken: String?,
        ringSentAt: Long? = null,
    ) {
        prefs(context).edit()
            .putString(KEY_CALL_ID, callId)
            .putString(KEY_PHASE, phase)
            .putLong(KEY_EXPIRES_AT, expiresAt)
            .apply {
                if (ringToken.isNullOrBlank()) remove(KEY_RING_TOKEN)
                else putString(KEY_RING_TOKEN, ringToken)
                if (ringSentAt == null || ringSentAt <= 0L) remove(KEY_RING_SENT_AT)
                else putLong(KEY_RING_SENT_AT, ringSentAt)
            }
            .apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun cancelPrefs(context: Context) =
        context.applicationContext.getSharedPreferences(CANCEL_PREFS, Context.MODE_PRIVATE)

    private fun endedPrefs(context: Context) =
        context.applicationContext.getSharedPreferences(ENDED_PREFS, Context.MODE_PRIVATE)
}

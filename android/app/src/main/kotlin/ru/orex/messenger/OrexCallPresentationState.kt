package ru.orex.messenger

import android.content.Context
import android.util.Log

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
    private const val KEY_CALL_ID = "call_id"
    private const val KEY_PHASE = "phase"
    private const val KEY_EXPIRES_AT = "expires_at"
    private const val KEY_RING_TOKEN = "ring_token"
    private const val KEY_CANCEL_CALL_ID = "cancel_call_id"
    private const val KEY_CANCEL_RING_TOKEN = "cancel_ring_token"
    private const val KEY_CANCEL_EXPIRES_AT = "cancel_expires_at"

    private const val PHASE_RINGING = "ringing"
    private const val PHASE_ANSWERING = "answering"
    private const val PHASE_ACTIVE = "active"

    private const val DEFAULT_RING_WINDOW_MS = 45_000L
    private const val CANCEL_TOMBSTONE_WINDOW_MS = 120_000L
    private const val ANSWER_WINDOW_MS = 120_000L
    private const val ACTIVE_WINDOW_MS = 12 * 60 * 60 * 1000L

    private val lock = Any()

    fun claimPushRing(
        context: Context,
        callId: String,
        ringToken: String?,
        timeoutAfterMs: Long,
        refreshOnly: Boolean = false,
    ): IncomingDecision = synchronized(lock) {
        val now = System.currentTimeMillis()
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
                    val sameAttempt = ringToken.isNullOrBlank() ||
                        currentToken.isNullOrBlank() ||
                        currentToken == ringToken
                    return@synchronized if (sameAttempt) {
                        if (currentToken.isNullOrBlank() && !ringToken.isNullOrBlank()) {
                            writeState(
                                context = context,
                                callId = state.callId,
                                phase = state.phase,
                                expiresAt = state.expiresAt,
                                ringToken = ringToken,
                            )
                        }
                        IncomingDecision.SILENT_REFRESH
                    } else {
                        IncomingDecision.SUPPRESS
                    }
                }
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
        )
        IncomingDecision.FIRST_ALERT
    }

    fun claimTelecomRing(context: Context, callId: String): IncomingDecision = synchronized(lock) {
        val now = System.currentTimeMillis()
        val state = readLiveState(context, now)
        if (state != null) {
            if (state.callId == callId) {
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
            ringToken = null,
        )
        IncomingDecision.FIRST_ALERT
    }

    fun markAnswering(context: Context, callId: String) = synchronized(lock) {
        val now = System.currentTimeMillis()
        writeState(
            context = context,
            callId = callId,
            phase = PHASE_ANSWERING,
            expiresAt = now + ANSWER_WINDOW_MS,
            ringToken = currentRingToken(context),
        )
    }

    fun markActive(context: Context, callId: String) = synchronized(lock) {
        val now = System.currentTimeMillis()
        writeState(
            context = context,
            callId = callId,
            phase = PHASE_ACTIVE,
            expiresAt = now + ACTIVE_WINDOW_MS,
            ringToken = currentRingToken(context),
        )
    }

    fun markEnded(context: Context, callId: String? = null) = synchronized(lock) {
        val prefs = prefs(context)
        val currentCallId = prefs.getString(KEY_CALL_ID, null)
        if (callId != null && currentCallId != null && currentCallId != callId) return@synchronized
        prefs.edit().clear().apply()
    }

    fun isAnsweringOrActive(context: Context, callId: String): Boolean = synchronized(lock) {
        val state = readLiveState(context, System.currentTimeMillis()) ?: return@synchronized false
        state.callId == callId && (state.phase == PHASE_ANSWERING || state.phase == PHASE_ACTIVE)
    }

    fun canCancelPresentation(context: Context, callId: String): Boolean = synchronized(lock) {
        val state = readLiveState(context, System.currentTimeMillis())
        state == null || state.callId == callId
    }

    fun cancelRingIfMatches(
        context: Context,
        callId: String,
        ringToken: String,
    ): Boolean = synchronized(lock) {
        val now = System.currentTimeMillis()
        rememberCancelledRing(context, callId, ringToken, now)
        val state = readLiveState(context, now) ?: return@synchronized false
        val currentToken = currentRingToken(context)
        if (state.callId != callId ||
            state.phase != PHASE_RINGING ||
            currentToken.isNullOrBlank() ||
            currentToken != ringToken
        ) {
            return@synchronized false
        }
        prefs(context).edit().clear().apply()
        true
    }

    private fun rememberCancelledRing(
        context: Context,
        callId: String,
        ringToken: String,
        now: Long,
    ) {
        if (callId.isBlank() || ringToken.isBlank()) return
        cancelPrefs(context).edit()
            .putString(KEY_CANCEL_CALL_ID, callId)
            .putString(KEY_CANCEL_RING_TOKEN, ringToken)
            .putLong(KEY_CANCEL_EXPIRES_AT, now + CANCEL_TOMBSTONE_WINDOW_MS)
            .apply()
    }

    private fun isCancelledRing(
        context: Context,
        callId: String,
        ringToken: String,
        now: Long,
    ): Boolean {
        val prefs = cancelPrefs(context)
        val expiresAt = prefs.getLong(KEY_CANCEL_EXPIRES_AT, 0L)
        if (expiresAt <= now) {
            if (expiresAt > 0L) prefs.edit().clear().apply()
            return false
        }
        return prefs.getString(KEY_CANCEL_CALL_ID, null) == callId &&
            prefs.getString(KEY_CANCEL_RING_TOKEN, null) == ringToken
    }

    private data class State(
        val callId: String,
        val phase: String,
        val expiresAt: Long,
    )

    private fun readLiveState(context: Context, now: Long): State? {
        val prefs = prefs(context)
        val callId = prefs.getString(KEY_CALL_ID, null)?.trim().orEmpty()
        val phase = prefs.getString(KEY_PHASE, null)?.trim().orEmpty()
        val expiresAt = prefs.getLong(KEY_EXPIRES_AT, 0L)
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
        )
    }

    private fun currentRingToken(context: Context): String? =
        prefs(context).getString(KEY_RING_TOKEN, null)

    private fun writeState(
        context: Context,
        callId: String,
        phase: String,
        expiresAt: Long,
        ringToken: String?,
    ) {
        prefs(context).edit()
            .putString(KEY_CALL_ID, callId)
            .putString(KEY_PHASE, phase)
            .putLong(KEY_EXPIRES_AT, expiresAt)
            .apply {
                if (ringToken.isNullOrBlank()) remove(KEY_RING_TOKEN)
                else putString(KEY_RING_TOKEN, ringToken)
            }
            .apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun cancelPrefs(context: Context) =
        context.applicationContext.getSharedPreferences(CANCEL_PREFS, Context.MODE_PRIVATE)
}

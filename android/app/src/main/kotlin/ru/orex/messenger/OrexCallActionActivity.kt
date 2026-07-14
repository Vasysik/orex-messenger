package ru.orex.messenger

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log

/**
 * Invisible trampoline for notification call actions.
 *
 * Content taps open [OrexIncomingCallActivity]. Answer/Reject do not: the user
 * has already chosen an action, so showing the incoming panel again is both
 * confusing and race-prone. Answer is persisted for the process-owned call
 * runtime first; opening MainActivity under a native connecting cover is only
 * presentation. A locked device still requires normal unlock.
 */
class OrexCallActionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handle(intent)
        finish()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
        finish()
    }

    private fun handle(source: Intent) {
        val callId = source.getStringExtra(EXTRA_CALL_ID)?.trim().orEmpty()
        val ringEventId = normalizeRingEventId(source.getStringExtra(EXTRA_RING_EVENT_ID))
        val action = source.getStringExtra(EXTRA_ACTION)?.trim().orEmpty()
        if (callId.isEmpty() || action.isEmpty()) return

        val displayName = source.getStringExtra(EXTRA_DISPLAY_NAME)
            ?.trim()
            .orEmpty()
            .ifEmpty { "Orex" }
        val video = source.getBooleanExtra(EXTRA_VIDEO, false)
        val systemManaged = source.getBooleanExtra(EXTRA_SYSTEM_MANAGED, false)

        when (action) {
            ACTION_ANSWER, ACTION_ANSWER_VIDEO -> {
                val useVideo = action == ACTION_ANSWER_VIDEO || video
                if (!OrexCallPresentationState.markAnswering(
                        applicationContext,
                        callId,
                        ringEventId,
                    )
                ) return
                val foregroundStarted = OrexCallForegroundService.startAnswering(
                    context = applicationContext,
                    callId = callId,
                    ringEventId = ringEventId,
                    displayName = displayName,
                    video = useVideo,
                )
                if (!foregroundStarted) {
                    OrexCallPresentationState.markEnded(
                        applicationContext,
                        callId,
                        ringEventId,
                    )
                    return
                }
                OrexNotificationCenter.cancelCallNotification(applicationContext)
                val launched = if (systemManaged) {
                    // Publish the explicit user choice before MainActivity can
                    // resume. Flutter then suppresses any stale incoming route
                    // while Core-Telecom completes the same idempotent answer.
                    OrexPushBridge.queueIncomingCallAction(
                        context = this,
                        callId = callId,
                        ringEventId = ringEventId,
                        displayName = displayName,
                        video = useVideo,
                        action = ACTION_ANSWER,
                        fromSystem = true,
                    )
                    OrexAndroidTelecomManager.handleNotificationAction(
                        Intent().apply {
                            this.action = OrexAndroidTelecomManager.ACTION_ANSWER
                            putExtra(OrexAndroidTelecomManager.EXTRA_CALL_ID, callId)
                            ringEventId?.let {
                                putExtra(OrexAndroidTelecomManager.EXTRA_RING_EVENT_ID, it)
                            }
                        },
                    )
                    OrexPushBridge.bringCallHandoffToFront(
                        context = this,
                        callId = callId,
                        ringEventId = ringEventId,
                        displayName = displayName,
                    )
                } else {
                    OrexPushBridge.launchIncomingCallAction(
                        context = this,
                        callId = callId,
                        ringEventId = ringEventId,
                        displayName = displayName,
                        video = useVideo,
                        action = "answer",
                        fromSystem = false,
                        bringUiToFront = true,
                    )
                }
                if (!launched) {
                    // Call execution is already queued in the process runtime;
                    // expanded UI is best-effort only.
                    Log.w(TAG, "Accepted call queued without expanded UI $callId")
                }
            }

            ACTION_REJECT -> {
                if (!OrexCallPresentationState.markEnded(
                        applicationContext,
                        callId,
                        ringEventId,
                    )
                ) return
                OrexNotificationCenter.cancelCallNotification(applicationContext)
                if (systemManaged) {
                    OrexAndroidTelecomManager.handleNotificationAction(
                        Intent().apply {
                            this.action = OrexAndroidTelecomManager.ACTION_DECLINE
                            putExtra(OrexAndroidTelecomManager.EXTRA_CALL_ID, callId)
                            ringEventId?.let {
                                putExtra(OrexAndroidTelecomManager.EXTRA_RING_EVENT_ID, it)
                            }
                        },
                    )
                } else {
                    OrexPushBridge.launchIncomingCallAction(
                        context = this,
                        callId = callId,
                        ringEventId = ringEventId,
                        displayName = displayName,
                        video = video,
                        action = "reject",
                        fromSystem = false,
                        bringUiToFront = false,
                    )
                }
            }
        }
    }

    companion object {
        private const val TAG = "OrexCallAction"
        private const val EXTRA_CALL_ID = "orex_call_id"
        private const val EXTRA_RING_EVENT_ID = "orex_ring_event_id"
        private const val EXTRA_DISPLAY_NAME = "orex_display_name"
        private const val EXTRA_VIDEO = "orex_video"
        private const val EXTRA_ACTION = "orex_action"
        private const val EXTRA_SYSTEM_MANAGED = "orex_system_managed"
        private const val ACTION_ANSWER = "answer"
        private const val ACTION_ANSWER_VIDEO = "answer_video"
        private const val ACTION_REJECT = "reject"

        fun createIntent(
            context: Context,
            callId: String,
            ringEventId: String? = null,
            displayName: String,
            video: Boolean,
            action: String,
            systemManaged: Boolean,
        ): Intent = Intent(context, OrexCallActionActivity::class.java).apply {
            putExtra(EXTRA_CALL_ID, callId)
            normalizeRingEventId(ringEventId)?.let { putExtra(EXTRA_RING_EVENT_ID, it) }
            putExtra(EXTRA_DISPLAY_NAME, displayName)
            putExtra(EXTRA_VIDEO, video)
            putExtra(EXTRA_ACTION, action)
            putExtra(EXTRA_SYSTEM_MANAGED, systemManaged)
        }
    }
}

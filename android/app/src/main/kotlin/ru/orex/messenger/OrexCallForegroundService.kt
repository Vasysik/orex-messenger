package ru.orex.messenger

import android.Manifest
import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Foreground owner активного звонка Orex.
 *
 * Это process-level owner звонка. Service первым входит в foreground, затем
 * гарантирует запуск единственного FlutterEngine, где живут Matrix sync,
 * CallController и LiveKit. Activity только присоединяет UI к уже работающему
 * runtime и не является условием принятия/продолжения звонка.
 */
class OrexCallForegroundService : Service() {
    private val heartbeatHandler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var answerWatchdog: Runnable? = null
    private val heartbeat = object : Runnable {
        override fun run() {
            val descriptor = readDescriptor(this@OrexCallForegroundService)
            if (descriptor == null) {
                heartbeatHandler.removeCallbacks(this)
                return
            }
            if (shouldExpireAnsweringCall(
                    incoming = descriptor.incoming,
                    answered = descriptor.answered,
                    startedAt = descriptor.startedAt,
                    now = System.currentTimeMillis(),
                    timeoutMs = ANSWERING_TIMEOUT_MS,
                )
            ) {
                expireAnsweringAttempt(descriptor, "native answer watchdog")
                return
            }
            val refreshed = descriptor.copy(updatedAt = System.currentTimeMillis())
            persistDescriptor(this@OrexCallForegroundService, refreshed)
            if (foregroundReady && sameOrPromotableCallAttempt(
                    foregroundReadyCallId,
                    foregroundReadyRingEventId,
                    refreshed.callId,
                    refreshed.ringEventId,
                )
            ) {
                foregroundReadyUpdatedAt = refreshed.updatedAt
            }
            ensureForegroundNotificationVisible(refreshed)
            ensureCallRuntimeStarted(refreshed)
            heartbeatHandler.postDelayed(this, HEARTBEAT_INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        clearForegroundReadiness()
        serviceRunning = true
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val descriptor = readDescriptor(this)
        if (descriptor == null) {
            clearForegroundReadiness()
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }
        if (shouldExpireAnsweringCall(
                incoming = descriptor.incoming,
                answered = descriptor.answered,
                startedAt = descriptor.startedAt,
                now = System.currentTimeMillis(),
                timeoutMs = ANSWERING_TIMEOUT_MS,
            )
        ) {
            expireAnsweringAttempt(descriptor, "stale service restart")
            return START_NOT_STICKY
        }

        acquireCallWakeLock()
        startHeartbeat()
        val notification = takePendingNotification()
            ?: rebuildNotification(descriptor)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    OrexNotificationCenter.ONGOING_CALL_NOTIFICATION_ID,
                    notification,
                    foregroundServiceType(descriptor),
                )
            } else {
                startForeground(
                    OrexNotificationCenter.ONGOING_CALL_NOTIFICATION_ID,
                    notification,
                )
            }
            foregroundReadyCallId = descriptor.callId
            foregroundReadyRingEventId = normalizeRingEventId(descriptor.ringEventId)
            foregroundReadyUpdatedAt = descriptor.updatedAt
            foregroundReady = true
            logNotificationVisibilityConstraints()
            // The foreground descriptor is the native source of truth while
            // Flutter/Telecom callbacks race. As soon as answer/start reaches
            // this service, suppress and close every stale incoming surface for
            // the same Matrix room.
            val presentationMatched = if (descriptor.answered) {
                OrexCallPresentationState.markActive(
                    this,
                    descriptor.callId,
                    descriptor.ringEventId,
                )
            } else if (descriptor.incoming) {
                OrexCallPresentationState.markAnswering(
                    this,
                    descriptor.callId,
                    descriptor.ringEventId,
                )
            } else {
                true
            }
            if (presentationMatched && (descriptor.answered || descriptor.incoming)) {
                // The foreground owner silences duplicate ringing, but it must
                // not tear down the native connecting shell. Only Flutter's
                // callUiReady handshake may reveal the expanded call route.
                OrexNotificationCenter.cancelCallNotification(this)
            }
            Log.i(
                TAG,
                "Foreground call notification active call=${descriptor.callId} " +
                    "answered=${descriptor.answered} mic=${descriptor.micEnabled} " +
                    "audio=${descriptor.audioEnabled}",
            )
            scheduleAnswerWatchdog(descriptor)
            ensureCallRuntimeStarted(descriptor)
        } catch (error: Throwable) {
            Log.e(TAG, "Failed to enter call foreground state", error)
            failForegroundOwnership(descriptor)
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    private fun foregroundServiceType(descriptor: Descriptor): Int {
        var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return type

        // phoneCall keeps the call visible to the system, but Android 11+
        // separately classifies the resources that must keep working after
        // the activity is backgrounded. Declare only capabilities whose
        // runtime permissions are actually granted.
        if (descriptor.answered && descriptor.micEnabled &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
        ) {
            type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        if (descriptor.answered && descriptor.cameraEnabled &&
            checkSelfPermission(Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED
        ) {
            type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        }
        return type
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val descriptor = readDescriptor(this)
        if (descriptor != null) {
            val refreshed = descriptor.copy(updatedAt = System.currentTimeMillis())
            persistDescriptor(this, refreshed)
            ensureForegroundNotificationVisible(refreshed)
            scheduleAnswerWatchdog(refreshed)
            ensureCallRuntimeStarted(refreshed)
            Log.i(TAG, "Call task removed; foreground media runtime retained call=${descriptor.callId}")
        }
        super.onTaskRemoved(rootIntent)
    }

    private fun logNotificationVisibilityConstraints() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(
                TAG,
                "POST_NOTIFICATIONS denied: call service is active, but Android may hide " +
                    "its notification from the notification drawer",
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(android.app.NotificationManager::class.java)
            val channel = manager.getNotificationChannel(
                OrexNotificationCenter.ONGOING_CALL_CHANNEL_ID,
            )
            if (channel?.importance == android.app.NotificationManager.IMPORTANCE_NONE) {
                Log.w(TAG, "Ongoing-call notification channel is disabled by the user")
            }
        }
    }

    private fun failForegroundOwnership(descriptor: Descriptor) {
        clearForegroundReadiness()
        OrexPushBridge.cancelPendingCallAction(
            context = applicationContext,
            callId = descriptor.callId,
            ringEventId = descriptor.ringEventId,
        )
        OrexCallPresentationState.markEnded(
            context = applicationContext,
            callId = descriptor.callId,
            ringEventId = descriptor.ringEventId,
            endedAt = System.currentTimeMillis(),
        )
        val current = readDescriptor(applicationContext)
        if (current != null && sameOrPromotableCallAttempt(
                current.callId,
                current.ringEventId,
                descriptor.callId,
                descriptor.ringEventId,
            )
        ) {
            clearDescriptor(applicationContext)
        }
        pendingNotification = null
        OrexNotificationCenter.cancelCallNotification(applicationContext)
        OrexNotificationCenter.cancelOngoingCallNotification(applicationContext)
        OrexIncomingCallActivity.onAnswerBootstrapFailed(
            descriptor.callId,
            descriptor.ringEventId,
        )
        stopForegroundCompat()
        stopSelf()
    }

    private fun ensureForegroundNotificationVisible(descriptor: Descriptor) {
        val manager = getSystemService(android.app.NotificationManager::class.java)
        val visible = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                manager.activeNotifications.any {
                    it.id == OrexNotificationCenter.ONGOING_CALL_NOTIFICATION_ID
                }
            } catch (_: Throwable) {
                false
            }
        } else {
            false
        }
        if (visible) return
        try {
            val notification = rebuildNotification(descriptor)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    OrexNotificationCenter.ONGOING_CALL_NOTIFICATION_ID,
                    notification,
                    foregroundServiceType(descriptor),
                )
            } else {
                startForeground(OrexNotificationCenter.ONGOING_CALL_NOTIFICATION_ID, notification)
            }
            Log.i(TAG, "Reposted missing ongoing call notification call=${descriptor.callId}")
        } catch (error: Throwable) {
            Log.w(TAG, "Failed to restore ongoing call notification", error)
        }
    }

    private fun ensureCallRuntimeStarted(descriptor: Descriptor) {
        val wasRunning = OrexFlutterEngineOwner.isRunning()
        heartbeatHandler.post {
            if (readDescriptor(this)?.let {
                    sameCallAttempt(
                        it.callId,
                        it.ringEventId,
                        descriptor.callId,
                        descriptor.ringEventId,
                    ) || (it.callId == descriptor.callId &&
                        canPromoteRingAttempt(it.ringEventId, descriptor.ringEventId))
                } != true
            ) return@post
            if (OrexFlutterEngineOwner.ensureStarted(applicationContext) && !wasRunning) {
                Log.i(TAG, "Process call runtime active call=${descriptor.callId}")
            }
        }
    }

    private fun scheduleAnswerWatchdog(descriptor: Descriptor) {
        answerWatchdog?.let(heartbeatHandler::removeCallbacks)
        answerWatchdog = null
        if (!descriptor.incoming || descriptor.answered) return
        val remaining = (descriptor.startedAt + ANSWERING_TIMEOUT_MS - System.currentTimeMillis())
            .coerceAtLeast(0L)
        answerWatchdog = Runnable {
            val current = readDescriptor(this) ?: return@Runnable
            val matches = sameCallAttempt(
                current.callId,
                current.ringEventId,
                descriptor.callId,
                descriptor.ringEventId,
            ) || (current.callId == descriptor.callId &&
                canPromoteRingAttempt(current.ringEventId, descriptor.ringEventId))
            if (!matches) return@Runnable
            if (shouldExpireAnsweringCall(
                    incoming = current.incoming,
                    answered = current.answered,
                    startedAt = current.startedAt,
                    now = System.currentTimeMillis(),
                    timeoutMs = ANSWERING_TIMEOUT_MS,
                )
            ) {
                expireAnsweringAttempt(current, "native answer watchdog")
            }
        }.also { heartbeatHandler.postDelayed(it, remaining) }
    }

    private fun expireAnsweringAttempt(descriptor: Descriptor, reason: String) {
        clearForegroundReadiness()
        Log.e(TAG, "Expiring unanswered call bootstrap call=${descriptor.callId} reason=$reason")
        OrexPushBridge.cancelPendingCallAction(
            context = applicationContext,
            callId = descriptor.callId,
            ringEventId = descriptor.ringEventId,
        )
        OrexCallPresentationState.markEnded(
            context = applicationContext,
            callId = descriptor.callId,
            ringEventId = descriptor.ringEventId,
            endedAt = System.currentTimeMillis(),
        )
        clearDescriptor(applicationContext)
        pendingNotification = null
        OrexNotificationCenter.cancelCallNotification(applicationContext)
        OrexNotificationCenter.cancelOngoingCallNotification(applicationContext)
        OrexIncomingCallActivity.onAnswerBootstrapFailed(
            descriptor.callId,
            descriptor.ringEventId,
        )
        stopForegroundCompat()
        stopSelf()
    }

    override fun onDestroy() {
        clearForegroundReadiness()
        serviceRunning = false
        pendingNotification = null
        heartbeatHandler.removeCallbacks(heartbeat)
        answerWatchdog?.let(heartbeatHandler::removeCallbacks)
        answerWatchdog = null
        releaseCallWakeLock()
        stopForegroundCompat()
        super.onDestroy()
    }

    private fun rebuildNotification(descriptor: Descriptor): Notification {
        val openApp = OrexPushBridge.incomingCallPendingIntent(
            context = this,
            callId = descriptor.callId,
            ringEventId = descriptor.ringEventId,
            displayName = descriptor.displayName,
            video = descriptor.video,
            action = "resume",
            requestCode = 7200,
        )
        val toggleMic = OrexPushBridge.callActionPendingIntent(
            context = this,
            callId = descriptor.callId,
            ringEventId = descriptor.ringEventId,
            displayName = descriptor.displayName,
            video = descriptor.video,
            action = "toggle_mic",
            requestCode = 7201,
        )
        val toggleAudio = OrexPushBridge.callActionPendingIntent(
            context = this,
            callId = descriptor.callId,
            ringEventId = descriptor.ringEventId,
            displayName = descriptor.displayName,
            video = descriptor.video,
            action = "toggle_audio",
            requestCode = 7202,
        )
        val hangUp = OrexPushBridge.callActionPendingIntent(
            context = this,
            callId = descriptor.callId,
            ringEventId = descriptor.ringEventId,
            displayName = descriptor.displayName,
            video = descriptor.video,
            action = "hangup",
            requestCode = 7203,
        )
        return OrexNotificationCenter.buildForegroundCallFallback(
            context = this,
            displayName = descriptor.displayName,
            openApp = openApp,
            hangUp = hangUp,
            toggleMic = toggleMic,
            toggleAudio = toggleAudio,
            startedAt = descriptor.startedAt,
            answered = descriptor.answered,
            micEnabled = descriptor.micEnabled,
            audioEnabled = descriptor.audioEnabled,
        )
    }

    private fun startHeartbeat() {
        heartbeatHandler.removeCallbacks(heartbeat)
        heartbeatHandler.postDelayed(heartbeat, HEARTBEAT_INTERVAL_MS)
    }

    private fun acquireCallWakeLock() {
        if (wakeLock?.isHeld == true) return
        val manager = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        wakeLock = manager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:active-call",
        ).apply {
            setReferenceCounted(false)
            try {
                acquire()
            } catch (error: Throwable) {
                Log.w(TAG, "Failed to acquire active-call wake lock", error)
            }
        }
    }

    private fun releaseCallWakeLock() {
        val current = wakeLock
        wakeLock = null
        if (current?.isHeld != true) return
        try {
            current.release()
        } catch (error: Throwable) {
            Log.w(TAG, "Failed to release active-call wake lock", error)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    data class Descriptor(
        val callId: String,
        val displayName: String,
        val incoming: Boolean,
        val video: Boolean,
        val answered: Boolean,
        val startedAt: Long,
        val micEnabled: Boolean,
        val audioEnabled: Boolean,
        val cameraEnabled: Boolean,
        val updatedAt: Long,
        val ringEventId: String? = null,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "callId" to callId,
            "ringEventId" to ringEventId,
            "displayName" to displayName,
            "incoming" to incoming,
            "video" to video,
            "answered" to answered,
            "startedAt" to startedAt,
            "micEnabled" to micEnabled,
            "audioEnabled" to audioEnabled,
            "cameraEnabled" to cameraEnabled,
            "updatedAt" to updatedAt,
        )
    }

    companion object {
        private const val TAG = "OrexCallService"
        private const val ACTION_START = "ru.orex.messenger.action.START_CALL_SERVICE"
        private const val PREFS = "orex_active_call_v1"
        private const val KEY_CALL_ID = "call_id"
        private const val KEY_RING_EVENT_ID = "ring_event_id"
        private const val KEY_DISPLAY_NAME = "display_name"
        private const val KEY_INCOMING = "incoming"
        private const val KEY_VIDEO = "video"
        private const val KEY_ANSWERED = "answered"
        private const val KEY_STARTED_AT = "started_at"
        private const val KEY_MIC_ENABLED = "mic_enabled"
        private const val KEY_AUDIO_ENABLED = "audio_enabled"
        private const val KEY_CAMERA_ENABLED = "camera_enabled"
        private const val KEY_UPDATED_AT = "updated_at"
        private const val HEARTBEAT_INTERVAL_MS = 60_000L
        private const val DESCRIPTOR_STALE_MS = 3 * HEARTBEAT_INTERVAL_MS
        const val ANSWERING_TIMEOUT_MS = 35_000L

        @Volatile
        private var pendingNotification: Notification? = null

        @Volatile
        private var serviceRunning: Boolean = false

        @Volatile
        private var foregroundReady: Boolean = false

        @Volatile
        private var foregroundReadyCallId: String? = null

        @Volatile
        private var foregroundReadyRingEventId: String? = null

        @Volatile
        private var foregroundReadyUpdatedAt: Long = 0L

        private fun clearForegroundReadiness() {
            foregroundReady = false
            foregroundReadyCallId = null
            foregroundReadyRingEventId = null
            foregroundReadyUpdatedAt = 0L
        }

        fun startAnswering(
            context: Context,
            callId: String,
            ringEventId: String?,
            displayName: String,
            video: Boolean,
        ): Boolean {
            val now = System.currentTimeMillis()
            return update(
                context = context,
                descriptor = Descriptor(
                    callId = callId,
                    ringEventId = normalizeRingEventId(ringEventId),
                    displayName = displayName,
                    incoming = true,
                    video = video,
                    answered = false,
                    startedAt = now,
                    micEnabled = false,
                    audioEnabled = true,
                    cameraEnabled = false,
                    updatedAt = now,
                ),
                notification = null,
            )
        }

        fun republish(context: Context): Boolean {
            val descriptor = readDescriptor(context) ?: return false
            return update(
                context,
                descriptor.copy(updatedAt = System.currentTimeMillis()),
                notification = null,
            )
        }

        fun update(
            context: Context,
            descriptor: Descriptor,
            notification: Notification?,
        ): Boolean {
            val current = readDescriptor(context)
            if (current != null &&
                !sameCallAttempt(
                    current.callId,
                    current.ringEventId,
                    descriptor.callId,
                    descriptor.ringEventId,
                )
            ) {
                val isOneWayAttemptUpgrade = current.callId == descriptor.callId &&
                    canPromoteRingAttempt(
                        current.ringEventId,
                        descriptor.ringEventId,
                    )
                val currentHasLiveOwner = hasLiveCall(context)
                val mayReplace = shouldReplaceForegroundDescriptor(
                    currentCallId = current.callId,
                    currentRingEventId = current.ringEventId,
                    requestedCallId = descriptor.callId,
                    requestedRingEventId = descriptor.ringEventId,
                    hasLiveOwner = currentHasLiveOwner,
                )
                if (!isOneWayAttemptUpgrade && !mayReplace) return false
                if (mayReplace) {
                    Log.i(
                        TAG,
                        "Replacing stale foreground descriptor for fresh call attempt " +
                            "call=${descriptor.callId}",
                    )
                    clearDescriptor(context)
                }
            }
            // Every update needs a fresh acknowledgement from onStartCommand.
            // Identity alone is insufficient for repeated room calls because local
            // outgoing attempts intentionally have no Matrix ring event id.
            clearForegroundReadiness()
            persistDescriptor(context, descriptor)
            pendingNotification = notification
            val intent = Intent(context, OrexCallForegroundService::class.java).apply {
                action = ACTION_START
            }
            return try {
                ContextCompat.startForegroundService(context, intent)
                true
            } catch (error: Throwable) {
                Log.e(TAG, "Failed to start call foreground service", error)
                val stored = readDescriptor(context)
                if (stored != null && (
                        sameCallAttempt(
                            stored.callId,
                            stored.ringEventId,
                            descriptor.callId,
                            descriptor.ringEventId,
                        ) || (stored.callId == descriptor.callId &&
                            canPromoteRingAttempt(stored.ringEventId, descriptor.ringEventId))
                    )
                ) {
                    clearForegroundReadiness()
                    clearDescriptor(context)
                    pendingNotification = null
                }
                false
            }
        }

        fun stop(
            context: Context,
            callId: String?,
            ringEventId: String? = null,
        ): Boolean {
            val current = readDescriptor(context)
            if (callId != null && current != null &&
                !sameCallAttempt(
                    current.callId,
                    current.ringEventId,
                    callId,
                    ringEventId,
                )
            ) {
                val canPromoteAttempt = current.callId == callId &&
                    canPromoteRingAttempt(current.ringEventId, ringEventId)
                if (!canPromoteAttempt) return false
            }
            val endedCallId = current?.callId ?: callId
            val endedRingEventId = normalizeRingEventId(ringEventId) ?: current?.ringEventId
            var presentationMatched = false
            if (!endedCallId.isNullOrBlank()) {
                presentationMatched = OrexCallPresentationState.markEnded(
                    context = context,
                    callId = endedCallId,
                    ringEventId = endedRingEventId,
                    endedAt = System.currentTimeMillis(),
                )
            }
            if (!shouldApplyForegroundStop(
                    descriptorMatched = current != null,
                    presentationMatched = presentationMatched,
                )
            ) return false
            clearForegroundReadiness()
            clearDescriptor(context)
            pendingNotification = null
            context.stopService(Intent(context, OrexCallForegroundService::class.java))
            OrexNotificationCenter.cancelOngoingCallNotification(context)
            return true
        }

        fun isForegroundReady(
            context: Context,
            callId: String,
            ringEventId: String? = null,
        ): Boolean {
            if (!serviceRunning || !foregroundReady) return false
            if (!sameOrPromotableCallAttempt(
                    foregroundReadyCallId,
                    foregroundReadyRingEventId,
                    callId,
                    ringEventId,
                )
            ) return false
            val descriptor = readDescriptor(context) ?: return false
            if (foregroundReadyUpdatedAt < descriptor.updatedAt) return false
            if (!sameOrPromotableCallAttempt(
                    descriptor.callId,
                    descriptor.ringEventId,
                    callId,
                    ringEventId,
                )
            ) return false
            val now = System.currentTimeMillis()
            if (shouldExpireAnsweringCall(
                    incoming = descriptor.incoming,
                    answered = descriptor.answered,
                    startedAt = descriptor.startedAt,
                    now = now,
                    timeoutMs = ANSWERING_TIMEOUT_MS,
                )
            ) return false
            return now - descriptor.updatedAt <= DESCRIPTOR_STALE_MS
        }

        fun hasLiveCall(context: Context): Boolean {
            if (!serviceRunning) return false
            val descriptor = readDescriptor(context) ?: return false
            return System.currentTimeMillis() - descriptor.updatedAt <= DESCRIPTOR_STALE_MS
        }

        /**
         * Activity teardown must retain the engine as soon as a descriptor was
         * committed, even if startForegroundService has not reached onCreate yet.
         */
        fun shouldRetainRuntime(context: Context): Boolean {
            val descriptor = readDescriptor(context) ?: return false
            val now = System.currentTimeMillis()
            if (shouldExpireAnsweringCall(
                    incoming = descriptor.incoming,
                    answered = descriptor.answered,
                    startedAt = descriptor.startedAt,
                    now = now,
                    timeoutMs = ANSWERING_TIMEOUT_MS,
                )
            ) return false
            return now - descriptor.updatedAt <= DESCRIPTOR_STALE_MS
        }

        fun isAnsweredCall(
            context: Context,
            callId: String,
            ringEventId: String? = null,
        ): Boolean {
            val descriptor = readDescriptor(context) ?: return false
            val matches = sameCallAttempt(
                descriptor.callId,
                descriptor.ringEventId,
                callId,
                ringEventId,
            ) || (descriptor.callId == callId &&
                canPromoteRingAttempt(descriptor.ringEventId, ringEventId))
            return matches && descriptor.answered &&
                System.currentTimeMillis() - descriptor.updatedAt <= DESCRIPTOR_STALE_MS
        }

        fun ownsCall(
            context: Context,
            callId: String,
            ringEventId: String? = null,
        ): Boolean {
            var descriptor = readDescriptor(context) ?: return false
            if (!sameCallAttempt(
                    descriptor.callId,
                    descriptor.ringEventId,
                    callId,
                    ringEventId,
                )
            ) {
                val canPromoteAttempt = descriptor.callId == callId &&
                    canPromoteRingAttempt(descriptor.ringEventId, ringEventId)
                if (!canPromoteAttempt) return false
                descriptor = descriptor.copy(ringEventId = normalizeRingEventId(ringEventId))
                persistDescriptor(context, descriptor)
            }
            val now = System.currentTimeMillis()
            if (shouldExpireAnsweringCall(
                    incoming = descriptor.incoming,
                    answered = descriptor.answered,
                    startedAt = descriptor.startedAt,
                    now = now,
                    timeoutMs = ANSWERING_TIMEOUT_MS,
                )
            ) return false
            return now - descriptor.updatedAt <= DESCRIPTOR_STALE_MS
        }

        fun readRecovery(context: Context): Map<String, Any?>? =
            readDescriptor(context)?.toMap()

        fun clearRecovery(
            context: Context,
            callId: String?,
            ringEventId: String? = null,
        ): Boolean {
            val current = readDescriptor(context) ?: return false
            val normalizedCallId = callId?.trim()?.ifEmpty { null } ?: return false
            if (!sameCallAttempt(
                    current.callId,
                    current.ringEventId,
                    normalizedCallId,
                    ringEventId,
                )
            ) {
                val canPromoteAttempt = current.callId == normalizedCallId &&
                    canPromoteRingAttempt(current.ringEventId, ringEventId)
                if (!canPromoteAttempt) return false
            }
            return stop(context, callId, ringEventId)
        }

        fun ringEventIdForCall(context: Context, callId: String): String? {
            val descriptor = readDescriptor(context) ?: return null
            if (descriptor.callId != callId) return null
            return descriptor.ringEventId
        }

        private fun takePendingNotification(): Notification? =
            pendingNotification.also { pendingNotification = null }

        private fun persistDescriptor(context: Context, descriptor: Descriptor) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_CALL_ID, descriptor.callId)
                .apply {
                    val ringEventId = normalizeRingEventId(descriptor.ringEventId)
                    if (ringEventId == null) remove(KEY_RING_EVENT_ID)
                    else putString(KEY_RING_EVENT_ID, ringEventId)
                }
                .putString(KEY_DISPLAY_NAME, descriptor.displayName)
                .putBoolean(KEY_INCOMING, descriptor.incoming)
                .putBoolean(KEY_VIDEO, descriptor.video)
                .putBoolean(KEY_ANSWERED, descriptor.answered)
                .putLong(KEY_STARTED_AT, descriptor.startedAt)
                .putBoolean(KEY_MIC_ENABLED, descriptor.micEnabled)
                .putBoolean(KEY_AUDIO_ENABLED, descriptor.audioEnabled)
                .putBoolean(KEY_CAMERA_ENABLED, descriptor.cameraEnabled)
                .putLong(KEY_UPDATED_AT, descriptor.updatedAt)
                .commit()
        }

        private fun readDescriptor(context: Context): Descriptor? {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val callId = prefs.getString(KEY_CALL_ID, null)?.trim().orEmpty()
            val displayName = prefs.getString(KEY_DISPLAY_NAME, null)?.trim().orEmpty()
            val updatedAt = prefs.getLong(KEY_UPDATED_AT, 0L)
            if (callId.isEmpty() || displayName.isEmpty() || updatedAt <= 0L) return null
            return Descriptor(
                callId = callId,
                ringEventId = normalizeRingEventId(
                    prefs.getString(KEY_RING_EVENT_ID, null),
                ),
                displayName = displayName,
                incoming = prefs.getBoolean(KEY_INCOMING, false),
                video = prefs.getBoolean(KEY_VIDEO, false),
                answered = prefs.getBoolean(KEY_ANSWERED, false),
                startedAt = prefs.getLong(KEY_STARTED_AT, updatedAt),
                micEnabled = prefs.getBoolean(KEY_MIC_ENABLED, true),
                audioEnabled = prefs.getBoolean(KEY_AUDIO_ENABLED, true),
                cameraEnabled = prefs.getBoolean(
                    KEY_CAMERA_ENABLED,
                    prefs.getBoolean(KEY_VIDEO, false),
                ),
                updatedAt = updatedAt,
            )
        }

        private fun clearDescriptor(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().commit()
        }
    }
}

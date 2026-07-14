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
 * LiveKit остаётся во Flutter-процессе, но системный phoneCall service не даёт
 * Android считать продолжающийся вызов обычной фоновой работой. Descriptor
 * сохраняется отдельно, чтобы после process recreation Flutter мог проверить
 * MatrixRTC state и безопасно переподключить media без повторного ring.
 * Для исходящего вызова service стартует уже во время подключения; recoverable
 * descriptor становится пригодным для media recovery только после answered=true.
 */
class OrexCallForegroundService : Service() {
    private val heartbeatHandler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private val heartbeat = object : Runnable {
        override fun run() {
            val descriptor = readDescriptor(this@OrexCallForegroundService)
            if (descriptor == null) {
                heartbeatHandler.removeCallbacks(this)
                return
            }
            val refreshed = descriptor.copy(updatedAt = System.currentTimeMillis())
            persistDescriptor(this@OrexCallForegroundService, refreshed)
            ensureForegroundNotificationVisible(refreshed)
            heartbeatHandler.postDelayed(this, HEARTBEAT_INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        serviceRunning = true
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val descriptor = readDescriptor(this)
        if (descriptor == null) {
            stopForegroundCompat()
            stopSelf()
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
            if (descriptor.answered && !OrexFlutterEngineOwner.isRunning()) {
                heartbeatHandler.post {
                    try {
                        OrexFlutterEngineOwner.getOrCreate(applicationContext)
                        Log.i(TAG, "Restarted headless Flutter call runtime")
                    } catch (error: Throwable) {
                        Log.e(TAG, "Failed to restart Flutter call runtime", error)
                    }
                }
            }
        } catch (error: Throwable) {
            Log.e(TAG, "Failed to enter call foreground state", error)
            stopSelf()
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
            Log.i(TAG, "Call task removed; foreground media runtime retained call=${descriptor.callId}")
        }
        super.onTaskRemoved(rootIntent)
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

    override fun onDestroy() {
        serviceRunning = false
        pendingNotification = null
        heartbeatHandler.removeCallbacks(heartbeat)
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

        @Volatile
        private var pendingNotification: Notification? = null

        @Volatile
        private var serviceRunning: Boolean = false

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
                val currentHasLiveOwner = serviceRunning &&
                    System.currentTimeMillis() - current.updatedAt <= DESCRIPTOR_STALE_MS
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
            clearDescriptor(context)
            pendingNotification = null
            context.stopService(Intent(context, OrexCallForegroundService::class.java))
            OrexNotificationCenter.cancelOngoingCallNotification(context)
            return true
        }

        fun hasLiveCall(context: Context): Boolean {
            if (!serviceRunning) return false
            val descriptor = readDescriptor(context) ?: return false
            return System.currentTimeMillis() - descriptor.updatedAt <= DESCRIPTOR_STALE_MS
        }

        fun ownsCall(
            context: Context,
            callId: String,
            ringEventId: String? = null,
        ): Boolean {
            if (!serviceRunning) return false
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
            return System.currentTimeMillis() - descriptor.updatedAt <= DESCRIPTOR_STALE_MS
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

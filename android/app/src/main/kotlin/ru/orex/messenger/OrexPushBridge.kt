package ru.orex.messenger

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.UUID

/**
 * Нативная граница push lifecycle.
 *
 * Звонки публикуются сразу из FCM. Сообщения, которым нужна Matrix/E2EE
 * расшифровка, передаются в expedited WorkManager и никогда не блокируют
 * FirebaseMessagingService.
 */
object OrexPushBridge {
    private const val TAG = "OrexPush"
    private const val CHANNEL_NAME = "orex/push"
    private const val PREFS_NAME = "orex_push_native_v2"
    private const val PREF_TOKEN = "fcm_token"
    private const val PREF_PENDING_OPEN = "pending_open"
    private const val EXTRA_OPEN = "orex_push_open"
    private const val EXTRA_PREFIX = "orex_push_payload_"
    private const val DELIVERY_ID_KEY = "orex_delivery_id"
    private const val PERMISSION_REQUEST_CODE = 46041
    private const val ACTION_CALL_NOTIFICATION = "ru.orex.messenger.action.PUSH_CALL"
    const val ACTION_RESTORE_ONGOING_CALL_NOTIFICATION =
        "ru.orex.messenger.action.RESTORE_ONGOING_CALL_NOTIFICATION"
    private const val UI_RESOLVE_TIMEOUT_MS = 40_000L

    private const val MAX_PAYLOAD_ENTRIES = 48
    private const val MAX_PAYLOAD_KEY_LENGTH = 96
    private const val MAX_PAYLOAD_VALUE_LENGTH = 8192

    private val OPEN_PAYLOAD_KEYS = setOf(
        "orex_kind",
        "orex_action",
        "room_id",
        "event_id",
        "call_id",
        "message_id",
        "orex_from_system",
        "orex_video",
    )
    private val PAYLOAD_PRIORITY_KEYS = listOf(
        *OPEN_PAYLOAD_KEYS.toTypedArray(),
        "type",
        "event_type",
        "notification_type",
        "notify_type",
        "orex_call_action",
        "orex_call_refresh",
        "orex_ring_event_id",
        "orex_ring_ts_ms",
        "content_orex_call_action",
        "content_orex_ring_event_id",
        "content_notification_type",
        "content_notify_type",
        "content_sender_ts",
        "content_lifetime",
        "content_m.call.intent",
        "content_m_call_intent",
        "content_msgtype",
        "content_body",
        "content",
        "sender",
        "sender_display_name",
        "sender_avatar_key",
        "room_name",
        "room_alias",
        "origin_server_ts",
        "unread",
        "missed_calls",
        "prio",
        "title",
        "body",
        "orex_sent_time_ms",
        "orex_ttl_seconds",
    )
    private val PAYLOAD_KEY_PATTERN = Regex("[A-Za-z0-9_.-]+")

    private var activity: Activity? = null
    private var applicationContext: Context? = null
    private var channel: MethodChannel? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var firebaseConfigurationWarningLogged = false

    private data class DeferredCallHandoffOpen(
        val callId: String,
        val ringEventId: String?,
        val payload: Map<String, String>,
        var dispatched: Boolean = false,
    )

    private val callHandoffLock = Any()
    private var deferredCallHandoffOpen: DeferredCallHandoffOpen? = null

    @Volatile
    private var activityResumed = false

    @Volatile
    private var dartBridgeReady = false

    fun attachEngine(context: Context, messenger: BinaryMessenger) {
        applicationContext = context.applicationContext
        dartBridgeReady = false
        channel?.setMethodCallHandler(null)
        channel = MethodChannel(messenger, CHANNEL_NAME).also { methodChannel ->
            methodChannel.setMethodCallHandler(::handleMethodCall)
        }
    }

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        this.activity = activity
        applicationContext = activity.applicationContext
        if (channel == null) attachEngine(activity.applicationContext, messenger)
    }

    /**
     * Detaches only the Activity projection.
     *
     * The MethodChannel belongs to [OrexFlutterEngineOwner], not to an Activity.
     * Clearing it here leaves a still-running Dart isolate unable to receive a
     * cold/background Answer command until another Activity happens to attach.
     */
    fun detach(activity: Activity) {
        if (this.activity !== activity) return
        this.activity = null
        activityResumed = false
        pendingPermissionResult = null
    }

    fun onActivityResumed(activity: Activity) {
        if (this.activity === activity) activityResumed = true
    }

    fun onActivityPaused(activity: Activity) {
        if (this.activity === activity) activityResumed = false
    }

    fun captureLaunchIntent(context: Context, intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_OPEN, false) != true) return
        val payload = extractPayload(intent)
        consumeLaunchIntent(intent)
        if (payload.isEmpty()) return
        OrexNotificationCenter.onNotificationOpened(context.applicationContext, payload)
        if (payload["orex_action"] == "answer") {
            deferNotificationOpenForCallHandoff(context.applicationContext, payload)
        } else {
            deliverNotificationOpen(context.applicationContext, payload)
        }
    }

    fun onTokenRefresh(context: Context, rawToken: String) {
        applicationContext = context.applicationContext
        val token = rawToken.trim()
        if (token.isEmpty()) return
        prefs(context).edit().putString(PREF_TOKEN, token).apply()
        Log.i(TAG, "FCM registration token refreshed")
        invokeOnMainThread("onTokenRefresh", token)
    }

    fun onMessageReceived(context: Context, message: RemoteMessage) {
        val appContext = context.applicationContext
        applicationContext = appContext
        val payload = linkedMapOf<String, String>()
        payload.putAll(message.data)
        message.messageId?.let { payload.putIfAbsent("message_id", it) }
        message.notification?.title?.let { payload.putIfAbsent("title", it) }
        message.notification?.body?.let { payload.putIfAbsent("body", it) }
        if (message.sentTime > 0L) payload["orex_sent_time_ms"] = message.sentTime.toString()
        if (message.ttl > 0) payload["orex_ttl_seconds"] = message.ttl.toString()

        val normalized = normalizePayload(payload)
        if (normalized.isEmpty()) return
        Log.i(TAG, "FCM data message received keys=${normalized.keys.sorted()}")

        // Incoming calls are latency-sensitive and already carry a dedicated
        // short-lived wake envelope. They must reach CallStyle/full-screen UI
        // immediately, without waiting for Matrix crypto startup.
        val incomingCall = OrexNotificationCenter.isIncomingCallPayload(normalized)
        if (incomingCall || OrexNotificationCenter.isRtcNotificationPayload(normalized)) {
            OrexNotificationCenter.showPush(appContext, normalized, activityResumed)
            // A call envelope is complete enough for native presentation. Never
            // start the headless Matrix Flutter engine merely to resolve an avatar:
            // it can overlap the process-owned call engine during cold Answer and
            // contend for the same encrypted Matrix database/plugins.
            return
        }

        if (OrexNotificationCenter.canRenderMessageDirectly(normalized)) {
            OrexNotificationCenter.showPush(appContext, normalized, activityResumed)
            return
        }

        if (OrexNotificationCenter.needsBackgroundResolution(normalized)) {
            OrexPushResolveWorker.enqueue(appContext, normalized)
            return
        }

        OrexNotificationCenter.showPush(appContext, normalized, activityResumed)
    }

    fun resolvePushPayload(
        context: Context,
        payload: Map<String, String>,
        callback: (Map<String, String>?) -> Unit,
    ) {
        val normalized = normalizePayload(payload)
        if (normalized.isEmpty()) {
            callback(null)
            return
        }
        val uiChannel = channel
        if (uiChannel == null) {
            resolveWithAvailableRuntime(context, normalized, callback)
            return
        }

        val handler = Handler(Looper.getMainLooper())
        handler.post {
            if (channel !== uiChannel) {
                resolveWithAvailableRuntime(context, normalized, callback)
                return@post
            }

            var finished = false
            val fallback = Runnable {
                if (finished) return@Runnable
                finished = true
                Log.w(TAG, "Live Flutter resolver timed out; worker will retry without racing the Matrix DB")
                callback(null)
            }
            handler.postDelayed(fallback, UI_RESOLVE_TIMEOUT_MS)

            uiChannel.invokeMethod(
                "resolvePush",
                normalized,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (finished) return
                        finished = true
                        handler.removeCallbacks(fallback)
                        val resolved = stringMap(result)
                        if (resolved.isEmpty()) {
                            resolveWithAvailableRuntime(context, normalized, callback)
                        } else {
                            callback(resolved)
                        }
                    }

                    override fun error(
                        errorCode: String,
                        errorMessage: String?,
                        errorDetails: Any?,
                    ) {
                        if (finished) return
                        finished = true
                        handler.removeCallbacks(fallback)
                        Log.w(TAG, "Live Flutter resolver failed: $errorCode $errorMessage")
                        resolveWithAvailableRuntime(context, normalized, callback)
                    }

                    override fun notImplemented() {
                        if (finished) return
                        finished = true
                        handler.removeCallbacks(fallback)
                        resolveWithAvailableRuntime(context, normalized, callback)
                    }
                },
            )
        }
    }

    private fun resolveWithAvailableRuntime(
        context: Context,
        payload: Map<String, String>,
        callback: (Map<String, String>?) -> Unit,
    ) {
        if (OrexFlutterEngineOwner.isRunning()) {
            // The process isolate exists but its Dart channel is still booting or
            // temporarily unavailable. Returning null makes WorkManager retry and
            // preserves the single-engine database ownership invariant.
            callback(null)
            return
        }
        OrexPushBackgroundResolver.resolve(context, payload, callback)
    }

    fun handleResolvedPush(context: Context, resolved: Map<String, String>) {
        val payload = normalizePayload(resolved)
        if (payload.isEmpty() || payload["orex_drop"].equals("true", ignoreCase = true)) {
            Log.i(TAG, "Resolved Matrix push suppressed: ${payload["orex_drop_reason"] ?: "empty"}")
            return
        }
        OrexNotificationCenter.showPush(
            context = context.applicationContext,
            payload = payload,
            appResumed = activityResumed,
        )
    }

    fun isAppResumed(): Boolean = activityResumed

    fun notificationOpenPendingIntent(
        context: Context,
        payload: Map<String, String>,
        requestCode: Int,
    ): PendingIntent {
        return PendingIntent.getActivity(
            context,
            requestCode,
            buildOpenIntent(context, payload, action = null),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun incomingCallPendingIntent(
        context: Context,
        callId: String,
        displayName: String,
        video: Boolean,
        action: String?,
        requestCode: Int,
        fromSystem: Boolean = false,
        ringEventId: String? = null,
        avatarCacheKey: String? = null,
    ): PendingIntent {
        val payload = incomingCallPayload(
            callId = callId,
            ringEventId = ringEventId,
            displayName = displayName,
            video = video,
            fromSystem = fromSystem,
            avatarCacheKey = avatarCacheKey,
        )
        return PendingIntent.getActivity(
            context,
            callAttemptRequestCode(requestCode, callId, ringEventId),
            buildOpenIntent(context, payload, action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun incomingCallScreenPendingIntent(
        context: Context,
        callId: String,
        displayName: String,
        video: Boolean,
        timeoutAfterMs: Long,
        requestCode: Int,
        action: String? = null,
        systemManaged: Boolean = false,
        ringEventId: String? = null,
        avatarCacheKey: String? = null,
    ): PendingIntent {
        val intent = OrexIncomingCallActivity.createIntent(
            context = context,
            callId = callId,
            ringEventId = ringEventId,
            displayName = displayName,
            video = video,
            timeoutAfterMs = timeoutAfterMs,
            action = action,
            systemManaged = systemManaged,
            avatarCacheKey = avatarCacheKey,
        )
        return PendingIntent.getActivity(
            context,
            callAttemptRequestCode(requestCode, callId, ringEventId),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun incomingCallActionPendingIntent(
        context: Context,
        callId: String,
        displayName: String,
        video: Boolean,
        action: String,
        requestCode: Int,
        systemManaged: Boolean = false,
        ringEventId: String? = null,
    ): PendingIntent {
        // Android 12+ blocks notification trampolines: a notification action
        // must launch an Activity directly instead of entering a receiver which
        // then calls startActivity(). This invisible Activity persists Answer,
        // starts the foreground call runtime and opens MainActivity. Because it
        // is not showWhenLocked, Android requests the normal device unlock first.
        val intent = OrexCallActionActivity.createIntent(
            context = context,
            callId = callId,
            ringEventId = ringEventId,
            displayName = displayName,
            video = video,
            action = action,
            systemManaged = systemManaged,
        )
        return PendingIntent.getActivity(
            context,
            callAttemptRequestCode(requestCode, callId, ringEventId),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun restoreOngoingCallNotificationPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, OrexNotificationActionReceiver::class.java).apply {
            action = ACTION_RESTORE_ONGOING_CALL_NOTIFICATION
        }
        return PendingIntent.getBroadcast(
            context,
            7299,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun callActionPendingIntent(
        context: Context,
        callId: String,
        displayName: String,
        video: Boolean,
        action: String,
        requestCode: Int,
        ringEventId: String? = null,
    ): PendingIntent {
        val payload = incomingCallPayload(
            callId = callId,
            ringEventId = ringEventId,
            displayName = displayName,
            video = video,
            fromSystem = false,
        )
        val intent = Intent(context, OrexNotificationActionReceiver::class.java).apply {
            this.action = ACTION_CALL_NOTIFICATION
            putExtra(EXTRA_OPEN, true)
            for ((key, value) in openPayload(payload, action)) {
                putExtra("$EXTRA_PREFIX$key", value)
            }
        }
        return PendingIntent.getBroadcast(
            context,
            callAttemptRequestCode(requestCode, callId, ringEventId),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun handleCallNotificationAction(context: Context, intent: Intent) {
        if (intent.action == ACTION_RESTORE_ONGOING_CALL_NOTIFICATION) {
            OrexCallForegroundService.republish(context.applicationContext)
            return
        }
        if (intent.action == OrexAndroidTelecomManager.ACTION_ANSWER ||
            intent.action == OrexAndroidTelecomManager.ACTION_DECLINE ||
            intent.action == OrexAndroidTelecomManager.ACTION_HANG_UP ||
            intent.action == OrexAndroidTelecomManager.ACTION_TOGGLE_MIC ||
            intent.action == OrexAndroidTelecomManager.ACTION_TOGGLE_AUDIO
        ) {
            OrexAndroidTelecomManager.handleNotificationAction(intent)
            return
        }
        if (intent.action != ACTION_CALL_NOTIFICATION) return
        val payload = extractPayload(intent)
        if (payload.isEmpty()) return
        val action = payload["orex_action"] ?: return
        val launched = launchIncomingCallAction(
            context = context,
            callId = payload["call_id"] ?: payload["room_id"] ?: return,
            ringEventId = payload["event_id"],
            displayName = payload["sender_display_name"] ?: "Orex",
            video = payload["orex_video"].equals("true", ignoreCase = true),
            action = action,
            fromSystem = payload["orex_from_system"].equals("true", ignoreCase = true),
        )
        if (!launched) {
            deliverNotificationOpen(context.applicationContext, payload)
        }
    }

    fun queueIncomingCallAction(
        context: Context,
        callId: String,
        displayName: String,
        video: Boolean,
        action: String,
        fromSystem: Boolean,
        ringEventId: String? = null,
    ) {
        val payload = incomingCallPayload(
            callId = callId,
            ringEventId = ringEventId,
            displayName = displayName,
            video = video,
            fromSystem = fromSystem,
        )
        val open = openPayload(payload, action)
        if (action == "answer") {
            deferNotificationOpenForCallHandoff(context.applicationContext, open)
        } else {
            deliverNotificationOpen(context.applicationContext, open)
        }
    }

    fun launchIncomingCallAction(
        context: Context,
        callId: String,
        displayName: String,
        video: Boolean,
        action: String,
        fromSystem: Boolean,
        bringUiToFront: Boolean = action == "answer",
        ringEventId: String? = null,
    ): Boolean {
        return when (action) {
            "answer", "answer_video" -> acceptIncomingCallFromNativeAction(
                context = context,
                callId = callId,
                ringEventId = ringEventId,
                displayName = displayName,
                video = action == "answer_video" || video,
                fromSystem = fromSystem,
                bringUiToFront = bringUiToFront,
            )
            else -> {
                val payload = incomingCallPayload(
                    callId = callId,
                    ringEventId = ringEventId,
                    displayName = displayName,
                    video = video,
                    fromSystem = fromSystem,
                )
                deliverNotificationOpen(context.applicationContext, openPayload(payload, action))
                if (!bringUiToFront && channel != null) true else bringAppToFront(context)
            }
        }
    }

    fun acceptIncomingCallFromNativeAction(
        context: Context,
        callId: String,
        ringEventId: String?,
        displayName: String,
        video: Boolean,
        fromSystem: Boolean,
        bringUiToFront: Boolean,
    ): Boolean {
        val appContext = context.applicationContext
        if (!OrexCallPresentationState.markAnswering(appContext, callId, ringEventId)) {
            Log.i(TAG, "Ignoring accepted call action for non-presentable attempt call=$callId")
            return false
        }
        val foregroundStarted = OrexCallForegroundService.startAnswering(
            context = appContext,
            callId = callId,
            ringEventId = ringEventId,
            displayName = displayName,
            video = video,
        )
        if (!foregroundStarted) {
            OrexCallPresentationState.markEnded(appContext, callId, ringEventId)
            return false
        }
        OrexNotificationCenter.cancelCallNotification(appContext)
        // The full-screen incoming activity is the only trusted surface that
        // may remain above the keyguard. Keep it alive while Flutter boots the
        // accepted call; it closes itself after callUiReady (and requests the
        // normal credential flow on a locked device).
        if (!bringUiToFront) {
            OrexIncomingCallActivity.finishForCall(callId, ringEventId)
        }
        queueIncomingCallAction(
            context = appContext,
            callId = callId,
            ringEventId = ringEventId,
            displayName = displayName,
            video = video,
            action = "answer",
            fromSystem = fromSystem,
        )
        if (fromSystem) {
            OrexAndroidTelecomManager.handleNotificationAction(
                Intent().apply {
                    action = OrexAndroidTelecomManager.ACTION_ANSWER
                    putExtra(OrexAndroidTelecomManager.EXTRA_CALL_ID, callId)
                    normalizeRingEventId(ringEventId)?.let {
                        putExtra(OrexAndroidTelecomManager.EXTRA_RING_EVENT_ID, it)
                    }
                },
            )
        }
        if (!bringUiToFront) return true
        val launched = bringCallHandoffToFront(
            context = appContext,
            callId = callId,
            ringEventId = ringEventId,
            displayName = displayName,
            avatarCacheKey = null,
        )
        if (!launched) {
            Log.w(TAG, "Accepted call queued without expanded Activity call=$callId")
        }
        return true
    }

    fun bringCallHandoffToFront(
        context: Context,
        callId: String,
        ringEventId: String?,
        displayName: String,
        avatarCacheKey: String? = null,
    ): Boolean = startMainActivity(
        context,
        Intent(context, MainActivity::class.java).apply {
            // The accepted command is persisted before this Activity launch. A
            // small native cover is nevertheless required during a cold Flutter
            // bootstrap, otherwise the launcher/splash can surface a generic
            // startup error while Matrix and the call route are still restoring.
            putExtra(MainActivity.EXTRA_CALL_HANDOFF, true)
            putExtra("orex_call_host_open", true)
            putExtra(MainActivity.EXTRA_CALL_ID, callId)
            normalizeRingEventId(ringEventId)?.let {
                putExtra(MainActivity.EXTRA_RING_EVENT_ID, it)
            }
            putExtra(MainActivity.EXTRA_DISPLAY_NAME, displayName)
            if (!avatarCacheKey.isNullOrBlank()) {
                putExtra(MainActivity.EXTRA_AVATAR_CACHE_KEY, avatarCacheKey)
            }
        },
    )

    fun bringAppToFront(context: Context): Boolean = startMainActivity(
        context,
        Intent(context, MainActivity::class.java),
    )

    private fun startMainActivity(context: Context, intent: Intent): Boolean {
        return try {
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_NO_ANIMATION
            context.startActivity(intent)
            true
        } catch (error: Throwable) {
            Log.e(TAG, "Failed to bring Orex UI to foreground", error)
            false
        }
    }

    private fun incomingCallPayload(
        callId: String,
        ringEventId: String? = null,
        displayName: String,
        video: Boolean,
        fromSystem: Boolean,
        avatarCacheKey: String? = null,
    ): Map<String, String> = linkedMapOf<String, String>().apply {
        put("orex_kind", "incoming_call")
        put("room_id", callId)
        put("call_id", callId)
        normalizeRingEventId(ringEventId)?.let { put("event_id", it) }
        put("sender_display_name", displayName)
        put("orex_video", video.toString())
        put("orex_from_system", fromSystem.toString())
        if (!avatarCacheKey.isNullOrBlank()) put("sender_avatar_key", avatarCacheKey)
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val result = pendingPermissionResult ?: return true
        pendingPermissionResult = null
        val notificationIndex = permissions.indexOf(Manifest.permission.POST_NOTIFICATIONS)
        val granted = notificationIndex >= 0 &&
            grantResults.getOrNull(notificationIndex) == PackageManager.PERMISSION_GRANTED
        if (granted) activity?.let(::maybeOpenFullScreenIntentSettings)
        result.success(if (granted) "authorized" else "denied")
        return true
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (!dartBridgeReady) {
            dartBridgeReady = true
            flushDeferredCallHandoffOpen()
        }
        when (call.method) {
            "isSupported" -> result.success(isFirebaseConfigured())
            "getToken" -> getToken(result)
            "takeInitialNotification" -> result.success(takePendingOpen())
            "ackNotificationOpen" -> {
                val deliveryId = call.argument<String>("deliveryId")?.trim().orEmpty()
                result.success(acknowledgePendingOpen(deliveryId))
            }
            "showLocalMatrixNotification" -> {
                val context = applicationContext
                val payload = stringMap(call.arguments)
                if (context == null || payload.isEmpty()) {
                    result.success(false)
                    return
                }
                OrexNotificationCenter.showPush(context, payload, appResumed = false)
                result.success(true)
            }
            "dismissRoomNotifications" -> {
                val context = applicationContext
                val roomId = call.argument<String>("roomId")?.trim().orEmpty()
                if (context != null && roomId.isNotEmpty()) {
                    OrexNotificationCenter.dismissRoomNotifications(context, roomId)
                }
                result.success(context != null && roomId.isNotEmpty())
            }
            "callUiAnswering" -> {
                val callId = call.argument<String>("callId")?.trim().orEmpty()
                val ringEventId = call.argument<String>("ringEventId")
                val context = applicationContext
                val matched = callId.isNotEmpty() && context != null &&
                    OrexCallPresentationState.markAnswering(context, callId, ringEventId)
                if (matched) {
                    OrexNotificationCenter.cancelCallNotification(context)
                }
                result.success(matched)
            }
            "callUiReady" -> {
                val callId = call.argument<String>("callId")?.trim().orEmpty()
                val ringEventId = call.argument<String>("ringEventId")
                val context = applicationContext
                val presentationMatched = callId.isNotEmpty() && context != null &&
                    OrexCallPresentationState.markActive(context, callId, ringEventId)
                val main = activity as? MainActivity
                val overlayMatched = callId.isNotEmpty() &&
                    main?.completeCallHandoff(callId, ringEventId) == true
                val accepted = presentationMatched || overlayMatched
                if (accepted && context != null) {
                    OrexIncomingCallActivity.onCallUiReady(callId, ringEventId)
                    if (!overlayMatched) {
                        bringAppToFront(context)
                    }
                }
                result.success(accepted)
            }
            "callUiEnded" -> {
                val callId = call.argument<String>("callId")?.trim().orEmpty()
                val ringEventId = call.argument<String>("ringEventId")
                val context = applicationContext
                val presentationMatched = callId.isNotEmpty() && context != null &&
                    OrexCallPresentationState.markEnded(context, callId, ringEventId)
                val overlayMatched = callId.isNotEmpty() &&
                    (activity as? MainActivity)?.cancelCallHandoff(callId, ringEventId) == true
                val ended = presentationMatched || overlayMatched
                if (ended && context != null) {
                    OrexCallForegroundService.stop(context, callId, ringEventId)
                    OrexNotificationCenter.cancelCallNotification(context)
                    OrexIncomingCallActivity.finishForCall(callId, ringEventId)
                }
                result.success(ended)
            }
            "callUiHidden" -> result.success(true)
            "requestPermission" -> requestPermission(result)
            else -> result.notImplemented()
        }
    }

    private fun isFirebaseConfigured(): Boolean {
        val context = activity?.applicationContext ?: applicationContext ?: return false
        return try {
            val configured = FirebaseApp.getApps(context).isNotEmpty()
            if (!configured && !firebaseConfigurationWarningLogged) {
                firebaseConfigurationWarningLogged = true
                Log.e(TAG, "Firebase is not configured; google-services.json is missing or invalid")
            }
            configured
        } catch (error: Throwable) {
            Log.w(TAG, "Firebase configuration check failed", error)
            false
        }
    }

    private fun getToken(result: MethodChannel.Result) {
        val context = activity?.applicationContext ?: applicationContext
        if (context == null || !isFirebaseConfigured()) {
            result.success(null)
            return
        }
        try {
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                if (task.isSuccessful) {
                    val token = task.result?.trim().orEmpty()
                    if (token.isNotEmpty()) {
                        prefs(context).edit().putString(PREF_TOKEN, token).apply()
                        Log.i(TAG, "FCM registration token is available")
                        result.success(token)
                    } else {
                        result.success(null)
                    }
                } else {
                    Log.w(TAG, "FCM token request failed", task.exception)
                    result.success(prefs(context).getString(PREF_TOKEN, null))
                }
            }
        } catch (error: Throwable) {
            Log.w(TAG, "FCM token request unavailable", error)
            result.success(prefs(context).getString(PREF_TOKEN, null))
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        val currentActivity = activity
        if (currentActivity == null) {
            result.success("not_supported")
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            maybeOpenFullScreenIntentSettings(currentActivity)
            result.success("authorized")
            return
        }
        if (currentActivity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            maybeOpenFullScreenIntentSettings(currentActivity)
            result.success("authorized")
            return
        }
        if (pendingPermissionResult != null) {
            result.error(
                "permission_request_in_progress",
                "Notification permission request is already active",
                null,
            )
            return
        }
        pendingPermissionResult = result
        currentActivity.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            PERMISSION_REQUEST_CODE,
        )
    }

    private fun maybeOpenFullScreenIntentSettings(activity: Activity) {
        if (Build.VERSION.SDK_INT < 34 || activity.isFinishing) return
        val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val allowed = try {
            manager.canUseFullScreenIntent()
        } catch (error: Throwable) {
            Log.w(TAG, "Unable to query full-screen intent access", error)
            true
        }
        if (allowed) return
        try {
            activity.startActivity(
                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                    data = Uri.parse("package:${activity.packageName}")
                },
            )
        } catch (error: Throwable) {
            Log.w(TAG, "Unable to open full-screen intent settings", error)
        }
    }

    private fun buildOpenIntent(
        context: Context,
        payload: Map<String, String>,
        action: String?,
    ): Intent = Intent(context, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        putExtra(EXTRA_OPEN, true)
        for ((key, value) in openPayload(payload, action)) {
            putExtra("$EXTRA_PREFIX$key", value)
        }
    }

    private fun deliverNotificationOpen(context: Context, payload: Map<String, String>) {
        val normalized = persistNotificationOpen(context, payload) ?: return
        dispatchNotificationOpen(normalized)
    }

    private fun deferNotificationOpenForCallHandoff(
        context: Context,
        payload: Map<String, String>,
    ) {
        val normalized = persistNotificationOpen(context, payload) ?: return
        val callId = normalized["call_id"]?.trim().orEmpty()
            .ifEmpty { normalized["room_id"]?.trim().orEmpty() }
        if (callId.isEmpty()) {
            dispatchNotificationOpen(normalized)
            return
        }
        val ringEventId = normalizeRingEventId(normalized["event_id"])
        synchronized(callHandoffLock) {
            deferredCallHandoffOpen = DeferredCallHandoffOpen(
                callId = callId,
                ringEventId = ringEventId,
                payload = normalized,
            )
        }
        flushDeferredCallHandoffOpen()
    }

    private fun persistNotificationOpen(
        context: Context,
        payload: Map<String, String>,
    ): Map<String, String>? {
        val normalized = normalizePayload(payload).toMutableMap()
        if (normalized.isEmpty()) return null
        normalized[DELIVERY_ID_KEY] = UUID.randomUUID().toString()
        prefs(context).edit().putString(PREF_PENDING_OPEN, JSONObject(normalized).toString()).apply()
        return normalized
    }

    private fun dispatchNotificationOpen(normalized: Map<String, String>) {
        Handler(Looper.getMainLooper()).post {
            val currentChannel = channel
            if (currentChannel == null) {
                val deliveryId = normalized[DELIVERY_ID_KEY]
                synchronized(callHandoffLock) {
                    deferredCallHandoffOpen?.takeIf {
                        it.payload[DELIVERY_ID_KEY] == deliveryId
                    }?.dispatched = false
                }
                return@post
            }
            currentChannel.invokeMethod(
                "onNotificationOpened",
                normalized,
                object : MethodChannel.Result {
                    override fun success(result: Any?) = Unit

                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        Log.w(TAG, "Flutter rejected notification open: $errorCode $errorMessage")
                        dartBridgeReady = false
                        rearmDeferredCallHandoff(normalized)
                    }

                    override fun notImplemented() {
                        Log.i(TAG, "Flutter call handoff bridge is not ready yet; deferring answer")
                        dartBridgeReady = false
                        rearmDeferredCallHandoff(normalized)
                    }
                },
            )
        }
    }

    private fun rearmDeferredCallHandoff(payload: Map<String, String>) {
        val deliveryId = payload[DELIVERY_ID_KEY]
        synchronized(callHandoffLock) {
            deferredCallHandoffOpen?.takeIf {
                it.payload[DELIVERY_ID_KEY] == deliveryId
            }?.dispatched = false
        }
    }

    /**
     * Removes one accepted-call command from both the in-memory handoff and the
     * process-death-safe pending-open slot. Used by native watchdogs so a later
     * app launch cannot replay an already failed answer.
     */
    fun cancelPendingCallAction(
        context: Context,
        callId: String,
        ringEventId: String?,
    ): Boolean {
        val normalizedCallId = callId.trim()
        if (normalizedCallId.isEmpty()) return false
        val normalizedRingEventId = normalizeRingEventId(ringEventId)
        var removed = synchronized(callHandoffLock) {
            var changed = false
            val deferred = deferredCallHandoffOpen
            if (deferred != null && callHandoffAttemptMatches(
                    deferred.callId,
                    deferred.ringEventId,
                    normalizedCallId,
                    normalizedRingEventId,
                )
            ) {
                deferredCallHandoffOpen = null
                changed = true
            }
            changed
        }

        val preferences = prefs(context.applicationContext)
        val encoded = preferences.getString(PREF_PENDING_OPEN, null)
        if (encoded != null) {
            val decoded = decodePayload(encoded)
            val pendingCallId = decoded["call_id"]?.trim().orEmpty()
                .ifEmpty { decoded["room_id"]?.trim().orEmpty() }
            val pendingRingEventId = normalizeRingEventId(decoded["event_id"])
            if (decoded["orex_action"] == "answer" &&
                pendingCallId.isNotEmpty() &&
                callHandoffAttemptMatches(
                    pendingCallId,
                    pendingRingEventId,
                    normalizedCallId,
                    normalizedRingEventId,
                )
            ) {
                preferences.edit().remove(PREF_PENDING_OPEN).commit()
                removed = true
            }
        }
        return removed
    }

    private fun flushDeferredCallHandoffOpen() {
        val payload = synchronized(callHandoffLock) {
            val deferred = deferredCallHandoffOpen
            if (deferred == null || deferred.dispatched || channel == null ||
                !dartBridgeReady
            ) {
                null
            } else {
                deferred.dispatched = true
                deferred.payload
            }
        }
        if (payload != null) {
            Log.i(TAG, "Dispatching accepted call to process runtime")
            dispatchNotificationOpen(payload)
        }
    }

    private fun callHandoffAttemptMatches(
        firstCallId: String?,
        firstRingEventId: String?,
        secondCallId: String,
        secondRingEventId: String?,
    ): Boolean {
        return sameOrPromotableCallAttempt(
            firstCallId,
            firstRingEventId,
            secondCallId,
            secondRingEventId,
        )
    }

    private fun takePendingOpen(): Map<String, String>? {
        val context = activity?.applicationContext ?: applicationContext ?: return null
        val preferences = prefs(context)
        val encoded = preferences.getString(PREF_PENDING_OPEN, null) ?: return null
        val decoded = decodePayload(encoded)
        if (decoded.isEmpty()) {
            preferences.edit().remove(PREF_PENDING_OPEN).apply()
            return null
        }
        if (decoded["orex_action"] == "answer") {
            val callId = decoded["call_id"]?.trim().orEmpty()
                .ifEmpty { decoded["room_id"]?.trim().orEmpty() }
            val ringEventId = normalizeRingEventId(decoded["event_id"])
            if (callId.isNotEmpty()) {
                val shouldDeliver = synchronized(callHandoffLock) {
                    val deferred = deferredCallHandoffOpen?.takeIf {
                        callHandoffAttemptMatches(
                            it.callId,
                            it.ringEventId,
                            callId,
                            ringEventId,
                        )
                    }
                    if (deferred?.dispatched == true) {
                        false
                    } else {
                        if (deferred == null) {
                            deferredCallHandoffOpen = DeferredCallHandoffOpen(
                                callId = callId,
                                ringEventId = ringEventId,
                                payload = decoded,
                                dispatched = true,
                            )
                        } else {
                            deferred.dispatched = true
                        }
                        true
                    }
                }
                if (!shouldDeliver) return null
            }
        }
        return decoded
    }

    private fun acknowledgePendingOpen(deliveryId: String): Boolean {
        if (deliveryId.isEmpty()) return false
        val context = activity?.applicationContext ?: applicationContext ?: return false
        val preferences = prefs(context)
        val encoded = preferences.getString(PREF_PENDING_OPEN, null) ?: return true
        val decoded = decodePayload(encoded)
        if (decoded.isEmpty() || decoded[DELIVERY_ID_KEY] == deliveryId) {
            preferences.edit().remove(PREF_PENDING_OPEN).apply()
            synchronized(callHandoffLock) {
                deferredCallHandoffOpen?.takeIf {
                    it.payload[DELIVERY_ID_KEY] == deliveryId
                }?.let { deferredCallHandoffOpen = null }
            }
        }
        return true
    }

    private fun consumeLaunchIntent(intent: Intent) {
        intent.removeExtra(EXTRA_OPEN)
        val keys = intent.extras?.keySet()?.toList().orEmpty()
        for (key in keys) {
            if (key.startsWith(EXTRA_PREFIX)) intent.removeExtra(key)
        }
    }

    private fun extractPayload(intent: Intent): Map<String, String> {
        val extras = intent.extras ?: return emptyMap()
        val result = linkedMapOf<String, String>()
        for (key in extras.keySet()) {
            if (!key.startsWith(EXTRA_PREFIX)) continue
            val payloadKey = key.removePrefix(EXTRA_PREFIX)
            val value = extras.get(key)?.toString() ?: continue
            result[payloadKey] = value
        }
        return normalizePayload(result)
    }

    private fun openPayload(source: Map<String, String>, action: String? = null): Map<String, String> {
        val filtered = linkedMapOf<String, String>()
        for (key in OPEN_PAYLOAD_KEYS) {
            source[key]?.let { filtered[key] = it }
        }
        if (!action.isNullOrBlank()) filtered["orex_action"] = action
        return filtered
    }

    private fun normalizePayload(source: Map<String, String>): Map<String, String> {
        val result = linkedMapOf<String, String>()
        val orderedKeys = (PAYLOAD_PRIORITY_KEYS + source.keys).distinct()
        for (rawKey in orderedKeys) {
            if (result.size >= MAX_PAYLOAD_ENTRIES) break
            val rawValue = source[rawKey] ?: continue
            val key = rawKey.trim()
            if (key.isEmpty() || key.length > MAX_PAYLOAD_KEY_LENGTH) continue
            if (!key.matches(PAYLOAD_KEY_PATTERN)) continue
            result[key] = rawValue.take(MAX_PAYLOAD_VALUE_LENGTH)
        }
        return result
    }

    private fun stringMap(raw: Any?): Map<String, String> {
        if (raw !is Map<*, *>) return emptyMap()
        val result = linkedMapOf<String, String>()
        for ((keyRaw, valueRaw) in raw) {
            val key = keyRaw?.toString()?.trim().orEmpty()
            if (key.isEmpty()) continue
            result[key] = valueRaw?.toString().orEmpty()
        }
        return normalizePayload(result)
    }

    private fun decodePayload(encoded: String): Map<String, String> {
        return try {
            val json = JSONObject(encoded)
            val result = linkedMapOf<String, String>()
            val keys = json.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                result[key] = json.optString(key, "")
            }
            normalizePayload(result)
        } catch (error: Throwable) {
            Log.w(TAG, "Failed to decode pending notification", error)
            emptyMap()
        }
    }

    private fun invokeOnMainThread(method: String, arguments: Any?) {
        Handler(Looper.getMainLooper()).post {
            channel?.invokeMethod(method, arguments)
        }
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}

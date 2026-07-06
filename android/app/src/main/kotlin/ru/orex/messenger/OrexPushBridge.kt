package ru.orex.messenger

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
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
 * Мост между нативной FCM-доставкой и Flutter.
 *
 * FCM Service живёт независимо от Activity: токен и открытый notification
 * сначала сохраняются локально, а Flutter забирает их после запуска engine.
 */
object OrexPushBridge {
    private const val TAG = "OrexPush"
    private const val CHANNEL_NAME = "orex/push"
    private const val PREFS_NAME = "orex_push_native_v1"
    private const val PREF_TOKEN = "fcm_token"
    private const val PREF_PENDING_OPEN = "pending_open"
    private const val EXTRA_OPEN = "orex_push_open"
    private const val EXTRA_PREFIX = "orex_push_payload_"
    private const val DELIVERY_ID_KEY = "orex_delivery_id"
    private const val PERMISSION_REQUEST_CODE = 46041

    private const val MESSAGE_CHANNEL_ID = "orex_messages"
    private const val CALL_CHANNEL_ID = "orex_push_calls"

    private const val MAX_PAYLOAD_ENTRIES = 32
    private const val MAX_PAYLOAD_KEY_LENGTH = 80
    private const val MAX_PAYLOAD_VALUE_LENGTH = 4096

    private val OPEN_PAYLOAD_KEYS = setOf(
        "orex_kind",
        "room_id",
        "event_id",
        "call_id",
        "message_id",
    )
    private val PAYLOAD_PRIORITY_KEYS = listOf(
        *OPEN_PAYLOAD_KEYS.toTypedArray(),
        "title",
        "body",
    )
    private val PAYLOAD_KEY_PATTERN = Regex("[A-Za-z0-9_.-]+")

    private var activity: Activity? = null
    private var channel: MethodChannel? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var firebaseConfigurationWarningLogged = false

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        this.activity = activity
        channel?.setMethodCallHandler(null)
        channel = MethodChannel(messenger, CHANNEL_NAME).also { methodChannel ->
            methodChannel.setMethodCallHandler(::handleMethodCall)
        }
    }

    fun detach(activity: Activity) {
        if (this.activity !== activity) return
        this.activity = null
        pendingPermissionResult = null
        channel?.setMethodCallHandler(null)
        channel = null
    }

    fun captureLaunchIntent(context: Context, intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_OPEN, false) != true) return
        val payload = extractPayload(intent)
        consumeLaunchIntent(intent)
        if (payload.isEmpty()) return
        deliverNotificationOpen(context.applicationContext, payload)
    }

    fun onTokenRefresh(context: Context, rawToken: String) {
        val token = rawToken.trim()
        if (token.isEmpty()) return
        prefs(context).edit().putString(PREF_TOKEN, token).apply()
        Log.i(TAG, "FCM registration token refreshed")
        invokeOnMainThread("onTokenRefresh", token)
    }

    fun onMessageReceived(context: Context, message: RemoteMessage) {
        val payload = linkedMapOf<String, String>()
        payload.putAll(message.data)
        message.messageId?.let { payload.putIfAbsent("message_id", it) }
        message.notification?.title?.let { payload.putIfAbsent("title", it) }
        message.notification?.body?.let { payload.putIfAbsent("body", it) }

        val normalized = normalizePayload(payload)
        if (normalized.isEmpty()) return
        Log.i(TAG, "FCM data message received keys=${normalized.keys.sorted()}")
        showNotification(context.applicationContext, normalized)
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
        result.success(if (granted) "authorized" else "denied")
        return true
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(isFirebaseConfigured())
            "getToken" -> getToken(result)
            "takeInitialNotification" -> result.success(takePendingOpen())
            "ackNotificationOpen" -> {
                val deliveryId = call.argument<String>("deliveryId")?.trim().orEmpty()
                result.success(acknowledgePendingOpen(deliveryId))
            }
            "requestPermission" -> requestPermission(result)
            else -> result.notImplemented()
        }
    }

    private fun isFirebaseConfigured(): Boolean {
        val context = activity?.applicationContext ?: return false
        return try {
            val configured = FirebaseApp.getApps(context).isNotEmpty()
            if (!configured && !firebaseConfigurationWarningLogged) {
                firebaseConfigurationWarningLogged = true
                Log.e(
                    TAG,
                    "Firebase is not configured; google-services.json is missing or invalid",
                )
            }
            configured
        } catch (error: Throwable) {
            Log.w(TAG, "Firebase configuration check failed", error)
            false
        }
    }

    private fun getToken(result: MethodChannel.Result) {
        val context = activity?.applicationContext
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
        if (currentActivity == null || !isFirebaseConfigured()) {
            result.success("not_supported")
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success("authorized")
            return
        }
        if (currentActivity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
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

    private fun showNotification(context: Context, payload: Map<String, String>) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        val incomingCall = payload["orex_kind"] == "incoming_call"
        val channelId = if (incomingCall) CALL_CHANNEL_ID else MESSAGE_CHANNEL_ID
        ensureNotificationChannels(manager)

        val title = boundedText(
            payload["title"],
            if (incomingCall) "Входящий звонок Orex" else "Новое событие в Orex",
            120,
        )
        val body = boundedText(
            payload["body"],
            if (incomingCall) "Откройте Orex, чтобы ответить" else "Откройте приложение, чтобы посмотреть",
            240,
        )
        val stablePayloadId = payload["event_id"]
            ?: payload["call_id"]
            ?: payload["room_id"]
            ?: payload["message_id"]
            ?: "orex-push"
        val stableId = "${payload["orex_kind"] ?: "matrix_event"}|$stablePayloadId"
        val notificationId = stableId.hashCode() and 0x7fffffff

        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_OPEN, true)
            for ((key, value) in openPayload(payload)) {
                putExtra("$EXTRA_PREFIX$key", value)
            }
        }
        val openApp = PendingIntent.getActivity(
            context,
            notificationId,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_orex)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setCategory(if (incomingCall) Notification.CATEGORY_CALL else Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            builder.setPriority(
                if (incomingCall) Notification.PRIORITY_HIGH else Notification.PRIORITY_DEFAULT,
            )
        }

        manager.notify(notificationId, builder.build())
    }

    private fun ensureNotificationChannels(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        manager.createNotificationChannels(
            listOf(
                NotificationChannel(
                    MESSAGE_CHANNEL_ID,
                    "Сообщения Orex",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "Новые сообщения и события Matrix"
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                },
                NotificationChannel(
                    CALL_CHANNEL_ID,
                    "Входящие звонки Orex",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Push-сигнал о входящем звонке при закрытом приложении"
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                },
            ),
        )
    }

    private fun deliverNotificationOpen(context: Context, payload: Map<String, String>) {
        val normalized = normalizePayload(payload).toMutableMap()
        if (normalized.isEmpty()) return
        normalized[DELIVERY_ID_KEY] = UUID.randomUUID().toString()
        val encoded = JSONObject(normalized).toString()
        prefs(context).edit().putString(PREF_PENDING_OPEN, encoded).apply()

        Handler(Looper.getMainLooper()).post {
            val currentChannel = channel ?: return@post
            currentChannel.invokeMethod(
                "onNotificationOpened",
                normalized,
                object : MethodChannel.Result {
                    override fun success(result: Any?) = Unit

                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                        Log.w(TAG, "Flutter rejected notification open: $errorCode $errorMessage")
                    }

                    override fun notImplemented() = Unit
                },
            )
        }
    }

    private fun takePendingOpen(): Map<String, String>? {
        val context = activity?.applicationContext ?: return null
        val preferences = prefs(context)
        val encoded = preferences.getString(PREF_PENDING_OPEN, null) ?: return null
        val decoded = decodePayload(encoded)
        if (decoded.isEmpty()) {
            preferences.edit().remove(PREF_PENDING_OPEN).apply()
            return null
        }
        return decoded
    }

    private fun acknowledgePendingOpen(deliveryId: String): Boolean {
        if (deliveryId.isEmpty()) return false
        val context = activity?.applicationContext ?: return false
        val preferences = prefs(context)
        val encoded = preferences.getString(PREF_PENDING_OPEN, null) ?: return true
        val decoded = decodePayload(encoded)
        if (decoded.isEmpty() || decoded[DELIVERY_ID_KEY] == deliveryId) {
            preferences.edit().remove(PREF_PENDING_OPEN).apply()
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

    private fun openPayload(source: Map<String, String>): Map<String, String> =
        source.filterKeys(OPEN_PAYLOAD_KEYS::contains)

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

    private fun boundedText(value: String?, fallback: String, maxLength: Int): String {
        val normalized = value?.replace(Regex("\\s+"), " ")?.trim().orEmpty()
        return (if (normalized.isEmpty()) fallback else normalized).take(maxLength)
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
}

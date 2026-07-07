package ru.orex.messenger

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.os.Build
import android.provider.Settings
import android.util.Log
import org.json.JSONObject
import kotlin.math.absoluteValue

/**
 * Единственная точка создания Android-уведомлений Orex.
 *
 * Push callback не открывает БД, не запускает FlutterEngine и не делает сеть:
 * он только нормализует уже доставленный Sygnal payload и сразу публикует UI.
 */
object OrexNotificationCenter {
    const val CALL_NOTIFICATION_ID = 4040
    const val MESSAGE_CHANNEL_ID = "orex_messages_v2"
    const val INCOMING_CALL_CHANNEL_ID = "orex_calls_incoming_v3"
    const val ONGOING_CALL_CHANNEL_ID = "orex_calls_ongoing_v2"

    private const val TAG = "OrexNotifications"
    private const val MESSAGE_GROUP_KEY = "orex_messages"
    private const val DEFAULT_CALL_LIFETIME_MS = 45_000L
    private const val MAX_CALL_LIFETIME_MS = 90_000L
    private const val CLOCK_SKEW_TOLERANCE_MS = 15_000L

    fun showPush(context: Context, payload: Map<String, String>, appResumed: Boolean) {
        if (isIncomingCallPayload(payload)) {
            if (isStaleIncomingCall(payload)) {
                Log.i(TAG, "Stale MatrixRTC ring ignored")
                return
            }
            showIncomingCall(context, payload)
            return
        }
        if (isRtcNotificationPayload(payload)) {
            Log.i(TAG, "Non-ringing MatrixRTC notification ignored")
            return
        }
        if (!isMessagePayload(payload)) {
            Log.i(TAG, "Non-message Matrix event ignored: ${firstValue(payload, "type", "event_type")}")
            return
        }
        if (appResumed) {
            Log.i(TAG, "Message notification suppressed while Orex is foreground")
            return
        }
        showMessage(context, payload)
    }

    fun showLocalMatrixEvent(context: Context, roomId: String, eventId: String?) {
        val payload = linkedMapOf(
            "orex_kind" to "matrix_event",
            "room_id" to roomId,
        )
        if (!eventId.isNullOrBlank()) payload["event_id"] = eventId
        showMessage(context, payload)
    }

    fun isIncomingCallPayload(payload: Map<String, String>): Boolean {
        if (payload["orex_kind"].equals("incoming_call", ignoreCase = true)) return true
        if (!isRtcNotificationPayload(payload)) return false

        val notificationType = firstValue(
            payload,
            "content_notification_type",
            "content.notification_type",
            "notification_type",
            "content_notify_type",
            "content.notify_type",
            "notify_type",
        ) ?: contentString(payload, "notification_type", "notify_type")

        // Sygnal FCM v1 may flatten or omit arbitrary nested content fields.
        // Orex only emits m.rtc.notification as the targeted ring wake envelope,
        // so the event type itself is the reliable killed-process fallback.
        return notificationType == null || notificationType.equals("ring", ignoreCase = true)
    }


    private fun isRtcNotificationPayload(payload: Map<String, String>): Boolean {
        val eventType = firstValue(payload, "type", "event_type")?.lowercase()
        return eventType == "m.rtc.notification" ||
            eventType == "org.matrix.msc4075.rtc.notification"
    }

    private fun isMessagePayload(payload: Map<String, String>): Boolean {
        if (payload["orex_kind"].equals("matrix_event", ignoreCase = true)) return true
        return when (firstValue(payload, "type", "event_type")?.lowercase()) {
            "m.room.message",
            "m.sticker",
            "m.room.encrypted",
            "m.message",
            "m.file",
            "m.image",
            "m.audio",
            "m.video",
            "m.location",
            "m.poll.start",
            "org.matrix.msc1767.message",
            "org.matrix.msc1767.file",
            "org.matrix.msc1767.image",
            "org.matrix.msc1767.audio",
            "org.matrix.msc1767.video",
            "org.matrix.msc1767.location",
            "org.matrix.msc3381.poll.start" -> true
            else -> false
        }
    }

    fun showTelecomCall(
        context: Context,
        callId: String,
        displayName: String,
        video: Boolean,
        incoming: Boolean,
        answered: Boolean,
        answer: PendingIntent,
        decline: PendingIntent,
        hangUp: PendingIntent,
    ) {
        if (!canPostNotifications(context)) return
        ensureChannels(context)
        val openApp = OrexPushBridge.incomingCallPendingIntent(
            context = context,
            callId = callId,
            displayName = displayName,
            video = video,
            action = null,
            requestCode = 7000,
        )
        postCall(
            context = context,
            displayName = displayName,
            incoming = incoming && !answered,
            openApp = openApp,
            answer = answer,
            decline = decline,
            hangUp = hangUp,
            timeoutAfterMs = null,
        )
    }

    fun cancelCall(context: Context) {
        notificationManager(context).cancel(CALL_NOTIFICATION_ID)
    }

    private fun showIncomingCall(context: Context, payload: Map<String, String>) {
        if (!canPostNotifications(context)) return
        ensureChannels(context)
        val callId = firstValue(payload, "room_id", "call_id", "event_id") ?: return
        val displayName = callerDisplayName(payload)
        val video = isVideoCall(payload)
        val openApp = OrexPushBridge.incomingCallPendingIntent(
            context = context,
            callId = callId,
            displayName = displayName,
            video = video,
            action = null,
            requestCode = 6100,
        )
        val answer = OrexPushBridge.callActionPendingIntent(
            context = context,
            callId = callId,
            displayName = displayName,
            video = video,
            action = "answer",
            requestCode = 6101,
        )
        val decline = OrexPushBridge.callActionPendingIntent(
            context = context,
            callId = callId,
            displayName = displayName,
            video = video,
            action = "reject",
            requestCode = 6102,
        )
        postCall(
            context = context,
            displayName = displayName,
            incoming = true,
            openApp = openApp,
            answer = answer,
            decline = decline,
            hangUp = null,
            timeoutAfterMs = remainingCallLifetimeMs(payload),
        )
        Log.i(TAG, "Incoming call notification posted")
    }

    private fun postCall(
        context: Context,
        displayName: String,
        incoming: Boolean,
        openApp: PendingIntent,
        answer: PendingIntent,
        decline: PendingIntent,
        hangUp: PendingIntent?,
        timeoutAfterMs: Long?,
    ) {
        val channelId = if (incoming) INCOMING_CALL_CHANNEL_ID else ONGOING_CALL_CHANNEL_ID
        val builder = builder(context, channelId)
            .setSmallIcon(R.drawable.ic_stat_orex)
            .setContentTitle(displayName)
            .setContentText(if (incoming) "Входящий звонок" else "Звонок Orex")
            .setContentIntent(openApp)
            .setCategory(Notification.CATEGORY_CALL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)

        if (timeoutAfterMs != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setTimeoutAfter(timeoutAfterMs.coerceAtLeast(1_000L))
        }

        if (incoming && canUseFullScreenIntent(context)) {
            builder.setFullScreenIntent(openApp, true)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder()
                .setName(displayName)
                .setImportant(true)
                .build()
            val style = if (incoming) {
                Notification.CallStyle.forIncomingCall(person, decline, answer)
            } else {
                val disconnect = hangUp ?: decline
                Notification.CallStyle.forOngoingCall(person, disconnect)
            }
            builder.setStyle(style)
        } else if (incoming) {
            builder
                .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Отклонить", decline)
                .addAction(android.R.drawable.sym_action_call, "Ответить", answer)
        } else if (hangUp != null) {
            builder.addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Завершить",
                hangUp,
            )
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            builder.setPriority(if (incoming) Notification.PRIORITY_MAX else Notification.PRIORITY_DEFAULT)
        }

        val notification = builder.build().apply {
            if (incoming) flags = flags or Notification.FLAG_INSISTENT
        }
        notificationManager(context).notify(CALL_NOTIFICATION_ID, notification)
    }

    private fun showMessage(context: Context, payload: Map<String, String>) {
        if (!canPostNotifications(context)) return
        ensureChannels(context)
        val title = messageTitle(payload)
        val body = messageBody(payload)
        val stableId = firstValue(payload, "room_id", "event_id", "message_id") ?: body
        val notificationId = ("message|$stableId".hashCode().absoluteValue).coerceAtLeast(1)
        val openApp = OrexPushBridge.notificationOpenPendingIntent(
            context = context,
            payload = payload,
            requestCode = notificationId,
        )
        val timestamp = eventTimestamp(payload)
        val builder = builder(context, MESSAGE_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_orex)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(openApp)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setAutoCancel(true)
            .setOnlyAlertOnce(false)
            .setGroup(MESSAGE_GROUP_KEY)
            .setWhen(timestamp)
            .setShowWhen(true)

        val senderName = callerDisplayName(payload)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val user = Person.Builder().setName("Orex").build()
            val sender = Person.Builder().setName(senderName).build()
            builder.setStyle(
                Notification.MessagingStyle(user)
                    .setConversationTitle(title.takeIf { it != senderName })
                    .addMessage(Notification.MessagingStyle.Message(body, timestamp, sender)),
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            @Suppress("DEPRECATION")
            builder.setStyle(
                Notification.MessagingStyle("Orex")
                    .setConversationTitle(title.takeIf { it != senderName })
                    .addMessage(body, timestamp, senderName),
            )
        } else {
            builder.setStyle(Notification.BigTextStyle().bigText(body))
        }

        notificationManager(context).notify(notificationId, builder.build())
        Log.i(TAG, "Message notification posted")
    }

    private fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = notificationManager(context)
        val ringtoneAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

        manager.createNotificationChannels(
            listOf(
                NotificationChannel(
                    MESSAGE_CHANNEL_ID,
                    "Сообщения Orex",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "Личные сообщения, комнаты и события Matrix"
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                    enableVibration(true)
                },
                NotificationChannel(
                    INCOMING_CALL_CHANNEL_ID,
                    "Входящие звонки Orex",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Входящие аудио- и видеозвонки"
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0L, 700L, 500L, 700L)
                    setSound(Settings.System.DEFAULT_RINGTONE_URI, ringtoneAttributes)
                },
                NotificationChannel(
                    ONGOING_CALL_CHANNEL_ID,
                    "Активные звонки Orex",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "Текущий звонок Orex"
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    enableVibration(false)
                    setSound(null, null)
                },
            ),
        )
    }

    private fun isStaleIncomingCall(payload: Map<String, String>): Boolean {
        val remaining = remainingCallLifetimeMs(payload)
        return remaining <= 0L
    }

    private fun remainingCallLifetimeMs(payload: Map<String, String>): Long {
        val now = System.currentTimeMillis()
        val senderTs = firstLong(payload, "content_sender_ts", "content.sender_ts", "sender_ts")
            ?: contentLong(payload, "sender_ts")
        val requestedLifetime = firstLong(
            payload,
            "content_lifetime",
            "content.lifetime",
            "lifetime",
        ) ?: contentLong(payload, "lifetime")
        val lifetime = (requestedLifetime ?: DEFAULT_CALL_LIFETIME_MS)
            .coerceIn(1_000L, MAX_CALL_LIFETIME_MS)
        if (senderTs != null) {
            return senderTs + lifetime + CLOCK_SKEW_TOLERANCE_MS - now
        }

        val sentTime = firstLong(payload, "orex_sent_time_ms")
        if (sentTime != null && sentTime > 0L) {
            return sentTime + lifetime - now
        }
        return lifetime
    }

    private fun isVideoCall(payload: Map<String, String>): Boolean {
        if (payload["orex_video"].equals("true", ignoreCase = true)) return true
        val intent = firstValue(
            payload,
            "content_m.call.intent",
            "content_m_call_intent",
            "m.call.intent",
            "call_intent",
        ) ?: contentString(payload, "m.call.intent", "call_intent")
        return intent.equals("video", ignoreCase = true)
    }

    private fun messageTitle(payload: Map<String, String>): String {
        firstValue(payload, "title")?.let { return boundedText(it, "Новое сообщение", 120) }
        val sender = callerDisplayName(payload).takeIf { it != "Orex" }
        val room = firstValue(payload, "room_name", "room_alias")
        return boundedText(
            when {
                sender != null && room != null && sender != room -> "$sender · $room"
                sender != null -> sender
                room != null -> room
                else -> "Новое сообщение"
            },
            "Новое сообщение",
            120,
        )
    }

    private fun messageBody(payload: Map<String, String>): String {
        val body = firstValue(payload, "body", "content_body", "content.body")
            ?: contentString(payload, "body")
        if (body != null) return boundedText(body, "Новое сообщение", 500)
        val eventType = firstValue(payload, "type", "event_type")
        val fallback = if (eventType == "m.room.encrypted") {
            "Новое зашифрованное сообщение"
        } else {
            "Новое сообщение"
        }
        return fallback
    }

    private fun callerDisplayName(payload: Map<String, String>): String {
        return firstValue(payload, "sender_display_name", "sender", "room_name") ?: "Orex"
    }

    private fun eventTimestamp(payload: Map<String, String>): Long {
        return firstLong(payload, "origin_server_ts", "event_ts", "orex_sent_time_ms")
            ?.takeIf { it > 0L }
            ?: System.currentTimeMillis()
    }

    private fun contentJson(payload: Map<String, String>): JSONObject? {
        val raw = payload["content"]?.trim().orEmpty()
        if (raw.isEmpty() || !raw.startsWith("{")) return null
        return try {
            JSONObject(raw)
        } catch (_: Throwable) {
            null
        }
    }

    private fun contentString(payload: Map<String, String>, vararg keys: String): String? {
        val json = contentJson(payload) ?: return null
        for (key in keys) {
            val value = json.opt(key) ?: continue
            if (value === JSONObject.NULL) continue
            value.toString().trim().takeIf { it.isNotEmpty() }?.let { return it }
        }
        return null
    }

    private fun contentLong(payload: Map<String, String>, vararg keys: String): Long? =
        contentString(payload, *keys)?.toLongOrNull()

    private fun firstValue(payload: Map<String, String>, vararg keys: String): String? {
        for (key in keys) {
            payload[key]?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
        }
        return null
    }

    private fun firstLong(payload: Map<String, String>, vararg keys: String): Long? =
        firstValue(payload, *keys)?.toLongOrNull()

    private fun canPostNotifications(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        val granted = context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) Log.w(TAG, "Notification dropped: POST_NOTIFICATIONS is not granted")
        return granted
    }

    private fun canUseFullScreenIntent(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        return try {
            notificationManager(context).canUseFullScreenIntent()
        } catch (error: Throwable) {
            Log.w(TAG, "Full-screen intent capability check failed", error)
            false
        }
    }

    private fun builder(context: Context, channelId: String): Notification.Builder {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
    }

    private fun notificationManager(context: Context): NotificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun boundedText(value: String?, fallback: String, maxLength: Int): String {
        val normalized = value?.replace(Regex("\\s+"), " ")?.trim().orEmpty()
        return (if (normalized.isEmpty()) fallback else normalized).take(maxLength)
    }
}

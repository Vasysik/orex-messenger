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
import android.graphics.drawable.Icon
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.Person as CompatPerson
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.absoluteValue

/**
 * Единственная точка создания Android-уведомлений Orex.
 *
 * Звонки публикуются сразу. Сообщения попадают сюда только когда payload уже
 * содержит реальный plaintext или после Matrix/E2EE resolution worker.
 */
object OrexNotificationCenter {
    const val INCOMING_CALL_NOTIFICATION_ID = 4040
    const val ONGOING_CALL_NOTIFICATION_ID = 4041
    const val MESSAGE_CHANNEL_ID = "orex_messages_v3"
    const val INCOMING_CALL_CHANNEL_ID = "orex_calls_incoming_v4"
    const val ONGOING_CALL_CHANNEL_ID = "orex_calls_ongoing_v2"

    private const val TAG = "OrexNotifications"
    private const val MESSAGE_GROUP_KEY = "orex_messages"
    private const val MESSAGE_HISTORY_PREFS = "orex_message_history_v3"
    private const val MAX_HISTORY_MESSAGES = 6
    private const val DEFAULT_CALL_LIFETIME_MS = 45_000L
    private const val MAX_CALL_LIFETIME_MS = 90_000L
    private const val CLOCK_SKEW_TOLERANCE_MS = 15_000L

    fun showPush(context: Context, payload: Map<String, String>, appResumed: Boolean) {
        if (isCallRingCancellationPayload(payload)) {
            val callId = firstValue(payload, "room_id", "call_id")
            val ringEventId = firstValue(
                payload,
                "content_orex_ring_event_id",
                "content.orex_ring_event_id",
                "orex_ring_event_id",
            ) ?: contentString(payload, "orex_ring_event_id")
            if (callId != null && ringEventId != null) {
                val cancelled = OrexCallPresentationState.cancelRingIfMatches(
                    context,
                    callId,
                    ringEventId,
                )
                if (cancelled) {
                    cancelCallNotification(context)
                    OrexIncomingCallActivity.finishForCall(callId)
                    Log.i(TAG, "Incoming ring cancelled by exact control payload call=$callId")
                }
                // Exact cancellation also stores a tombstone for cancel-before-ring.
                // Never fall back to cancelCall(): the same room may already be
                // answering/active or may contain a newer redial attempt.
                return
            }
            if (callId != null && isCallEndPayload(payload)) {
                cancelCall(context, callId)
                Log.i(TAG, "Incoming call cancelled by tokenless remote end call=$callId")
            }
            return
        }
        if (isIncomingCallPayload(payload)) {
            if (isStaleIncomingCall(payload)) {
                Log.i(TAG, "Stale MatrixRTC ring ignored")
                return
            }
            if (appResumed) {
                Log.i(TAG, "Native call presentation suppressed while Orex is foreground")
                return
            }
            showIncomingCall(context, payload, allowFullScreen = true)
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
        if (eventId.isNullOrBlank()) {
            Log.w(TAG, "Local Matrix notification skipped without event id")
            return
        }
        OrexPushResolveWorker.enqueue(context.applicationContext, payload)
    }

    fun onNotificationOpened(context: Context, payload: Map<String, String>) {
        val roomId = firstValue(payload, "room_id") ?: return
        dismissRoomNotifications(context, roomId)
    }

    fun dismissRoomNotifications(context: Context, rawRoomId: String) {
        val roomId = rawRoomId.trim()
        if (roomId.isEmpty()) return
        messageHistoryPrefs(context).edit().remove(roomId).apply()
        notificationManager(context).cancel(messageNotificationId(roomId))
    }

    fun isIncomingCallPayload(payload: Map<String, String>): Boolean {
        if (isCallRingCancellationPayload(payload)) return false
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
        // Explicit Orex control actions are handled above; without one, the RTC
        // event type remains the killed-process fallback for the ring envelope.
        return notificationType == null || notificationType.equals("ring", ignoreCase = true)
    }

    fun isCallEndPayload(payload: Map<String, String>): Boolean =
        callControlAction(payload).equals("ended", ignoreCase = true)

    fun isCallRingCancellationPayload(payload: Map<String, String>): Boolean {
        val action = callControlAction(payload) ?: return false
        return action.equals("ended", ignoreCase = true) ||
            action.equals("handled", ignoreCase = true)
    }

    private fun callControlAction(payload: Map<String, String>): String? {
        if (!isRtcNotificationPayload(payload)) return null
        return firstValue(
            payload,
            "content_orex_call_action",
            "content.orex_call_action",
            "orex_call_action",
        ) ?: contentString(payload, "orex_call_action")
    }

    fun isRtcNotificationPayload(payload: Map<String, String>): Boolean {
        val eventType = firstValue(payload, "type", "event_type")?.lowercase()
        return eventType == "m.rtc.notification" ||
            eventType == "org.matrix.msc4075.rtc.notification"
    }

    fun isMessagePayload(payload: Map<String, String>): Boolean {
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

    fun canRenderMessageDirectly(payload: Map<String, String>): Boolean {
        if (!isMessagePayload(payload)) return false
        val eventType = firstValue(payload, "type", "event_type")?.lowercase()
        if (eventType == "m.room.encrypted") return false
        val body = rawMessageBody(payload) ?: return false
        return !isGenericMessageBody(body)
    }

    fun needsBackgroundResolution(payload: Map<String, String>): Boolean {
        if (!isMessagePayload(payload) || canRenderMessageDirectly(payload)) return false
        return firstValue(payload, "room_id") != null && firstValue(payload, "event_id") != null
    }

    fun needsCallAvatarResolution(context: Context, payload: Map<String, String>): Boolean {
        if (!isIncomingCallPayload(payload)) return false
        val roomId = firstValue(payload, "room_id", "call_id") ?: return false
        if (firstValue(payload, "event_id") == null) return false
        val senderId = firstValue(payload, "sender")
        val key = OrexAvatarCache.resolveConversationKey(
            context = context,
            explicitKey = firstValue(payload, "sender_avatar_key", "avatar_cache_key"),
            roomId = roomId,
            userId = senderId,
        )
        return OrexAvatarCache.load(context, key) == null
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
        toggleMic: PendingIntent,
        toggleAudio: PendingIntent,
        startedAt: Long,
        micEnabled: Boolean,
        audioEnabled: Boolean,
        avatarCacheKey: String? = null,
    ): Notification? {
        if (!canPostNotifications(context)) return null
        ensureChannels(context)
        val resolvedAvatarCacheKey = OrexAvatarCache.resolveConversationKey(
            context = context,
            explicitKey = avatarCacheKey,
            roomId = callId,
        )
        val isRinging = incoming && !answered
        val decision = if (isRinging) {
            OrexCallPresentationState.claimTelecomRing(context, callId)
        } else {
            OrexCallPresentationState.markActive(context, callId)
            OrexCallPresentationState.IncomingDecision.SILENT_REFRESH
        }
        if (decision == OrexCallPresentationState.IncomingDecision.SUPPRESS) return null
        val alert = decision == OrexCallPresentationState.IncomingDecision.FIRST_ALERT

        val openApp = if (isRinging) {
            OrexPushBridge.incomingCallScreenPendingIntent(
                context = context,
                callId = callId,
                displayName = displayName,
                video = video,
                timeoutAfterMs = DEFAULT_CALL_LIFETIME_MS,
                requestCode = 7000,
                avatarCacheKey = resolvedAvatarCacheKey,
            )
        } else {
            OrexPushBridge.incomingCallPendingIntent(
                context = context,
                callId = callId,
                displayName = displayName,
                video = video,
                action = null,
                requestCode = 7000,
                avatarCacheKey = resolvedAvatarCacheKey,
            )
        }
        val uiAnswer = if (isRinging) {
            OrexPushBridge.incomingCallActionPendingIntent(
                context = context,
                callId = callId,
                displayName = displayName,
                video = video,
                action = "answer",
                requestCode = 7001,
                systemManaged = true,
            )
        } else {
            answer
        }
        val uiDecline = if (isRinging) {
            OrexPushBridge.incomingCallActionPendingIntent(
                context = context,
                callId = callId,
                displayName = displayName,
                video = video,
                action = "reject",
                requestCode = 7002,
                systemManaged = true,
            )
        } else {
            decline
        }
        return postCall(
            context = context,
            displayName = displayName,
            incoming = isRinging,
            openApp = openApp,
            fullScreen = openApp.takeIf {
                isRinging && alert && !OrexPushBridge.isAppResumed()
            },
            answer = uiAnswer,
            decline = uiDecline,
            hangUp = hangUp,
            toggleMic = toggleMic,
            toggleAudio = toggleAudio,
            startedAt = startedAt,
            micEnabled = micEnabled,
            audioEnabled = audioEnabled,
            timeoutAfterMs = null,
            alert = alert,
            avatarCacheKey = resolvedAvatarCacheKey,
        )
    }

    fun buildForegroundCallFallback(
        context: Context,
        displayName: String,
        openApp: PendingIntent,
        hangUp: PendingIntent,
        toggleMic: PendingIntent,
        toggleAudio: PendingIntent,
        startedAt: Long,
        answered: Boolean,
        micEnabled: Boolean,
        audioEnabled: Boolean,
    ): Notification {
        ensureChannels(context)
        val person = CompatPerson.Builder()
            .setName(displayName)
            .setImportant(true)
            .build()
        return callBuilder(context, ONGOING_CALL_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_orex)
            .setColor(context.getColor(R.color.orex_launch_icon_background))
            .setContentTitle(displayName)
            .setContentText(
                if (answered) ongoingCallStatus(micEnabled, audioEnabled)
                else "Подключение к звонку…",
            )
            .setContentIntent(openApp)
            .addPerson(person)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setWhen(startedAt)
            .setShowWhen(true)
            .setUsesChronometer(true)
            .setStyle(NotificationCompat.CallStyle.forOngoingCall(person, hangUp))
            .addAction(
                R.drawable.ic_stat_orex,
                if (micEnabled) "Микрофон выкл." else "Микрофон вкл.",
                toggleMic,
            )
            .addAction(
                R.drawable.ic_stat_orex,
                if (audioEnabled) "Звук выкл." else "Звук вкл.",
                toggleAudio,
            )
            .build()
    }

    fun cancelCallNotification(context: Context) {
        notificationManager(context).cancel(INCOMING_CALL_NOTIFICATION_ID)
    }

    fun cancelOngoingCallNotification(context: Context) {
        notificationManager(context).cancel(ONGOING_CALL_NOTIFICATION_ID)
    }

    fun cancelIncomingCall(context: Context, callId: String? = null) {
        cancelCallNotification(context)
        OrexCallPresentationState.markEnded(context, callId)
        if (callId == null) OrexIncomingCallActivity.finishActive()
        else OrexIncomingCallActivity.finishForCall(callId)
    }

    fun cancelCall(context: Context, callId: String? = null) {
        val canCancel = callId == null ||
            OrexCallPresentationState.canCancelPresentation(context, callId)
        if (canCancel) cancelCallNotification(context)
        // Ongoing notification ownership belongs exclusively to
        // OrexCallForegroundService. Ring/handled/end push cleanup must never
        // remove the active media call card behind the service's back.
        OrexCallPresentationState.markEnded(context, callId)
        if (callId == null) OrexIncomingCallActivity.finishActive()
        else OrexIncomingCallActivity.finishForCall(callId)
    }

    private fun showIncomingCall(
        context: Context,
        payload: Map<String, String>,
        allowFullScreen: Boolean,
    ) {
        if (!canPostNotifications(context)) return
        ensureChannels(context)
        val callId = firstValue(payload, "room_id", "call_id", "event_id") ?: return
        val displayName = callerDisplayName(payload)
        val senderId = firstValue(payload, "sender")
        val avatarCacheKey = OrexAvatarCache.resolveConversationKey(
            context = context,
            explicitKey = firstValue(payload, "sender_avatar_key", "avatar_cache_key"),
            roomId = callId,
            userId = senderId,
        )
        if (avatarCacheKey != null) {
            OrexIncomingCallActivity.updateAvatarForCall(callId, avatarCacheKey)
        }
        val video = isVideoCall(payload)
        val timeoutAfterMs = remainingCallLifetimeMs(payload)
        val ringToken = firstValue(
            payload,
            "event_id",
            "content_sender_ts",
            "content.sender_ts",
            "sender_ts",
        )
        val decision = OrexCallPresentationState.claimPushRing(
            context = context,
            callId = callId,
            ringToken = ringToken,
            timeoutAfterMs = timeoutAfterMs,
            refreshOnly = payload["orex_call_refresh"].equals("true", ignoreCase = true),
        )
        if (decision == OrexCallPresentationState.IncomingDecision.SUPPRESS) {
            Log.i(TAG, "Duplicate/handled incoming call push suppressed call=$callId")
            return
        }
        val alert = decision == OrexCallPresentationState.IncomingDecision.FIRST_ALERT

        val openApp = OrexPushBridge.incomingCallScreenPendingIntent(
            context = context,
            callId = callId,
            displayName = displayName,
            video = video,
            timeoutAfterMs = timeoutAfterMs,
            requestCode = 6100,
            avatarCacheKey = avatarCacheKey,
        )
        val answer = OrexPushBridge.incomingCallActionPendingIntent(
            context = context,
            callId = callId,
            displayName = displayName,
            video = video,
            action = "answer",
            requestCode = 6101,
        )
        val decline = OrexPushBridge.incomingCallActionPendingIntent(
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
            fullScreen = openApp.takeIf { allowFullScreen && alert },
            answer = answer,
            decline = decline,
            hangUp = null,
            timeoutAfterMs = timeoutAfterMs,
            alert = alert,
            avatarCacheKey = avatarCacheKey,
        )
        Log.i(TAG, "Incoming call notification posted call=$callId alert=$alert")
    }

    private fun postCall(
        context: Context,
        displayName: String,
        incoming: Boolean,
        openApp: PendingIntent,
        fullScreen: PendingIntent?,
        answer: PendingIntent,
        decline: PendingIntent,
        hangUp: PendingIntent?,
        toggleMic: PendingIntent? = null,
        toggleAudio: PendingIntent? = null,
        startedAt: Long? = null,
        micEnabled: Boolean = true,
        audioEnabled: Boolean = true,
        timeoutAfterMs: Long?,
        alert: Boolean,
        avatarCacheKey: String? = null,
    ): Notification {
        val channelId = if (incoming) INCOMING_CALL_CHANNEL_ID else ONGOING_CALL_CHANNEL_ID
        val builder = callBuilder(context, channelId)
            .setSmallIcon(R.drawable.ic_stat_orex)
            .setColor(context.getColor(R.color.orex_launch_icon_background))
            .setContentTitle(displayName)
            .setContentText(
                if (incoming) "Входящий звонок" else ongoingCallStatus(micEnabled, audioEnabled),
            )
            .setContentIntent(openApp)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
        val avatar = OrexAvatarCache.load(context, avatarCacheKey)
        if (avatar != null) builder.setLargeIcon(avatar)

        if (!incoming && startedAt != null) {
            builder
                .setWhen(startedAt)
                .setShowWhen(true)
                .setUsesChronometer(true)
        }
        if (timeoutAfterMs != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setTimeoutAfter(timeoutAfterMs.coerceAtLeast(1_000L))
        }

        if (incoming && fullScreen != null && canUseFullScreenIntent(context)) {
            builder.setFullScreenIntent(fullScreen, true)
        }

        val person = CompatPerson.Builder()
            .setName(displayName)
            .setImportant(true)
            .build()
        builder.addPerson(person)
        if (incoming) {
            builder.setStyle(
                NotificationCompat.CallStyle.forIncomingCall(person, decline, answer),
            )
        } else {
            val disconnect = hangUp ?: decline
            builder.setStyle(
                NotificationCompat.CallStyle.forOngoingCall(person, disconnect),
            )
            if (toggleMic != null) {
                builder.addAction(
                    R.drawable.ic_stat_orex,
                    if (micEnabled) "Микрофон выкл." else "Микрофон вкл.",
                    toggleMic,
                )
            }
            if (toggleAudio != null) {
                builder.addAction(
                    R.drawable.ic_stat_orex,
                    if (audioEnabled) "Звук выкл." else "Звук вкл.",
                    toggleAudio,
                )
            }
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            builder.priority = if (incoming) {
                NotificationCompat.PRIORITY_MAX
            } else {
                NotificationCompat.PRIORITY_DEFAULT
            }
        }

        val notification = builder.build().apply {
            if (incoming && alert) flags = flags or Notification.FLAG_INSISTENT
        }
        val notificationId = if (incoming) {
            INCOMING_CALL_NOTIFICATION_ID
        } else {
            ONGOING_CALL_NOTIFICATION_ID
        }
        notificationManager(context).notify(notificationId, notification)
        return notification
    }

    private fun ongoingCallStatus(micEnabled: Boolean, audioEnabled: Boolean): String {
        val mic = if (micEnabled) "Микрофон включён" else "Микрофон выключен"
        val audio = if (audioEnabled) "Звук включён" else "Звук выключен"
        return "$mic · $audio"
    }

    private data class MessageHistoryItem(
        val sender: String,
        val senderId: String?,
        val body: String,
        val timestamp: Long,
    )

    private fun messageNotificationId(stableId: String): Int =
        ("message|$stableId".hashCode().absoluteValue).coerceAtLeast(1)

    private fun showMessage(context: Context, payload: Map<String, String>) {
        if (!canPostNotifications(context)) return
        ensureChannels(context)
        val title = messageTitle(payload)
        val body = messageBody(payload) ?: run {
            Log.w(TAG, "Message notification skipped until E2EE plaintext is available")
            return
        }
        val stableId = firstValue(payload, "room_id", "event_id", "message_id") ?: body
        val notificationId = messageNotificationId(stableId)
        val openApp = OrexPushBridge.notificationOpenPendingIntent(
            context = context,
            payload = payload,
            requestCode = notificationId,
        )
        val timestamp = eventTimestamp(payload)
        val builder = builder(context, MESSAGE_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_orex)
            .setColor(context.getColor(R.color.orex_launch_icon_background))
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
        val senderId = firstValue(payload, "sender")
        val historyKey = firstValue(payload, "room_id") ?: stableId
        val avatarCacheKey = OrexAvatarCache.resolveSenderKey(
            context = context,
            explicitKey = firstValue(payload, "sender_avatar_key", "avatar_cache_key"),
            userId = senderId,
        )
        val currentAvatar = OrexAvatarCache.load(context, avatarCacheKey)
        if (currentAvatar != null) builder.setLargeIcon(currentAvatar)
        val history = appendMessageHistory(
            context = context,
            key = historyKey,
            item = MessageHistoryItem(senderName, senderId, body, timestamp),
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val user = Person.Builder().setName("Orex").build()
            val style = Notification.MessagingStyle(user)
                .setConversationTitle(title.takeIf { it != senderName })
            for (item in history) {
                val senderBuilder = Person.Builder().setName(item.sender)
                if (!item.senderId.isNullOrBlank()) senderBuilder.setKey(item.senderId)
                val senderAvatar = OrexAvatarCache.load(
                    context,
                    OrexAvatarCache.resolveSenderKey(
                        context = context,
                        explicitKey = null,
                        userId = item.senderId,
                    ),
                )
                if (senderAvatar != null) {
                    senderBuilder.setIcon(
                        Icon.createWithBitmap(OrexAvatarCache.circle(senderAvatar)),
                    )
                }
                val sender = senderBuilder.build()
                style.addMessage(
                    Notification.MessagingStyle.Message(
                        item.body,
                        item.timestamp,
                        sender,
                    ),
                )
            }
            builder.setStyle(style)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            @Suppress("DEPRECATION")
            val style = Notification.MessagingStyle("Orex")
                .setConversationTitle(title.takeIf { it != senderName })
            for (item in history) {
                @Suppress("DEPRECATION")
                style.addMessage(item.body, item.timestamp, item.sender)
            }
            builder.setStyle(style)
        } else {
            builder.setStyle(Notification.BigTextStyle().bigText(body))
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            builder.setPriority(Notification.PRIORITY_HIGH)
        }

        notificationManager(context).notify(notificationId, builder.build())
        Log.i(TAG, "Message notification posted")
    }

    private fun appendMessageHistory(
        context: Context,
        key: String,
        item: MessageHistoryItem,
    ): List<MessageHistoryItem> {
        val prefs = messageHistoryPrefs(context)
        val current = decodeMessageHistory(prefs.getString(key, null)).toMutableList()
        current.removeAll { it.timestamp == item.timestamp && it.body == item.body && it.sender == item.sender }
        current.add(item)
        val trimmed = current.takeLast(MAX_HISTORY_MESSAGES)
        val encoded = JSONArray().apply {
            for (entry in trimmed) {
                put(
                    JSONObject()
                        .put("sender", entry.sender)
                        .put("sender_id", entry.senderId ?: JSONObject.NULL)
                        .put("body", entry.body)
                        .put("timestamp", entry.timestamp),
                )
            }
        }
        prefs.edit().putString(key, encoded.toString()).apply()
        return trimmed
    }

    private fun decodeMessageHistory(encoded: String?): List<MessageHistoryItem> {
        if (encoded.isNullOrBlank()) return emptyList()
        return try {
            val array = JSONArray(encoded)
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    val sender = item.optString("sender", "Orex").trim().ifEmpty { "Orex" }
                    val senderId = item.optString("sender_id", "")
                        .trim()
                        .ifEmpty { null }
                    val body = item.optString("body", "").trim()
                    val timestamp = item.optLong("timestamp", 0L)
                    if (body.isNotEmpty() && timestamp > 0L) {
                        add(MessageHistoryItem(sender, senderId, body, timestamp))
                    }
                }
            }
        } catch (error: Throwable) {
            Log.w(TAG, "Failed to decode notification message history", error)
            emptyList()
        }
    }

    private fun messageHistoryPrefs(context: Context) =
        context.getSharedPreferences(MESSAGE_HISTORY_PREFS, Context.MODE_PRIVATE)

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
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Личные сообщения, комнаты и события Matrix"
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                    enableVibration(true)
                    enableLights(true)
                    setSound(Settings.System.DEFAULT_NOTIFICATION_URI, null)
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
        val senderTs = firstLong(
            payload,
            "content_sender_ts",
            "content.sender_ts",
            "sender_ts",
            "orex_ring_ts_ms",
        ) ?: contentLong(payload, "sender_ts")
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

    private fun messageBody(payload: Map<String, String>): String? {
        val body = rawMessageBody(payload) ?: return null
        if (isGenericMessageBody(body)) return null
        return boundedText(body, "", 500).takeIf { it.isNotEmpty() }
    }

    private fun rawMessageBody(payload: Map<String, String>): String? =
        firstValue(payload, "body", "content_body", "content.body")
            ?: contentString(payload, "body")

    private fun isGenericMessageBody(value: String): Boolean {
        return when (value.trim().lowercase()) {
            "новое сообщение",
            "новое событие",
            "новое событие в orex",
            "новое зашифрованное сообщение" -> true
            else -> false
        }
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

    private fun callBuilder(
        context: Context,
        channelId: String,
    ): NotificationCompat.Builder = NotificationCompat.Builder(context, channelId)

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

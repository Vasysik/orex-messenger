package ru.orex.messenger

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.net.Uri
import android.os.Build
import android.telecom.DisconnectCause
import android.util.Log
import androidx.core.telecom.CallAttributesCompat
import androidx.core.telecom.CallControlResult
import androidx.core.telecom.CallControlScope
import androidx.core.telecom.CallEndpointCompat
import androidx.core.telecom.CallsManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/**
 * Единственная нативная граница Android Telecom для Orex.
 *
 * Приложение уже поддерживает только один активный CallController, поэтому
 * адаптер намеренно хранит одну Telecom-сессию. MatrixRTC и LiveKit остаются
 * владельцами сигналинга/медиа; этот класс отвечает только за системный call UI,
 * audio focus/route и действия с гарнитур/системных поверхностей.
 */
object OrexAndroidTelecomManager {
    const val ACTION_ANSWER = "ru.orex.messenger.action.ANSWER_CALL"
    const val ACTION_DECLINE = "ru.orex.messenger.action.DECLINE_CALL"
    const val ACTION_HANG_UP = "ru.orex.messenger.action.HANG_UP_CALL"
    const val ACTION_TOGGLE_MIC = "ru.orex.messenger.action.TOGGLE_CALL_MIC"
    const val ACTION_TOGGLE_AUDIO = "ru.orex.messenger.action.TOGGLE_CALL_AUDIO"
    const val EXTRA_CALL_ID = "orex_call_id"

    private const val CHANNEL_NAME = "orex/system_calls"
    private const val TAG = "OrexSystemCall"
    private const val CALL_READY_TIMEOUT_MS = 6_500L

    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private var appContext: Context? = null
    private var channel: MethodChannel? = null
    private var callsManager: CallsManager? = null
    private var telecomRegistered = false
    private var current: ManagedCall? = null
    private val callMutationMutex = Mutex()

    private data class ManagedCall(
        val callId: String,
        val displayName: String,
        val incoming: Boolean,
        var video: Boolean,
        var avatarCacheKey: String?,
        val ready: CompletableDeferred<Boolean> = CompletableDeferred(),
        var control: CallControlScope? = null,
        var job: Job? = null,
        var endpoints: List<CallEndpointCompat> = emptyList(),
        var answered: Boolean = false,
        var lastMuted: Boolean? = null,
        var suppressDisconnectEvent: Boolean = false,
        var terminating: Boolean = false,
        val startedAt: Long = System.currentTimeMillis(),
        var micEnabled: Boolean = true,
        var audioEnabled: Boolean = true,
        var cameraEnabled: Boolean = video,
    )

    fun attach(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        channel?.setMethodCallHandler(null)
        channel = MethodChannel(messenger, CHANNEL_NAME).also { methodChannel ->
            methodChannel.setMethodCallHandler(::handleMethodCall)
        }
        ensureRegistered()
    }

    fun ownsCallRouting(): Boolean = current != null

    fun handleNotificationAction(intent: Intent) {
        val callId = intent.getStringExtra(EXTRA_CALL_ID)?.trim().orEmpty()
        if (callId.isEmpty()) return
        when (intent.action) {
            ACTION_ANSWER -> appScope.launch {
                val call = current?.takeIf { it.callId == callId } ?: return@launch
                val accepted = emitActionAndAwait(
                    call,
                    "answer",
                    mapOf("video" to call.video),
                )
                if (!accepted) {
                    disconnectInternal(call, DisconnectCause.ERROR)
                    return@launch
                }
                if (!answerInternal(call, call.video)) {
                    emitAction(call, "disconnect")
                    disconnectInternal(call, DisconnectCause.ERROR)
                }
            }
            ACTION_DECLINE -> appScope.launch {
                val call = current?.takeIf { it.callId == callId } ?: return@launch
                emitActionAndAwait(call, "reject")
                disconnectInternal(call, DisconnectCause.REJECTED)
            }
            ACTION_HANG_UP -> appScope.launch {
                val call = current?.takeIf { it.callId == callId } ?: return@launch
                emitActionAndAwait(call, "disconnect")
                disconnectInternal(call, DisconnectCause.LOCAL)
            }
            ACTION_TOGGLE_MIC -> appScope.launch {
                val call = current?.takeIf { it.callId == callId } ?: return@launch
                emitActionAndAwait(call, "toggleMic")
            }
            ACTION_TOGGLE_AUDIO -> appScope.launch {
                val call = current?.takeIf { it.callId == callId } ?: return@launch
                emitActionAndAwait(call, "toggleAudio")
            }
        }
    }

    fun requestAudioRoute(
        androidDeviceType: Int?,
        preferredEndpointName: String?,
        callback: (Boolean) -> Unit,
    ) {
        appScope.launch {
            try {
                val call = current
                val control = call?.let { awaitControl(it) }
                if (call == null || control == null) {
                    callback(false)
                    return@launch
                }

                val endpointType = endpointTypeForAndroidDevice(androidDeviceType)
                var endpoints = call.endpoints
                if (endpoints.isEmpty()) {
                    endpoints = withTimeoutOrNull(1500) {
                        control.availableEndpoints.first { it.isNotEmpty() }
                    }.orEmpty()
                    call.endpoints = endpoints
                }
                fun selectEndpoint(items: List<CallEndpointCompat>): CallEndpointCompat? {
                    val compatible = items.filter { it.type == endpointType }
                    return preferredEndpointName
                        ?.takeIf { it.isNotBlank() }
                        ?.let { preferred ->
                            compatible.firstOrNull {
                                endpointNamesMatch(it.name.toString(), preferred)
                            }
                        }
                        ?: compatible.firstOrNull()
                }

                var endpoint = selectEndpoint(endpoints)
                if (endpoint == null) {
                    endpoint = withTimeoutOrNull(2500) {
                        val refreshed = control.availableEndpoints.first { items ->
                            selectEndpoint(items) != null
                        }
                        call.endpoints = refreshed
                        selectEndpoint(refreshed)
                    }
                }
                if (endpoint == null) {
                    Log.w(
                        TAG,
                        "No Telecom endpoint type=$endpointType for deviceType=$androidDeviceType",
                    )
                    callback(false)
                    return@launch
                }

                val selectedEndpoint = endpoint
                val requested = control.requestEndpointChange(selectedEndpoint)
                if (requested !is CallControlResult.Success) {
                    callback(false)
                    return@launch
                }

                // requestEndpointChange() is transactional but the endpoint Flow
                // updates asynchronously. Wait briefly for the system route to
                // become observable before confirming the UI selection.
                val confirmed = withTimeoutOrNull(2000) {
                    control.currentCallEndpoint.first { currentEndpoint ->
                        currentEndpoint.type == selectedEndpoint.type &&
                            (preferredEndpointName.isNullOrBlank() ||
                                endpointNamesMatch(
                                    currentEndpoint.name.toString(),
                                    preferredEndpointName,
                                ))
                    }
                    true
                } == true
                callback(confirmed)
            } catch (error: Throwable) {
                Log.e(TAG, "Failed to change Telecom audio endpoint", error)
                callback(false)
            }
        }
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "updateForegroundCall" -> {
                val context = appContext
                val callId = call.argument<String>("callId")?.trim().orEmpty()
                val displayName = call.argument<String>("displayName")?.trim().orEmpty()
                if (context == null || callId.isEmpty() || displayName.isEmpty()) {
                    result.success(false)
                    return
                }
                val video = call.argument<Boolean>("video") == true
                val startedAt = call.argument<Number>("startedAt")?.toLong()
                    ?.takeIf { it > 0L } ?: System.currentTimeMillis()
                val started = OrexCallForegroundService.update(
                    context = context,
                    descriptor = OrexCallForegroundService.Descriptor(
                        callId = callId,
                        displayName = displayName,
                        incoming = call.argument<Boolean>("incoming") == true,
                        video = video,
                        answered = call.argument<Boolean>("answered") == true,
                        startedAt = startedAt,
                        micEnabled = call.argument<Boolean>("micEnabled") != false,
                        audioEnabled = call.argument<Boolean>("audioEnabled") != false,
                        cameraEnabled = call.argument<Boolean>("cameraEnabled") ?: video,
                        updatedAt = System.currentTimeMillis(),
                    ),
                    notification = null,
                )
                result.success(started)
            }
            "stopForegroundCall" -> {
                val context = appContext
                val callId = call.argument<String>("callId")?.trim()?.ifEmpty { null }
                if (context != null) OrexCallForegroundService.stop(context, callId)
                result.success(context != null)
            }
            "reportIncomingCall" -> reportFromMethod(call, result, incoming = true)
            "reportOutgoingCall" -> reportFromMethod(call, result, incoming = false)
            "answerCall" -> withCall(call, result) { managed ->
                val video = call.argument<Boolean>("video") == true
                managed.video = video
                answerInternal(managed, video)
            }
            "updateControls" -> withCall(call, result) { managed ->
                managed.micEnabled = call.argument<Boolean>("micEnabled") == true
                managed.audioEnabled = call.argument<Boolean>("audioEnabled") == true
                managed.cameraEnabled = call.argument<Boolean>("cameraEnabled") == true
                true
            }
            "setActive" -> withCall(call, result) { managed ->
                val control = awaitControl(managed) ?: return@withCall false
                val success = control.setActive() is CallControlResult.Success
                if (success) {
                    managed.answered = true
                }
                success
            }
            "rejectCall" -> withCall(call, result) { managed ->
                disconnectInternal(managed, DisconnectCause.REJECTED)
            }
            "endCall" -> withCall(call, result) { managed ->
                val reason = call.argument<String>("reason")
                val cause = when (reason) {
                    "error" -> DisconnectCause.ERROR
                    "remote" -> DisconnectCause.REMOTE
                    else -> DisconnectCause.LOCAL
                }
                disconnectInternal(managed, cause)
            }
            "getRecoverableCall" -> {
                val context = appContext
                result.success(
                    if (context == null) null else OrexCallForegroundService.readRecovery(context),
                )
            }
            "clearRecoverableCall" -> {
                val context = appContext
                val callId = call.argument<String>("callId")?.trim()?.ifEmpty { null }
                if (context != null) {
                    OrexCallForegroundService.clearRecovery(context, callId)
                }
                result.success(context != null)
            }
            else -> result.notImplemented()
        }
    }

    private fun reportFromMethod(
        call: MethodCall,
        result: MethodChannel.Result,
        incoming: Boolean,
    ) {
        val callId = call.argument<String>("callId")?.trim().orEmpty()
        val displayName = call.argument<String>("displayName")?.trim().orEmpty()
        val avatarCacheKey = call.argument<String>("avatarCacheKey")?.trim()?.ifEmpty { null }
        val video = call.argument<Boolean>("video") == true
        val startedAt = call.argument<Number>("startedAt")?.toLong()
            ?.takeIf { it > 0L } ?: System.currentTimeMillis()
        val micEnabled = call.argument<Boolean>("micEnabled") ?: true
        val audioEnabled = call.argument<Boolean>("audioEnabled") ?: true
        val cameraEnabled = call.argument<Boolean>("cameraEnabled") ?: video
        if (callId.isEmpty() || displayName.isEmpty()) {
            result.error("invalid_arguments", "callId and displayName are required", null)
            return
        }
        appScope.launch {
            try {
                result.success(
                    reportCall(
                        callId = callId,
                        displayName = displayName,
                        incoming = incoming,
                        video = video,
                        avatarCacheKey = avatarCacheKey,
                        startedAt = startedAt,
                        micEnabled = micEnabled,
                        audioEnabled = audioEnabled,
                        cameraEnabled = cameraEnabled,
                    ),
                )
            } catch (error: Throwable) {
                Log.e(TAG, "Failed to report call id=$callId", error)
                result.success(false)
            }
        }
    }

    private fun withCall(
        methodCall: MethodCall,
        result: MethodChannel.Result,
        action: suspend (ManagedCall) -> Boolean,
    ) {
        val callId = methodCall.argument<String>("callId")?.trim().orEmpty()
        appScope.launch {
            try {
                val managed = current?.takeIf { it.callId == callId }
                result.success(managed != null && action(managed))
            } catch (error: Throwable) {
                Log.e(TAG, "Call command failed id=$callId", error)
                result.success(false)
            }
        }
    }

    private fun ensureRegistered(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (telecomRegistered) return true
        val context = appContext ?: return false
        return try {
            val manager = callsManager ?: CallsManager(context).also { callsManager = it }
            manager.registerAppWithTelecom(
                CallsManager.CAPABILITY_BASELINE or CallsManager.CAPABILITY_SUPPORTS_VIDEO_CALLING,
            )
            telecomRegistered = true
            true
        } catch (error: Throwable) {
            Log.e(TAG, "Failed to register Core-Telecom", error)
            false
        }
    }

    private suspend fun reportCall(
        callId: String,
        displayName: String,
        incoming: Boolean,
        video: Boolean,
        avatarCacheKey: String?,
        startedAt: Long,
        micEnabled: Boolean,
        audioEnabled: Boolean,
        cameraEnabled: Boolean,
    ): Boolean {
        callMutationMutex.lock()
        return try {
            reportCallLocked(
                callId,
                displayName,
                incoming,
                video,
                avatarCacheKey,
                startedAt,
                micEnabled,
                audioEnabled,
                cameraEnabled,
            )
        } finally {
            callMutationMutex.unlock()
        }
    }

    private suspend fun reportCallLocked(
        callId: String,
        displayName: String,
        incoming: Boolean,
        video: Boolean,
        avatarCacheKey: String?,
        startedAt: Long,
        micEnabled: Boolean,
        audioEnabled: Boolean,
        cameraEnabled: Boolean,
    ): Boolean {
        if (!ensureRegistered()) return false
        val existing = current
        if (existing != null) {
            if (existing.callId == callId && !existing.terminating) {
                existing.video = video
                existing.micEnabled = micEnabled
                existing.audioEnabled = audioEnabled
                existing.cameraEnabled = cameraEnabled
                if (!avatarCacheKey.isNullOrBlank()) existing.avatarCacheKey = avatarCacheKey
                showNotification(existing)
                return withTimeoutOrNull(CALL_READY_TIMEOUT_MS) { existing.ready.await() } == true
            }
            if (!existing.terminating &&
                !disconnectInternal(existing, DisconnectCause.LOCAL)
            ) {
                return false
            }
            val terminated = withTimeoutOrNull(2000) {
                existing.job?.join()
                true
            } == true
            if (!terminated) {
                existing.job?.cancel()
                cleanup(existing)
            }
        }

        val manager = callsManager ?: return false
        val managed = ManagedCall(
            callId = callId,
            displayName = displayName,
            incoming = incoming,
            video = video,
            avatarCacheKey = avatarCacheKey,
            startedAt = startedAt,
            micEnabled = micEnabled,
            audioEnabled = audioEnabled,
            cameraEnabled = cameraEnabled,
        )
        current = managed
        showNotification(managed)

        val address = if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.O_MR1) {
            Uri.parse("sip:${Uri.encode(callId)}")
        } else {
            Uri.parse("orex:${Uri.encode(callId)}")
        }
        val attributes = CallAttributesCompat(
            displayName,
            address,
            if (incoming) {
                CallAttributesCompat.DIRECTION_INCOMING
            } else {
                CallAttributesCompat.DIRECTION_OUTGOING
            },
            if (video) {
                CallAttributesCompat.CALL_TYPE_VIDEO_CALL
            } else {
                CallAttributesCompat.CALL_TYPE_AUDIO_CALL
            },
            CallAttributesCompat.SUPPORTS_SET_INACTIVE,
        )

        managed.job = appScope.launch {
            try {
                manager.addCall(
                    callAttributes = attributes,
                    onAnswer = { callType ->
                        val requestedVideo =
                            callType == CallAttributesCompat.CALL_TYPE_VIDEO_CALL
                        val handled = emitActionAndAwait(
                            managed,
                            "answer",
                            mapOf("video" to requestedVideo),
                        )
                        if (!handled) {
                            throw IllegalStateException(
                                "Orex did not acknowledge Telecom answer for ${managed.callId}",
                            )
                        }
                        managed.answered = true
                        managed.video = requestedVideo
                        showNotification(managed)
                    },
                    onDisconnect = { cause ->
                        managed.terminating = true
                        if (!managed.suppressDisconnectEvent) {
                            val action = if (!managed.answered && managed.incoming) {
                                "reject"
                            } else {
                                "disconnect"
                            }
                            val handled = emitActionAndAwait(
                                managed,
                                action,
                                mapOf("cause" to cause.code),
                            )
                            if (!handled) {
                                throw IllegalStateException(
                                    "Orex did not acknowledge Telecom $action for ${managed.callId}",
                                )
                            }
                        }
                    },
                    onSetActive = {
                        if (!emitActionAndAwait(managed, "setActive")) {
                            throw IllegalStateException(
                                "Orex did not acknowledge Telecom setActive for ${managed.callId}",
                            )
                        }
                        managed.answered = true
                        showNotification(managed)
                    },
                    onSetInactive = {
                        if (!emitActionAndAwait(managed, "setInactive")) {
                            throw IllegalStateException(
                                "Orex did not acknowledge Telecom setInactive for ${managed.callId}",
                            )
                        }
                    },
                ) {
                    managed.control = this
                    if (!managed.ready.isCompleted) managed.ready.complete(true)
                    // Повторно публикуем CallStyle уже после принятия addCall:
                    // Core-Telecom требует валидное call notification в начале
                    // foreground execution window, а ранняя публикация выше
                    // нужна только для отсутствия визуального лага.
                    showNotification(managed)
                    launch {
                        availableEndpoints.collect { managed.endpoints = it }
                    }
                    launch {
                        isMuted.collect { muted ->
                            if (managed.lastMuted != muted) {
                                managed.lastMuted = muted
                                emitAction(managed, "muteChanged", mapOf("muted" to muted))
                            }
                        }
                    }
                }
            } catch (_: CancellationException) {
                // Expected when a stale/duplicate registration is explicitly
                // replaced or timed out. Do not report it as a call failure.
                if (!managed.ready.isCompleted) managed.ready.complete(false)
            } catch (error: Throwable) {
                Log.e(TAG, "Core-Telecom call failed id=$callId", error)
                if (!managed.ready.isCompleted) managed.ready.complete(false)
            } finally {
                cleanup(managed)
            }
        }

        val ready = withTimeoutOrNull(CALL_READY_TIMEOUT_MS) { managed.ready.await() } == true
        if (!ready) {
            managed.job?.cancel()
            cleanup(managed)
        }
        return ready
    }

    private suspend fun answerInternal(managed: ManagedCall, video: Boolean): Boolean {
        val control = awaitControl(managed) ?: return false
        val result = control.answer(
            if (video) {
                CallAttributesCompat.CALL_TYPE_VIDEO_CALL
            } else {
                CallAttributesCompat.CALL_TYPE_AUDIO_CALL
            },
        )
        val success = result is CallControlResult.Success
        if (success) {
            managed.answered = true
            managed.video = video
        }
        return success
    }

    private suspend fun disconnectInternal(managed: ManagedCall, causeCode: Int): Boolean {
        if (managed.terminating) return true
        managed.terminating = true
        managed.suppressDisconnectEvent = true
        val control = awaitControl(managed)
        if (control == null) {
            managed.job?.cancel()
            cleanup(managed)
            return true
        }
        val success = control.disconnect(DisconnectCause(causeCode)) is CallControlResult.Success
        if (!success) {
            managed.suppressDisconnectEvent = false
            managed.terminating = false
        }
        return success
    }

    private suspend fun awaitControl(managed: ManagedCall): CallControlScope? {
        managed.control?.let { return it }
        val ready = withTimeoutOrNull(3000) { managed.ready.await() } == true
        return if (ready) managed.control else null
    }

    private fun cleanup(managed: ManagedCall) {
        if (current !== managed) return
        current = null
        val context = appContext ?: return
        if (managed.answered) {
            // Core-Telecom can finish its coroutine while LiveKit remains active
            // (for example during replacement/re-registration). Do not mark the
            // accepted call as ended or reopen ringing state; Flutter owns the
            // ongoing foreground notification from this point.
            OrexNotificationCenter.cancelCallNotification(context)
            OrexIncomingCallActivity.finishForCall(managed.callId)
        } else {
            OrexNotificationCenter.cancelIncomingCall(context, managed.callId)
        }
    }

    private fun emitAction(
        managed: ManagedCall,
        action: String,
        extras: Map<String, Any?> = emptyMap(),
    ) {
        val payload = mutableMapOf<String, Any?>(
            "action" to action,
            "callId" to managed.callId,
        )
        payload.putAll(extras)
        channel?.invokeMethod("systemCallAction", payload)
    }

    /**
     * Telecom callbacks are transactions, not fire-and-forget notifications.
     * Wait for Flutter to confirm that the local call state accepted the
     * command, while keeping a safety margin below Telecom's 5 second timeout.
     */
    private suspend fun emitActionAndAwait(
        managed: ManagedCall,
        action: String,
        extras: Map<String, Any?> = emptyMap(),
    ): Boolean {
        val methodChannel = channel
        if (methodChannel == null) {
            val context = appContext ?: return false
            val coldAction = when (action) {
                "answer" -> "answer"
                "reject" -> "reject"
                "disconnect" -> "hangup"
                "toggleMic" -> "toggle_mic"
                "toggleAudio" -> "toggle_audio"
                else -> null
            } ?: return false
            return OrexPushBridge.launchIncomingCallAction(
                context = context,
                callId = managed.callId,
                displayName = managed.displayName,
                video = extras["video"] as? Boolean ?: managed.video,
                action = coldAction,
                fromSystem = true,
            )
        }
        val payload = mutableMapOf<String, Any?>(
            "action" to action,
            "callId" to managed.callId,
        )
        payload.putAll(extras)
        return withTimeoutOrNull(4500) {
            suspendCancellableCoroutine { continuation ->
                methodChannel.invokeMethod(
                    "systemCallAction",
                    payload,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            if (continuation.isActive) continuation.resume(result == true)
                        }

                        override fun error(
                            errorCode: String,
                            errorMessage: String?,
                            errorDetails: Any?,
                        ) {
                            Log.e(TAG, "Flutter rejected $action code=$errorCode message=$errorMessage")
                            if (continuation.isActive) continuation.resume(false)
                        }

                        override fun notImplemented() {
                            if (continuation.isActive) continuation.resume(false)
                        }
                    },
                )
            }
        } ?: false
    }

    private fun endpointNamesMatch(endpointName: String, preferredName: String): Boolean {
        val endpoint = endpointName.normalizedEndpointName()
        val preferred = preferredName.normalizedEndpointName()
        if (endpoint.isEmpty() || preferred.isEmpty()) return false
        return endpoint == preferred || endpoint.contains(preferred) || preferred.contains(endpoint)
    }

    private fun String.normalizedEndpointName(): String =
        lowercase().replace(Regex("[^a-z0-9а-яё]+"), "")

    private fun endpointTypeForAndroidDevice(androidDeviceType: Int?): Int = when (androidDeviceType) {
        null, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> CallEndpointCompat.TYPE_SPEAKER
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> CallEndpointCompat.TYPE_EARPIECE
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_HEADSET -> CallEndpointCompat.TYPE_WIRED_HEADSET
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> CallEndpointCompat.TYPE_BLUETOOTH
        else -> {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                (androidDeviceType == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                    androidDeviceType == AudioDeviceInfo.TYPE_BLE_SPEAKER)
            ) {
                CallEndpointCompat.TYPE_BLUETOOTH
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
                androidDeviceType == AudioDeviceInfo.TYPE_HEARING_AID
            ) {
                CallEndpointCompat.TYPE_BLUETOOTH
            } else {
                CallEndpointCompat.TYPE_SPEAKER
            }
        }
    }

    private fun showNotification(managed: ManagedCall) {
        if (!managed.incoming || managed.answered) return
        val context = appContext ?: return
        OrexNotificationCenter.showTelecomCall(
            context = context,
            callId = managed.callId,
            displayName = managed.displayName,
            video = managed.video,
            incoming = true,
            answered = false,
            answer = actionIntent(context, managed.callId, ACTION_ANSWER, 7001),
            decline = actionIntent(context, managed.callId, ACTION_DECLINE, 7002),
            hangUp = actionIntent(context, managed.callId, ACTION_HANG_UP, 7003),
            toggleMic = actionIntent(context, managed.callId, ACTION_TOGGLE_MIC, 7004),
            toggleAudio = actionIntent(context, managed.callId, ACTION_TOGGLE_AUDIO, 7005),
            startedAt = managed.startedAt,
            micEnabled = managed.micEnabled,
            audioEnabled = managed.audioEnabled,
            avatarCacheKey = managed.avatarCacheKey,
        )
    }

    private fun actionIntent(
        context: Context,
        callId: String,
        action: String,
        requestCode: Int,
    ): PendingIntent = PendingIntent.getBroadcast(
        context,
        requestCode xor callId.hashCode(),
        Intent(context, OrexNotificationActionReceiver::class.java).apply {
            this.action = action
            putExtra(EXTRA_CALL_ID, callId)
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

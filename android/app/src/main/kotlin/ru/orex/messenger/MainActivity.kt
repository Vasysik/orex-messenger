package ru.orex.messenger

import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.util.Rational
import android.view.ViewGroup
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        OrexFlutterEngineOwner.getOrCreate(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    private var callHandoffOverlay: OrexCallHandoffOverlay? = null
    private var callHandoffCallId: String? = null
    private var callHandoffRingEventId: String? = null
    private val callHandoffHandler = Handler(Looper.getMainLooper())
    private var pictureInPictureChannel: MethodChannel? = null
    private var callHandoffRevealTimeout: Runnable? = null
    private var callHandoffTimeout: Runnable? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        installScoBroadcastCrashGuard()
        super.onCreate(savedInstanceState)
        installCallHandoffOverlay(intent)
        OrexPushBridge.captureLaunchIntent(this, intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        installCallHandoffOverlay(intent)
        OrexPushBridge.captureLaunchIntent(this, intent)
    }

    override fun onResume() {
        super.onResume()
        OrexPushBridge.onActivityResumed(this)
    }

    override fun onPause() {
        OrexPushBridge.onActivityPaused(this)
        super.onPause()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pictureInPictureChannel?.invokeMethod(
            "onPictureInPictureModeChanged",
            isInPictureInPictureMode,
        )
    }

    private fun isPictureInPictureSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun pictureInPictureAspectRatio(width: Int?, height: Int?): Rational {
        val safeWidth = width?.coerceAtLeast(1) ?: 16
        val safeHeight = height?.coerceAtLeast(1) ?: 9
        val ratio = safeWidth.toDouble() / safeHeight.toDouble()
        return when {
            ratio > 2.39 -> Rational(239, 100)
            ratio < (1.0 / 2.39) -> Rational(100, 239)
            else -> Rational(safeWidth, safeHeight)
        }
    }

    private fun pictureInPictureParams(width: Int?, height: Int?): PictureInPictureParams =
        PictureInPictureParams.Builder()
            .setAspectRatio(pictureInPictureAspectRatio(width, height))
            .build()

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (OrexPushBridge.onRequestPermissionsResult(requestCode, permissions, grantResults)) {
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        pictureInPictureChannel?.setMethodCallHandler(null)
        pictureInPictureChannel = null
        clearCallHandoffOverlay()
        setProximityEnabled(false)
        OrexPushBridge.detach(this)
        OrexSystemUiBridge.detach(this)
        super.onDestroy()
    }

    @Deprecated("Back is blocked while the accepted call handoff owns the UI")
    override fun onBackPressed() {
        if (callHandoffOverlay != null) return
        super.onBackPressed()
    }

    private fun installCallHandoffOverlay(source: Intent) {
        if (!source.getBooleanExtra(EXTRA_CALL_HANDOFF, false)) return
        val callId = source.getStringExtra(EXTRA_CALL_ID)?.trim().orEmpty()
        if (callId.isEmpty()) return
        val ringEventId = normalizeRingEventId(source.getStringExtra(EXTRA_RING_EVENT_ID))
        val displayName = source.getStringExtra(EXTRA_DISPLAY_NAME)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "Orex"
        val avatarCacheKey = source.getStringExtra(EXTRA_AVATAR_CACHE_KEY)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }

        if (callHandoffOverlay != null) {
            val ownedCallId = callHandoffCallId.orEmpty()
            val sameAttempt = sameCallAttempt(
                ownedCallId,
                callHandoffRingEventId,
                callId,
                ringEventId,
            )
            val canPromoteAttempt = ownedCallId == callId &&
                canPromoteRingAttempt(callHandoffRingEventId, ringEventId)
            if (sameAttempt || canPromoteAttempt) {
                // Keep the original placeholder identity. It remains safely
                // promotable to the exact ring event, while the already scheduled
                // timeout keeps its original deadline and cannot be invalidated or
                // extended by duplicate FCM/activity intents.
                return
            }
        }

        clearCallHandoffOverlay()
        val overlay = OrexCallHandoffOverlay(this, displayName, avatarCacheKey)
        callHandoffOverlay = overlay
        callHandoffCallId = callId
        callHandoffRingEventId = ringEventId
        addContentView(
            overlay,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        overlay.bringToFront()
        scheduleCallHandoffTimeout()
        Log.i("OrexCallHandoff", "Native connecting cover ready call=$callId ring=$ringEventId")
        window.decorView.post {
            if (callHandoffOverlay === overlay && !isFinishing) {
                OrexIncomingCallActivity.onFlutterBootstrapCovered(callId, ringEventId)
            }
        }
    }

    fun completeCallHandoff(callId: String, ringEventId: String?): Boolean {
        val ownedCallId = callHandoffCallId ?: return false
        val sameAttempt = sameCallAttempt(
            ownedCallId,
            callHandoffRingEventId,
            callId,
            ringEventId,
        )
        val canPromoteAttempt = ownedCallId == callId &&
            canPromoteRingAttempt(callHandoffRingEventId, ringEventId)
        if (!sameAttempt && !canPromoteAttempt) return false
        Log.i("OrexCallHandoff", "Expanded Flutter call UI ready call=$callId ring=$ringEventId")
        clearCallHandoffOverlay()
        intent.removeExtra(EXTRA_CALL_HANDOFF)
        return true
    }

    fun cancelCallHandoff(callId: String, ringEventId: String?): Boolean {
        val ownedCallId = callHandoffCallId ?: return false
        val sameAttempt = sameCallAttempt(
            ownedCallId,
            callHandoffRingEventId,
            callId,
            ringEventId,
        )
        val canPromoteAttempt = ownedCallId == callId &&
            canPromoteRingAttempt(callHandoffRingEventId, ringEventId)
        if (!sameAttempt && !canPromoteAttempt) return false
        Log.i(
            "OrexCallHandoff",
            "Flutter ended call before expanded UI became ready call=$callId ring=$ringEventId",
        )
        clearCallHandoffOverlay()
        intent.removeExtra(EXTRA_CALL_HANDOFF)
        return true
    }

    private fun clearCallHandoffOverlay() {
        callHandoffRevealTimeout?.let(callHandoffHandler::removeCallbacks)
        callHandoffRevealTimeout = null
        callHandoffTimeout?.let(callHandoffHandler::removeCallbacks)
        callHandoffTimeout = null
        val overlay = callHandoffOverlay
        callHandoffOverlay = null
        callHandoffCallId = null
        callHandoffRingEventId = null
        if (overlay != null) {
            (overlay.parent as? ViewGroup)?.removeView(overlay)
        }
    }

    private fun scheduleCallHandoffTimeout() {
        callHandoffRevealTimeout?.let(callHandoffHandler::removeCallbacks)
        callHandoffTimeout?.let(callHandoffHandler::removeCallbacks)
        val callId = callHandoffCallId ?: return
        val ringEventId = callHandoffRingEventId

        // Once Dart has promoted the descriptor to answered=true, the call is
        // already owned by the process runtime. Do not let a missing UI callback
        // keep a native cover above Flutter forever.
        callHandoffRevealTimeout = Runnable {
            if (!ownsCallHandoff(callId, ringEventId)) return@Runnable
            if (!OrexCallForegroundService.isAnsweredCall(
                    applicationContext,
                    callId,
                    ringEventId,
                )
            ) return@Runnable
            Log.w(
                "OrexCallHandoff",
                "Revealing answered call after UI handshake grace period " +
                    "call=$callId ring=$ringEventId",
            )
            clearCallHandoffOverlay()
            intent.removeExtra(EXTRA_CALL_HANDOFF)
        }.also { callHandoffHandler.postDelayed(it, CALL_HANDOFF_REVEAL_TIMEOUT_MS) }

        callHandoffTimeout = Runnable {
            if (!ownsCallHandoff(callId, ringEventId)) return@Runnable
            val answered = OrexCallForegroundService.isAnsweredCall(
                applicationContext,
                callId,
                ringEventId,
            )
            if (!answered) {
                OrexPushBridge.cancelPendingCallAction(
                    applicationContext,
                    callId,
                    ringEventId,
                )
                OrexCallForegroundService.stop(applicationContext, callId, ringEventId)
                Log.e("OrexCallHandoff", "Answer bootstrap timed out call=$callId ring=$ringEventId")
            } else {
                Log.w(
                    "OrexCallHandoff",
                    "Flutter route handshake timed out; revealing active app " +
                        "call=$callId ring=$ringEventId",
                )
            }
            clearCallHandoffOverlay()
            intent.removeExtra(EXTRA_CALL_HANDOFF)
        }.also {
            callHandoffHandler.postDelayed(
                it,
                OrexCallForegroundService.ANSWERING_TIMEOUT_MS,
            )
        }
    }

    private fun ownsCallHandoff(callId: String, ringEventId: String?): Boolean =
        sameOrPromotableCallAttempt(
            callHandoffCallId,
            callHandoffRingEventId,
            callId,
            ringEventId,
        )

    private val channelName = "orex/audio_devices"
    private val androidOutputPrefix = "orex://android/audio-output/"
    private var proximityWakeLock: PowerManager.WakeLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        OrexAndroidTelecomManager.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        OrexPushBridge.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        OrexSystemUiBridge.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "orex/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPrimaryAbi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull())
                    "getDistribution" -> result.success(
                        if (packageName.endsWith(".debug")) "debug" else "stable",
                    )
                    "installApk" -> installApk(
                        call.argument<String>("path"),
                        result,
                    )
                    else -> result.notImplemented()
                }
            }
        pictureInPictureChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "orex/picture_in_picture",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(isPictureInPictureSupported())
                    "enter" -> {
                        if (!isPictureInPictureSupported()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val params = pictureInPictureParams(
                            call.argument<Int>("width"),
                            call.argument<Int>("height"),
                        )
                        result.success(enterPictureInPictureMode(params))
                    }
                    "updateAspectRatio" -> {
                        if (!isPictureInPictureSupported()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val params = pictureInPictureParams(
                            call.argument<Int>("width"),
                            call.argument<Int>("height"),
                        )
                        val updated = runCatching {
                            setPictureInPictureParams(params)
                            true
                        }.getOrDefault(false)
                        result.success(updated)
                    }
                    "dismiss" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                            !isInPictureInPictureMode
                        ) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        // There is no symmetric public exitPictureInPictureMode().
                        // Do not finish/remove Orex's main Activity here: its Flutter
                        // engine intentionally survives the host and also owns fragile
                        // call/push handoff state. Moving the existing task to the back
                        // dismisses the PiP presentation without destroying that owner.
                        result.success(
                            runCatching { moveTaskToBack(false) }.getOrDefault(false),
                        )
                    }
                    else -> result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listAudioDevices" -> {
                        val includeCallRoutes = call.argument<Boolean>("includeCallRoutes") == true
                        result.success(listAudioDevices(includeCallRoutes))
                    }
                    "selectAudioOutput" -> {
                        val id = call.argument<String>("id")?.trim()?.takeIf { it.isNotEmpty() }
                        val inCall = call.argument<Boolean>("inCall") == true
                        if (OrexAndroidTelecomManager.ownsCallRouting()) {
                            if (!inCall) {
                                // Telecom завершит physical endpoint вместе с системной
                                // сессией. Здесь меняем только stream аппаратных клавиш:
                                // прямой AudioManager route всё ещё нельзя трогать до cleanup call.
                                volumeControlStream = AudioManager.STREAM_MUSIC
                                result.success(true)
                            } else {
                                // Core-Telecom owns the endpoint, while call media
                                // itself must stay on the voice-call stream for volume keys.
                                volumeControlStream = AudioManager.STREAM_VOICE_CALL
                                val route = parseRouteId(id)
                                val preferredEndpointName = route?.let { wanted ->
                                    availableOutputCandidates(
                                        audioManager(),
                                        includeCallRoutes = true,
                                    ).firstOrNull { it.matches(wanted) }
                                        ?.device
                                        ?.takeIf { it.requiresEndpointNameMatch() }
                                        ?.cleanProductName()
                                        ?.takeIf { it.isNotBlank() }
                                }
                                OrexAndroidTelecomManager.requestAudioRoute(
                                    route?.type,
                                    preferredEndpointName,
                                ) { applied -> result.success(applied) }
                            }
                        } else {
                            result.success(selectAudioOutput(id, inCall))
                        }
                    }
                    "setProximityEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        result.success(setProximityEnabled(enabled))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun installApk(
        rawPath: String?,
        result: MethodChannel.Result,
    ) {
        val file = rawPath
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let(::File)
        if (file == null || !file.isFile || !file.name.endsWith(".apk", ignoreCase = true)) {
            result.error("invalid_apk", "Downloaded APK is missing or invalid", null)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            try {
                val settingsIntent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                )
                startActivity(settingsIntent)
                result.success("permission_required")
            } catch (error: Exception) {
                Log.e("OrexUpdate", "Unable to open unknown-app-source settings", error)
                result.error("permission_settings_failed", error.message, null)
            }
            return
        }

        try {
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.orex_update_files",
                file,
            )
            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(installIntent)
            result.success("launched")
        } catch (error: Exception) {
            Log.e("OrexUpdate", "Unable to launch APK installer", error)
            result.error("installer_failed", error.message, null)
        }
    }

    private fun installScoBroadcastCrashGuard() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            if (isKnownScoReceiverReplyCrash(throwable)) {
                Log.w("OrexAudioDevices", "Ignored Android SCO receiver double-reply crash", throwable)
                return@setDefaultUncaughtExceptionHandler
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    private fun isKnownScoReceiverReplyCrash(throwable: Throwable): Boolean {
        if (throwable.message?.contains("Reply already submitted") != true) return false
        val text = throwable.stackTraceToString()
        return text.contains("ACTION_SCO_AUDIO_STATE_UPDATED") ||
            text.contains("onReceive") ||
            text.contains("ReceiverDispatcher")
    }

    private fun audioManager(): AudioManager =
        getSystemService(Context.AUDIO_SERVICE) as AudioManager

    @Suppress("DEPRECATION")
    private fun setProximityEnabled(enabled: Boolean): Boolean {
        if (!enabled) {
            val wakeLock = proximityWakeLock
            proximityWakeLock = null
            if (wakeLock?.isHeld == true) {
                try {
                    wakeLock.release()
                } catch (e: Throwable) {
                    Log.w("OrexAudioDevices", "proximity wake lock release failed", e)
                    return false
                }
            }
            return true
        }

        return try {
            val manager = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!manager.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
                return false
            }
            val wakeLock = proximityWakeLock ?: manager.newWakeLock(
                PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                "$packageName:orex-call-proximity",
            ).also { proximityWakeLock = it }
            if (!wakeLock.isHeld) wakeLock.acquire()
            true
        } catch (e: Throwable) {
            Log.w("OrexAudioDevices", "proximity wake lock update failed", e)
            false
        }
    }

    private fun listAudioDevices(includeCallRoutes: Boolean): List<Map<String, String>> {
        val items = linkedMapOf<String, RouteCandidate>()
        for (candidate in availableOutputCandidates(audioManager(), includeCallRoutes)) {
            val key = candidate.dedupKey()
            val previous = items[key]
            if (previous == null || candidate.score() < previous.score()) {
                items[key] = candidate
            }
        }

        val result = items.values
            .sortedWith(compareBy<RouteCandidate> { it.priority() }.thenBy { it.label().lowercase() })
            .map { it.toMap() }

        Log.d("OrexAudioDevices", "outputs=$result includeCallRoutes=$includeCallRoutes")
        return result
    }

    private fun availableOutputCandidates(
        manager: AudioManager,
        includeCallRoutes: Boolean,
    ): List<RouteCandidate> {
        val items = linkedMapOf<String, RouteCandidate>()

        fun add(device: AudioDeviceInfo, communication: Boolean) {
            if (!device.isUsefulOutput(includeCallRoutes)) return
            val candidate = RouteCandidate(device, communication)
            val key = candidate.routeId()
            val previous = items[key]
            if (previous == null || candidate.score() < previous.score()) items[key] = candidate
        }

        if (includeCallRoutes && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                manager.availableCommunicationDevices.forEach { add(it, communication = true) }
            } catch (e: Throwable) {
                Log.w("OrexAudioDevices", "availableCommunicationDevices failed", e)
            }
        }

        try {
            manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).forEach { add(it, communication = false) }
        } catch (e: Throwable) {
            Log.w("OrexAudioDevices", "get output devices failed", e)
        }

        return items.values.toList()
    }

    private fun selectAudioOutput(rawId: String?, inCall: Boolean): Boolean {
        val manager = audioManager()

        // Outside a LiveKit call we should not put Android into communication
        // routing. Media/notification playback belongs to STREAM_MUSIC and the
        // phone speaker is already the system default.
        if (!inCall) return resetMediaRouting(manager)

        val candidates = availableOutputCandidates(manager, includeCallRoutes = true)
        val route = parseRouteId(rawId)
        val requested = route?.let { wanted -> candidates.firstOrNull { it.matches(wanted) } }
        val target = when {
            route == null -> candidates.firstOrNull { it.device.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            requested == null -> null
            requested.communication -> requested
            requested.device.isBuiltInOutput() -> requested
            else -> candidates.firstOrNull {
                it.communication && it.dedupKey() == requested.dedupKey()
            }
        }

        if (target == null) {
            Log.w("OrexAudioDevices", "no applicable call route for id=$rawId")
            return route == null && forceSpeakerphone(manager)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return applyCommunicationRoute(manager, target)
        }
        return selectLegacyOutput(manager, target.device)
    }

    @Suppress("DEPRECATION")
    private fun resetMediaRouting(manager: AudioManager): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                manager.clearCommunicationDevice()
            }
            manager.mode = AudioManager.MODE_NORMAL
            manager.isSpeakerphoneOn = false
            volumeControlStream = AudioManager.STREAM_MUSIC
            true
        } catch (e: Throwable) {
            Log.w("OrexAudioDevices", "reset media route failed", e)
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun forceSpeakerphone(manager: AudioManager): Boolean {
        return try {
            manager.mode = AudioManager.MODE_IN_COMMUNICATION
            manager.isSpeakerphoneOn = true
            volumeControlStream = AudioManager.STREAM_VOICE_CALL
            true
        } catch (e: Throwable) {
            Log.w("OrexAudioDevices", "force speakerphone failed", e)
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun applyCommunicationRoute(manager: AudioManager, target: RouteCandidate): Boolean {
        return try {
            val isSpeaker = target.device.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
            manager.mode = AudioManager.MODE_IN_COMMUNICATION
            manager.isSpeakerphoneOn = isSpeaker
            val applied = if (target.communication || target.device.isBuiltInOutput()) {
                manager.setCommunicationDevice(target.device)
            } else {
                false
            }
            volumeControlStream = AudioManager.STREAM_VOICE_CALL
            applied || (isSpeaker && manager.isSpeakerphoneOn)
        } catch (e: Throwable) {
            Log.w("OrexAudioDevices", "set route failed ${target.routeId()}", e)
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun selectLegacyOutput(manager: AudioManager, target: AudioDeviceInfo?): Boolean {
        return try {
            manager.mode = AudioManager.MODE_IN_COMMUNICATION
            val isSpeaker = target?.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER || target == null
            if (target?.isBluetoothOutput() == true) {
                // Do not manually start Bluetooth SCO. Some Android stacks/plugins
                // crash on ACTION_SCO_AUDIO_STATE_UPDATED while a MethodChannel
                // reply is already completed. Modern Android uses
                // setCommunicationDevice(); old Android falls back to OS routing.
                Log.w("OrexAudioDevices", "legacy bluetooth route is left to Android")
                false
            } else {
                manager.isSpeakerphoneOn = isSpeaker
                volumeControlStream = AudioManager.STREAM_VOICE_CALL
                true
            }
        } catch (e: Throwable) {
            Log.w("OrexAudioDevices", "legacy route failed", e)
            false
        }
    }

    private fun parseRouteId(rawId: String?): AudioRouteId? {
        val value = rawId?.removePrefix(androidOutputPrefix)?.trim()
        if (value.isNullOrEmpty()) return null
        val parts = value.split(':')
        if (parts.size >= 3 && parts[0] == "audio") {
            return AudioRouteId(
                type = parts[1].toIntOrNull(),
                id = parts[2].toIntOrNull(),
            ).takeIf { it.id != null }
        }

        // Backward compatibility for ids saved by older patches: "type:id".
        if (parts.size == 2) {
            return AudioRouteId(
                type = parts[0].toIntOrNull(),
                id = parts[1].toIntOrNull(),
            ).takeIf { it.id != null }
        }
        return null
    }

    private inner class RouteCandidate(
        val device: AudioDeviceInfo,
        val communication: Boolean,
    ) {
        fun routeId(): String = "audio:${device.type}:${device.id}"

        fun matches(route: AudioRouteId): Boolean =
            device.id == route.id && (route.type == null || device.type == route.type)

        fun toMap(): Map<String, String> = mapOf(
            "id" to "$androidOutputPrefix${routeId()}",
            "kind" to "audiooutput",
            "label" to label(),
            "category" to category(),
        )

        fun dedupKey(): String = when {
            device.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "builtin:speaker"
            device.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "builtin:earpiece"
            device.isBluetoothOutput() -> "bluetooth:${device.stableExternalKey()}"
            device.isWiredOutput() -> "wired:${device.stableExternalKey()}"
            device.isUsbOutput() -> "usb:${device.stableExternalKey()}"
            else -> routeId()
        }

        fun score(): Int = when {
            communication && device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> 0
            communication -> 1
            device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> 2
            else -> 3
        }

        fun priority(): Int = when {
            device.isBluetoothOutput() -> 0
            device.isWiredOutput() || device.isUsbOutput() -> 1
            device.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> 8
            device.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> 9
            else -> 5
        }

        fun category(): String = when {
            device.isBluetoothOutput() -> "bluetooth"
            device.isWiredOutput() -> "headphones"
            device.isUsbOutput() -> "usb"
            device.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
            device.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
            else -> "output"
        }

        fun label(): String {
            when (device.type) {
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> return "Динамик телефона"
                AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> return "Разговорный динамик"
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> return "Проводные наушники"
                AudioDeviceInfo.TYPE_WIRED_HEADSET -> return "Проводная гарнитура"
            }

            val product = device.cleanProductName()
            if (product.isNotBlank()) return product

            return when {
                device.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth-наушники"
                device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth-гарнитура"
                device.isBleOutput() -> "Bluetooth LE-аудио"
                device.isHearingAidOutput() -> "Слуховое Bluetooth-устройство"
                device.isUsbOutput() -> "USB-аудио"
                else -> "Аудиовывод"
            }
        }
    }

    private fun AudioDeviceInfo.isUsefulOutput(includeCallRoutes: Boolean): Boolean = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_HEADSET -> true
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> includeCallRoutes
        else -> isBleOutput() || isHearingAidOutput()
    }

    private fun AudioDeviceInfo.requiresEndpointNameMatch(): Boolean =
        isBluetoothOutput() || isWiredOutput() || isUsbOutput()

    private fun AudioDeviceInfo.isBuiltInOutput(): Boolean =
        type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER ||
            type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE

    private fun AudioDeviceInfo.isBluetoothOutput(): Boolean = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> true
        else -> isBleOutput() || isHearingAidOutput()
    }

    private fun AudioDeviceInfo.isWiredOutput(): Boolean =
        type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
            type == AudioDeviceInfo.TYPE_WIRED_HEADSET

    private fun AudioDeviceInfo.isUsbOutput(): Boolean =
        type == AudioDeviceInfo.TYPE_USB_DEVICE || type == AudioDeviceInfo.TYPE_USB_HEADSET

    private fun AudioDeviceInfo.isBleOutput(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
            type == AudioDeviceInfo.TYPE_BLE_SPEAKER
    }

    private fun AudioDeviceInfo.isHearingAidOutput(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        return type == AudioDeviceInfo.TYPE_HEARING_AID
    }

    private fun AudioDeviceInfo.stableExternalKey(): String {
        val product = cleanProductName()
        if (product.isNotBlank()) return product.normalizedRouteName()
        val address = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                address.trim()
            } catch (_: Throwable) {
                ""
            }
        } else {
            ""
        }
        if (address.isNotBlank()) return address.lowercase()
        if (isBluetoothOutput()) return "bluetooth"
        return routeIdForKey()
    }

    private fun AudioDeviceInfo.routeIdForKey(): String = "audio:$type:$id"

    private fun AudioDeviceInfo.cleanProductName(): String {
        val product = productName?.toString()?.replace(Regex("\\s+"), " ")?.trim().orEmpty()
        if (product.isBlank() || product.equals("unknown", ignoreCase = true)) return ""
        if (product.looksLikeAndroidModelName()) return ""
        return product
    }

    private fun String.normalizedRouteName(): String =
        lowercase()
            .replace(Regex("\\b(headset|headphones|hands-free|stereo|audio|a2dp|sco)\\b"), "")
            .replace(Regex("[^a-z0-9а-яё]+"), "")
            .ifBlank { lowercase() }

    private fun String.looksLikeAndroidModelName(): Boolean {
        if (contains(' ')) return false
        return Regex("^(?=.*\\d)[A-Z0-9._-]{5,}$").matches(this)
    }

    private data class AudioRouteId(
        val type: Int?,
        val id: Int?,
    )

    companion object {
        private const val CALL_HANDOFF_REVEAL_TIMEOUT_MS = 8_000L
        const val EXTRA_CALL_HANDOFF = "orex_call_handoff"
        const val EXTRA_CALL_ID = "orex_call_id"
        const val EXTRA_RING_EVENT_ID = "orex_ring_event_id"
        const val EXTRA_DISPLAY_NAME = "orex_display_name"
        const val EXTRA_AVATAR_CACHE_KEY = "orex_avatar_cache_key"
    }
}

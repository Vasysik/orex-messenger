package ru.orex.messenger

import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        installScoBroadcastCrashGuard()
        super.onCreate(savedInstanceState)
        OrexPushBridge.captureLaunchIntent(this, intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
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
        OrexPushBridge.detach(this)
        super.onDestroy()
    }

    private val channelName = "orex/audio_devices"
    private val androidOutputPrefix = "orex://android/audio-output/"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        OrexAndroidTelecomManager.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        OrexPushBridge.attach(this, flutterEngine.dartExecutor.binaryMessenger)
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
                                // Telecom завершит communication routing вместе с системной
                                // сессией. Не сбрасываем AudioManager, пока call ещё зарегистрирован.
                                result.success(true)
                            } else {
                                volumeControlStream = AudioManager.STREAM_VOICE_CALL
                                val route = parseRouteId(id)
                                val preferredEndpointName = route?.let { wanted ->
                                    availableOutputCandidates(
                                        audioManager(),
                                        includeCallRoutes = true,
                                    ).firstOrNull { it.matches(wanted) }
                                        ?.device
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
                    else -> result.notImplemented()
                }
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
            manager.mode = AudioManager.MODE_NORMAL
            manager.isSpeakerphoneOn = true
            volumeControlStream = AudioManager.STREAM_MUSIC
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
            if (isSpeaker) {
                return forceSpeakerphone(manager)
            }
            manager.mode = AudioManager.MODE_IN_COMMUNICATION
            manager.isSpeakerphoneOn = false
            val applied = if (target.communication || target.device.isBuiltInOutput()) {
                manager.setCommunicationDevice(target.device)
            } else {
                false
            }
            volumeControlStream = AudioManager.STREAM_VOICE_CALL
            applied
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
                volumeControlStream = if (isSpeaker) {
                    AudioManager.STREAM_MUSIC
                } else {
                    AudioManager.STREAM_VOICE_CALL
                }
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


}

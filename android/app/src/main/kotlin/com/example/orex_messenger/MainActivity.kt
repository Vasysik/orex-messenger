package com.example.orex_messenger

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "orex/audio_devices"
    private val androidOutputPrefix = "orex://android/audio-output/"
    private val mainHandler = Handler(Looper.getMainLooper())
    private var selectedOutputId: String? = null
    private var audioDeviceCallback: AudioDeviceCallback? = null
    private val reapplyRouteRunnable = Runnable {
        selectedOutputId?.let { selectAudioOutput(it) }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerAudioDeviceCallbackOnce()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listAudioDevices" -> result.success(listAudioDevices())
                    "selectAudioOutput" -> {
                        selectedOutputId = call.argument<String>("id")?.trim()?.takeIf { it.isNotEmpty() }
                        result.success(selectAudioOutput(selectedOutputId))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        unregisterAudioDeviceCallback()
        super.onDestroy()
    }

    private fun audioManager(): AudioManager =
        getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun registerAudioDeviceCallbackOnce() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || audioDeviceCallback != null) return
        val callback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                scheduleRouteReapply()
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                scheduleRouteReapply()
            }
        }
        try {
            audioManager().registerAudioDeviceCallback(callback, mainHandler)
            audioDeviceCallback = callback
        } catch (e: Throwable) {
            Log.w("OrexAudioDevices", "register callback failed", e)
        }
    }

    private fun unregisterAudioDeviceCallback() {
        val callback = audioDeviceCallback ?: return
        audioDeviceCallback = null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            audioManager().unregisterAudioDeviceCallback(callback)
        } catch (_: Throwable) {}
    }

    private fun scheduleRouteReapply() {
        if (selectedOutputId == null) return
        mainHandler.removeCallbacks(reapplyRouteRunnable)
        mainHandler.postDelayed(reapplyRouteRunnable, 350L)
    }

    private fun listAudioDevices(): List<Map<String, String>> {
        val items = linkedMapOf<String, RouteCandidate>()
        for (candidate in availableOutputCandidates(audioManager())) {
            val key = candidate.dedupKey()
            val previous = items[key]
            if (previous == null || candidate.score() < previous.score()) {
                items[key] = candidate
            }
        }

        val result = items.values
            .sortedWith(compareBy<RouteCandidate> { it.priority() }.thenBy { it.label().lowercase() })
            .map { it.toMap() }

        Log.d("OrexAudioDevices", "outputs=$result")
        return result
    }

    private fun availableOutputCandidates(manager: AudioManager): List<RouteCandidate> {
        val items = linkedMapOf<String, RouteCandidate>()

        fun add(device: AudioDeviceInfo, communication: Boolean) {
            if (!device.isUsefulOutput()) return
            val candidate = RouteCandidate(device, communication)
            val key = candidate.routeId()
            val previous = items[key]
            if (previous == null || candidate.score() < previous.score()) items[key] = candidate
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
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

    private fun selectAudioOutput(rawId: String?): Boolean {
        val manager = audioManager()
        val route = parseRouteId(rawId)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (route == null) {
                return try {
                    manager.clearCommunicationDevice()
                    true
                } catch (e: Throwable) {
                    Log.w("OrexAudioDevices", "clear route failed", e)
                    false
                }
            }

            val candidates = availableOutputCandidates(manager)
            val requested = candidates.firstOrNull { it.matches(route) }
            val target = when {
                requested == null -> null
                requested.communication -> requested
                else -> candidates.firstOrNull {
                    it.communication && it.dedupKey() == requested.dedupKey()
                }
            } ?: requested?.takeIf { it.device.isBuiltInOutput() }

            if (target == null) return false

            return try {
                manager.mode = AudioManager.MODE_IN_COMMUNICATION
                if (target.communication || target.device.isBuiltInOutput()) {
                    manager.setCommunicationDevice(target.device)
                } else {
                    false
                }
            } catch (e: Throwable) {
                Log.w("OrexAudioDevices", "set route failed ${target.routeId()}", e)
                false
            }
        }

        val target = route?.let { wanted ->
            availableOutputCandidates(manager).firstOrNull { it.matches(wanted) }
        }
        return selectLegacyOutput(manager, target?.device)
    }

    @Suppress("DEPRECATION")
    private fun selectLegacyOutput(manager: AudioManager, target: AudioDeviceInfo?): Boolean {
        return try {
            manager.mode = AudioManager.MODE_IN_COMMUNICATION
            if (target?.isBluetoothOutput() == true) {
                manager.isSpeakerphoneOn = false
                manager.startBluetoothSco()
                manager.isBluetoothScoOn = true
                true
            } else {
                manager.isBluetoothScoOn = false
                manager.stopBluetoothSco()
                manager.isSpeakerphoneOn = target?.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
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

    private fun AudioDeviceInfo.isUsefulOutput(): Boolean = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_HEADSET -> true
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
        if (product.isNotBlank()) return product.lowercase()
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
        return routeIdForKey()
    }

    private fun AudioDeviceInfo.routeIdForKey(): String = "audio:$type:$id"

    private fun AudioDeviceInfo.cleanProductName(): String {
        val product = productName?.toString()?.replace(Regex("\\s+"), " ")?.trim().orEmpty()
        if (product.isBlank() || product.equals("unknown", ignoreCase = true)) return ""
        if (product.looksLikeAndroidModelName()) return ""
        return product
    }

    private fun String.looksLikeAndroidModelName(): Boolean {
        if (contains(' ')) return false
        return Regex("^(?=.*\\d)[A-Z0-9._-]{5,}$").matches(this)
    }

    private data class AudioRouteId(
        val type: Int?,
        val id: Int?,
    )
}

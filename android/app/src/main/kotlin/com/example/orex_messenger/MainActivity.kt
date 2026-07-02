package com.example.orex_messenger

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "orex/audio_devices"
    private val androidOutputPrefix = "orex://android/audio-output/"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listAudioDevices" -> result.success(listAudioDevices())
                    "selectAudioOutput" -> {
                        selectAudioOutput(call.argument<String>("id"))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun audioManager(): AudioManager =
        getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun listAudioDevices(): List<Map<String, String>> {
        val items = linkedMapOf<String, Map<String, String>>()
        for (device in availableOutputDevices(audioManager()).sortedBy { it.outputPriority() }) {
            addAudioDevice(items, device)
        }
        Log.d("OrexAudioDevices", "outputs=${items.values}")
        return items.values.toList()
    }

    private fun addAudioDevice(
        items: MutableMap<String, Map<String, String>>,
        device: AudioDeviceInfo,
    ) {
        val id = "$androidOutputPrefix${device.routeId()}"
        items.putIfAbsent(
            device.outputDedupKey(),
            mapOf(
                "id" to id,
                "kind" to "audiooutput",
                "label" to device.outputLabel(),
            ),
        )
    }

    private fun availableOutputDevices(manager: AudioManager): List<AudioDeviceInfo> {
        val devices = linkedMapOf<String, AudioDeviceInfo>()

        fun addAll(items: Iterable<AudioDeviceInfo>) {
            for (device in items) {
                if (device.isUsefulOutput()) devices[device.routeId()] = device
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                addAll(manager.availableCommunicationDevices)
            } catch (_: SecurityException) {}
        }

        try {
            addAll(manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).toList())
        } catch (_: SecurityException) {}

        return devices.values.toList()
    }

    private fun selectAudioOutput(rawId: String?) {
        val manager = audioManager()
        val route = parseRouteId(rawId)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (route == null) {
                manager.clearCommunicationDevice()
                return
            }
            val target = availableOutputDevices(manager).firstOrNull { it.matches(route) } ?: return
            manager.mode = AudioManager.MODE_IN_COMMUNICATION
            try {
                manager.setCommunicationDevice(target)
            } catch (_: SecurityException) {}
            return
        }

        val target = route?.let { wanted ->
            availableOutputDevices(manager).firstOrNull { it.matches(wanted) }
        }
        selectLegacyOutput(manager, target)
    }

    @Suppress("DEPRECATION")
    private fun selectLegacyOutput(manager: AudioManager, target: AudioDeviceInfo?) {
        manager.mode = AudioManager.MODE_IN_COMMUNICATION
        if (target?.isBluetoothOutput() == true) {
            manager.isSpeakerphoneOn = false
            manager.startBluetoothSco()
            manager.isBluetoothScoOn = true
            return
        }
        manager.isBluetoothScoOn = false
        manager.stopBluetoothSco()
        manager.isSpeakerphoneOn = target?.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
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

    private fun AudioDeviceInfo.matches(route: AudioRouteId): Boolean =
        id == route.id && (route.type == null || type == route.type)

    private fun AudioDeviceInfo.routeId(): String = "audio:$type:$id"

    private fun AudioDeviceInfo.outputDedupKey(): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "builtin:speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "builtin:earpiece"
        else -> routeId()
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

    private fun AudioDeviceInfo.isBluetoothOutput(): Boolean = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> true
        else -> isBleOutput() || isHearingAidOutput()
    }

    private fun AudioDeviceInfo.isBleOutput(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
            type == AudioDeviceInfo.TYPE_BLE_SPEAKER
    }

    private fun AudioDeviceInfo.isHearingAidOutput(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        return type == AudioDeviceInfo.TYPE_HEARING_AID
    }

    private fun AudioDeviceInfo.outputPriority(): Int = when {
        isBluetoothOutput() -> 0
        type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
            type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
            type == AudioDeviceInfo.TYPE_USB_DEVICE ||
            type == AudioDeviceInfo.TYPE_USB_HEADSET -> 1
        type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> 8
        type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> 9
        else -> 5
    }

    private fun AudioDeviceInfo.outputLabel(): String {
        when (type) {
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> return "Динамик телефона"
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> return "Разговорный динамик"
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> return "Проводные наушники"
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> return "Проводная гарнитура"
        }

        val product = productName?.toString()?.trim().orEmpty()
        if (product.isNotBlank() &&
            !product.equals("unknown", ignoreCase = true) &&
            !product.looksLikeAndroidModelName()) {
            return product
        }

        return when {
            type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth-наушники"
            type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth-гарнитура"
            type == AudioDeviceInfo.TYPE_USB_DEVICE ||
                type == AudioDeviceInfo.TYPE_USB_HEADSET -> "USB-аудио"
            isBleOutput() -> "Bluetooth LE-аудио"
            isHearingAidOutput() -> "Слуховое Bluetooth-устройство"
            else -> "Аудиовывод"
        }
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

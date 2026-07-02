package com.example.orex_messenger

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.pm.PackageManager
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
    private val bluetoothPermissionRequestCode = 48021
    private var pendingListResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listAudioDevices" -> listAudioDevices(result)
                    "selectAudioOutput" -> {
                        selectAudioOutput(call.argument<String>("id"))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == bluetoothPermissionRequestCode) {
            val result = pendingListResult
            pendingListResult = null
            if (result != null) listAudioDevices(result)
        }
    }

    private fun audioManager(): AudioManager =
        getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun listAudioDevices(result: MethodChannel.Result) {
        if (requestBluetoothPermissionForList(result)) return

        val manager = audioManager()
        val audioOutputs = availableOutputDevices(manager)
        val items = linkedMapOf<String, Map<String, String>>()

        for (device in audioOutputs.sortedBy { it.outputPriority() }) {
            addAudioDevice(items, device)
        }

        collectConnectedBluetoothRoutes { routes ->
            for (route in routes) {
                val matched = audioOutputs.firstOrNull { it.matchesBluetooth(route) }
                if (matched != null) {
                    addAudioDevice(items, matched, route.label)
                } else {
                    addBluetoothDevice(items, route)
                }
            }
            Log.d("OrexAudioDevices", "outputs=${items.values}")
            result.success(items.values.toList())
        }
    }

    private fun requestBluetoothPermissionForList(result: MethodChannel.Result): Boolean {
        if (!needsBluetoothConnectPermission()) return false
        if (pendingListResult != null) {
            result.success(listAudioDevicesWithoutBluetoothProfiles())
            return true
        }
        pendingListResult = result
        requestPermissions(
            arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
            bluetoothPermissionRequestCode
        )
        return true
    }

    private fun needsBluetoothConnectPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) !=
            PackageManager.PERMISSION_GRANTED
    }

    private fun listAudioDevicesWithoutBluetoothProfiles(): List<Map<String, String>> {
        val items = linkedMapOf<String, Map<String, String>>()
        for (device in availableOutputDevices(audioManager()).sortedBy { it.outputPriority() }) {
            addAudioDevice(items, device)
        }
        return items.values.toList()
    }

    private fun addAudioDevice(
        items: MutableMap<String, Map<String, String>>,
        device: AudioDeviceInfo,
        overrideLabel: String? = null,
    ) {
        val id = "$androidOutputPrefix${device.routeId()}"
        items[id] = mapOf(
            "id" to id,
            "kind" to "audiooutput",
            "label" to device.outputLabel(overrideLabel),
        )
    }

    private fun addBluetoothDevice(
        items: MutableMap<String, Map<String, String>>,
        route: BluetoothRoute,
    ) {
        val id = "$androidOutputPrefix${route.routeId()}"
        items[id] = mapOf(
            "id" to id,
            "kind" to "audiooutput",
            "label" to route.label,
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
            } catch (_: SecurityException) {
                // Bluetooth routes require BLUETOOTH_CONNECT on Android 12+.
            }
        }

        try {
            addAll(manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).toList())
        } catch (_: SecurityException) {
            // Keep the communication routes collected above.
        }

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
            val outputs = availableOutputDevices(manager)
            val target = outputs.firstOrNull { it.matches(route) }
                ?: outputs.firstOrNull { route.isBluetooth && it.isBluetoothOutput() }
                ?: return
            manager.mode = AudioManager.MODE_IN_COMMUNICATION
            try {
                manager.setCommunicationDevice(target)
            } catch (_: SecurityException) {}
            return
        }

        val target = route?.let { wanted ->
            availableOutputDevices(manager).firstOrNull { it.matches(wanted) }
        }
        selectLegacyOutput(manager, target, route)
    }

    @Suppress("DEPRECATION")
    private fun selectLegacyOutput(
        manager: AudioManager,
        target: AudioDeviceInfo?,
        route: AudioRouteId?,
    ) {
        manager.mode = AudioManager.MODE_IN_COMMUNICATION
        if (target?.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO || route?.isBluetooth == true) {
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
                bluetoothAddressKey = null,
            ).takeIf { it.id != null }
        }
        if (parts.size >= 3 && parts[0] == "bt") {
            return AudioRouteId(
                type = null,
                id = null,
                bluetoothAddressKey = parts[2],
            )
        }

        // Backward compatibility for ids saved by the previous patch: "type:id".
        if (parts.size == 2) {
            return AudioRouteId(
                type = parts[0].toIntOrNull(),
                id = parts[1].toIntOrNull(),
                bluetoothAddressKey = null,
            ).takeIf { it.id != null }
        }
        return null
    }

    private fun AudioDeviceInfo.matches(route: AudioRouteId): Boolean {
        if (route.bluetoothAddressKey != null) {
            return isBluetoothOutput() && safeAddress().toAddressKey() == route.bluetoothAddressKey
        }
        return id == route.id && (route.type == null || type == route.type)
    }

    private fun AudioDeviceInfo.matchesBluetooth(route: BluetoothRoute): Boolean =
        isBluetoothOutput() && safeAddress().toAddressKey() == route.addressKey

    private fun AudioDeviceInfo.routeId(): String = "audio:$type:$id"

    private fun AudioDeviceInfo.isUsefulOutput(): Boolean = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_HEADSET -> true
        else -> isBleOutput()
    }

    private fun AudioDeviceInfo.isBluetoothOutput(): Boolean = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> true
        else -> isBleOutput()
    }

    private fun AudioDeviceInfo.isBleOutput(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
            type == AudioDeviceInfo.TYPE_BLE_SPEAKER
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

    private fun AudioDeviceInfo.outputLabel(overrideLabel: String? = null): String {
        if (!overrideLabel.isNullOrBlank()) return overrideLabel
        val product = productName?.toString()?.trim().orEmpty()
        if (product.isNotBlank() && !product.equals("unknown", ignoreCase = true)) return product
        return when (type) {
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "Встроенный динамик"
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "Разговорный динамик"
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "Проводные наушники"
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Проводная гарнитура"
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth-аудио"
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_HEADSET -> "USB-аудио"
            else -> if (isBleOutput()) "Bluetooth LE-аудио" else "Аудиовывод"
        }
    }

    @SuppressLint("MissingPermission")
    private fun AudioDeviceInfo.safeAddress(): String = try {
        address.orEmpty()
    } catch (_: SecurityException) {
        ""
    }

    private fun collectConnectedBluetoothRoutes(callback: (List<BluetoothRoute>) -> Unit) {
        val adapter = bluetoothAdapter() ?: run {
            callback(emptyList())
            return
        }
        if (!hasBluetoothAccess()) {
            callback(emptyList())
            return
        }

        val profiles = mutableListOf(BluetoothProfile.HEADSET, BluetoothProfile.A2DP)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            profiles.add(BluetoothProfile.HEARING_AID)
        }
        val pending = profiles.toMutableSet()
        val routes = linkedMapOf<String, BluetoothRoute>()
        var finished = false

        fun finishOnce() {
            if (finished) return
            finished = true
            callback(routes.values.toList())
        }

        val listener = object : BluetoothProfile.ServiceListener {
            @SuppressLint("MissingPermission")
            override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                try {
                    for (device in proxy.connectedDevices) {
                        val route = device.toBluetoothRoute(profile) ?: continue
                        routes[route.routeId()] = route
                    }
                } catch (_: SecurityException) {
                    // Permission can be revoked while the picker is open.
                } finally {
                    adapter.closeProfileProxy(profile, proxy)
                    pending.remove(profile)
                    if (pending.isEmpty()) finishOnce()
                }
            }

            override fun onServiceDisconnected(profile: Int) {
                pending.remove(profile)
                if (pending.isEmpty()) finishOnce()
            }
        }

        var requested = 0
        for (profile in profiles) {
            try {
                if (adapter.getProfileProxy(this, listener, profile)) {
                    requested++
                } else {
                    pending.remove(profile)
                }
            } catch (_: Throwable) {
                pending.remove(profile)
            }
        }

        if (requested == 0 || pending.isEmpty()) {
            finishOnce()
            return
        }

        Handler(Looper.getMainLooper()).postDelayed({ finishOnce() }, 700)
    }

    private fun bluetoothAdapter(): BluetoothAdapter? =
        (getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
            ?: BluetoothAdapter.getDefaultAdapter()

    private fun hasBluetoothAccess(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    private fun BluetoothDevice.toBluetoothRoute(profile: Int): BluetoothRoute? {
        val rawAddress = try { address } catch (_: SecurityException) { null }
        val addressKey = rawAddress?.toAddressKey().orEmpty()
        if (addressKey.isEmpty()) return null
        val rawName = try { name } catch (_: SecurityException) { null }
        val fallback = profileBluetoothLabel(profile)
        val label = rawName?.trim()?.takeIf { it.isNotEmpty() }?.let { "$fallback · $it" }
            ?: fallback
        return BluetoothRoute(profile = profile, addressKey = addressKey, label = label)
    }

    private fun profileBluetoothLabel(profile: Int): String = when (profile) {
        BluetoothProfile.HEADSET -> "Bluetooth-гарнитура"
        BluetoothProfile.A2DP -> "Bluetooth-аудио"
        BluetoothProfile.HEARING_AID -> "Bluetooth hearing aid"
        else -> "Bluetooth-аудио"
    }

    private fun String.toAddressKey(): String =
        replace(Regex("[^A-Za-z0-9]"), "").uppercase()

    private data class AudioRouteId(
        val type: Int?,
        val id: Int?,
        val bluetoothAddressKey: String?,
    ) {
        val isBluetooth: Boolean get() = bluetoothAddressKey != null
    }

    private data class BluetoothRoute(
        val profile: Int,
        val addressKey: String,
        val label: String,
    ) {
        fun routeId(): String = "bt:$profile:$addressKey"
    }
}

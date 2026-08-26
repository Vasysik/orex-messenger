package ru.orex.messenger

import android.app.Activity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * Activity-scoped system UI bridge for the process-owned Flutter engine.
 *
 * Flutter's SystemChrome immersive modes are ignored by Android when the app
 * targets API 36+, while WindowInsetsController remains the supported native
 * way to hide system bars for a genuine fullscreen media surface.
 */
object OrexSystemUiBridge {
    private const val CHANNEL_NAME = "orex/system_ui"

    private var activityRef: WeakReference<Activity>? = null
    private var messenger: BinaryMessenger? = null
    private var channel: MethodChannel? = null

    @Synchronized
    fun attach(activity: Activity, binaryMessenger: BinaryMessenger) {
        activityRef = WeakReference(activity)
        if (messenger === binaryMessenger && channel != null) return

        channel?.setMethodCallHandler(null)
        messenger = binaryMessenger
        channel = MethodChannel(binaryMessenger, CHANNEL_NAME).also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                handleMethodCall(call, result)
            }
        }
    }

    @Synchronized
    fun detach(activity: Activity) {
        if (activityRef?.get() === activity) {
            activityRef = null
        }
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setMediaFullscreen" -> {
                val activity = activityRef?.get()
                if (activity == null || activity.isFinishing || activity.isDestroyed) {
                    result.success(false)
                    return
                }
                val enabled = call.argument<Boolean>("enabled") == true
                result.success(runCatching {
                    setMediaFullscreen(activity, enabled)
                    true
                }.getOrDefault(false))
            }
            else -> result.notImplemented()
        }
    }

    private fun setMediaFullscreen(activity: Activity, enabled: Boolean) {
        val controller = WindowCompat.getInsetsController(
            activity.window,
            activity.window.decorView,
        )
        if (enabled) {
            controller.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }
}

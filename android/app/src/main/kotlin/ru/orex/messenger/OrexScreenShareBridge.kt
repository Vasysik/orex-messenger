package ru.orex.messenger

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Native boundary for Android MediaProjection foreground ownership. */
object OrexScreenShareBridge {
    const val CHANNEL_NAME = "orex/screen_share"

    private const val TAG = "OrexScreenShare"

    @Volatile
    private var channel: MethodChannel? = null

    fun attach(context: Context, messenger: BinaryMessenger) {
        val applicationContext = context.applicationContext
        channel = MethodChannel(messenger, CHANNEL_NAME).also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                handleMethodCall(applicationContext, call, result)
            }
        }
    }

    /** Asks the process-owned Dart isolate to unpublish and release capture. */
    fun requestDartStop(reason: String) {
        val activeChannel = channel
        if (activeChannel == null) {
            Log.w(TAG, "Screen-share stop request dropped: Dart channel unavailable reason=$reason")
            return
        }
        Handler(Looper.getMainLooper()).post {
            activeChannel.invokeMethod(
                "screenShareStopRequested",
                mapOf("reason" to reason),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (result != true) {
                            Log.w(TAG, "Dart did not accept screen-share stop request reason=$reason")
                        }
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        Log.w(
                            TAG,
                            "Dart screen-share stop request failed code=$code reason=$reason: $message",
                        )
                    }

                    override fun notImplemented() {
                        Log.w(TAG, "Dart does not implement screen-share stop request")
                    }
                },
            )
        }
    }

    private fun handleMethodCall(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "startForeground" -> result.success(OrexScreenShareForegroundService.start(context))
            "isForegroundReady" -> result.success(OrexScreenShareForegroundService.isReady())
            "stopForeground" -> result.success(OrexScreenShareForegroundService.stop(context))
            else -> result.notImplemented()
        }
    }
}

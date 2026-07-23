package ru.orex.messenger

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Dedicated foreground owner for an active Android MediaProjection.
 *
 * The call service remains responsible for the call's recoverable descriptor;
 * this shorter-lived service exists only from MediaProjection consent until the
 * screen video track is unpublished.
 */
class OrexScreenShareForegroundService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var stopWatchdog: Runnable? = null
    private var screenOffReceiverRegistered = false

    private val screenOffReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_SCREEN_OFF) {
                // Android revokes a projection on lock. This is a safe fallback
                // in addition to the patched flutter_webrtc onStop event.
                requestDartStop("screen_off")
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        serviceRunning = true
        foregroundReady = false
        registerScreenOffReceiver()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_REQUEST_STOP -> {
                requestDartStop("notification")
                return START_NOT_STICKY
            }
            ACTION_START, null -> startForegroundOwnership()
            else -> Log.w(TAG, "Unknown screen-share service action=${intent.action}")
        }
        // A MediaProjection consent token cannot be reused after restart.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        foregroundReady = false
        serviceRunning = false
        stopWatchdog?.let(handler::removeCallbacks)
        stopWatchdog = null
        unregisterScreenOffReceiver()
        stopForegroundCompat()
        OrexNotificationCenter.cancelScreenShareNotification(applicationContext)
        super.onDestroy()
    }

    private fun startForegroundOwnership() {
        stopWatchdog?.let(handler::removeCallbacks)
        stopWatchdog = null
        try {
            val notification = OrexNotificationCenter.buildScreenShareForeground(
                context = this,
                stop = stopPendingIntent(),
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    OrexNotificationCenter.SCREEN_SHARE_NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
                )
            } else {
                startForeground(OrexNotificationCenter.SCREEN_SHARE_NOTIFICATION_ID, notification)
            }
            foregroundReady = true
            Log.i(TAG, "MediaProjection foreground owner is ready")
        } catch (error: Throwable) {
            foregroundReady = false
            Log.e(TAG, "Unable to enter mediaProjection foreground state", error)
            stopSelf()
        }
    }

    private fun requestDartStop(reason: String) {
        if (!serviceRunning) return
        Log.i(TAG, "Requesting Dart screen-share stop reason=$reason")
        OrexScreenShareBridge.requestDartStop(reason)
        stopWatchdog?.let(handler::removeCallbacks)
        stopWatchdog = Runnable {
            Log.w(TAG, "Dart did not release screen capture; stopping foreground owner")
            stopSelf()
        }.also { handler.postDelayed(it, STOP_ACK_TIMEOUT_MS) }
    }

    private fun stopPendingIntent(): PendingIntent = PendingIntent.getService(
        this,
        STOP_PENDING_INTENT_REQUEST_CODE,
        Intent(this, OrexScreenShareForegroundService::class.java).apply {
            action = ACTION_REQUEST_STOP
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun registerScreenOffReceiver() {
        if (screenOffReceiverRegistered) return
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(screenOffReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(screenOffReceiver, filter)
            }
            screenOffReceiverRegistered = true
        } catch (error: Throwable) {
            Log.w(TAG, "Unable to observe screen-off for projection cleanup", error)
        }
    }

    private fun unregisterScreenOffReceiver() {
        if (!screenOffReceiverRegistered) return
        screenOffReceiverRegistered = false
        try {
            unregisterReceiver(screenOffReceiver)
        } catch (error: Throwable) {
            Log.w(TAG, "Unable to unregister screen-off receiver", error)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    companion object {
        private const val TAG = "OrexScreenShare"
        private const val ACTION_START = "ru.orex.messenger.action.START_SCREEN_SHARE"
        private const val ACTION_REQUEST_STOP = "ru.orex.messenger.action.REQUEST_STOP_SCREEN_SHARE"
        private const val STOP_PENDING_INTENT_REQUEST_CODE = 7311
        private const val STOP_ACK_TIMEOUT_MS = 8_000L

        @Volatile
        private var serviceRunning = false

        @Volatile
        private var foregroundReady = false

        fun start(context: Context): Boolean {
            foregroundReady = false
            return try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, OrexScreenShareForegroundService::class.java).apply {
                        action = ACTION_START
                    },
                )
                true
            } catch (error: Throwable) {
                Log.e(TAG, "Unable to start mediaProjection foreground owner", error)
                false
            }
        }

        fun stop(context: Context): Boolean {
            foregroundReady = false
            return try {
                context.stopService(Intent(context, OrexScreenShareForegroundService::class.java))
            } catch (error: Throwable) {
                Log.w(TAG, "Unable to stop mediaProjection foreground owner", error)
                false
            }
        }

        fun isReady(): Boolean = serviceRunning && foregroundReady
    }
}

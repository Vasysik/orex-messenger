package ru.orex.messenger

import android.os.Looper
import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class OrexFirebaseMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        OrexPushBridge.onTokenRefresh(this, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val completed = CountDownLatch(1)
        OrexPushBridge.onMessageReceived(this, message) {
            completed.countDown()
        }

        // Firebase invokes this callback on a worker thread. Keep that callback
        // alive while the one-shot Matrix client fetches/decrypts the event;
        // otherwise Android may tear down the process before notification/call UI
        // is posted. Never block the main looper if an OEM dispatches differently.
        if (Looper.myLooper() != Looper.getMainLooper()) {
            try {
                if (!completed.await(42, TimeUnit.SECONDS)) {
                    Log.w("OrexPush", "Push processing exceeded service lifetime budget")
                }
            } catch (error: InterruptedException) {
                Thread.currentThread().interrupt()
                Log.w("OrexPush", "Push processing interrupted", error)
            }
        }
    }
}

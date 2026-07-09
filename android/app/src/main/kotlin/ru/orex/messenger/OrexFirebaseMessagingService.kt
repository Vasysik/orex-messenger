package ru.orex.messenger

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class OrexFirebaseMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        OrexPushBridge.onTokenRefresh(this, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        // FCM callback stays intentionally short: no network, no DB, no FlutterEngine.
        OrexPushBridge.onMessageReceived(this, message)
    }
}

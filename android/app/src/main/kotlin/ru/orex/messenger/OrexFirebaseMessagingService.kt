package ru.orex.messenger

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class OrexFirebaseMessagingService : FirebaseMessagingService() {
    @Deprecated(
        message = "Orex currently registers Matrix pushers with legacy FCM registration tokens.",
    )
    override fun onNewToken(token: String) {
        OrexPushBridge.onTokenRefresh(this, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        // FCM callback stays intentionally short: no network, no DB, no FlutterEngine.
        OrexPushBridge.onMessageReceived(this, message)
    }
}

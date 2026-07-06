package ru.orex.messenger

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Нативная точка входа FCM. Android может создать этот Service, когда Flutter
 * engine и Activity ещё не запущены, поэтому здесь нет зависимости от Dart.
 */
class OrexFirebaseMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        OrexPushBridge.onTokenRefresh(this, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        OrexPushBridge.onMessageReceived(this, message)
    }
}

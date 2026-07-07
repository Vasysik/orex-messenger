package ru.orex.messenger

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Handles CallStyle actions both for push-only calls and active Telecom calls. */
class OrexNotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        OrexPushBridge.handleCallNotificationAction(context, intent)
    }
}

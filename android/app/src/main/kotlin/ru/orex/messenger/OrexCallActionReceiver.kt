package ru.orex.messenger

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Действия CallStyle-уведомления; закрытый процесс появится в roadmap 0.4.0/2. */
class OrexCallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        OrexAndroidTelecomManager.handleNotificationAction(intent)
    }
}

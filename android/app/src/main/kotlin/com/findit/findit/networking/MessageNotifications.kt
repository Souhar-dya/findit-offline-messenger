package com.findit.findit.networking

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import com.findit.findit.MainActivity
import com.findit.findit.R
import java.util.concurrent.atomic.AtomicInteger

/**
 * Local "new message" notifications.
 *
 * Only ever called by the Dart layer for an inbound message that decrypted to
 * *this* device's own identity, so a notification is never shown for a message
 * addressed to somebody else (a device only ever holds a decryption key for its
 * own identity).
 */
object MessageNotifications {

    private const val CHANNEL_ID = "findit_messages"
    private const val TAG = "findit_message"

    private val nextId = AtomicInteger(1)

    /** Posts a notification for one newly received message. */
    fun show(context: Context, title: String, body: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
            as? NotificationManager ?: return
        createChannel(manager)
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setSmallIcon(R.drawable.ic_stat_findit)
            .setAutoCancel(true)
            .setContentIntent(openApp(context))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .build()
        // A distinct id per message so several arrivals stack instead of
        // overwriting each other.
        manager.notify(TAG, nextId.getAndIncrement(), notification)
    }

    private fun createChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Messages",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "A new message arrived for you."
        }
        manager.createNotificationChannel(channel)
    }

    private fun openApp(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}

package com.findit.findit.networking

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.findit.findit.MainActivity
import com.findit.findit.R

/**
 * A foreground service that keeps the FindIt process alive while the master
 * networking switch is on, so Wi-Fi Direct discovery and the TCP receive socket
 * keep working when the app is not on screen.
 *
 * The service owns no protocol logic: it exists purely to hold the process (and
 * the Flutter engine inside it) out of Android's background-freeze/kill path,
 * and to show an ongoing notification so the user always knows the radio is on.
 * It is started and stopped by [PlatformTransportChannel] alongside the native
 * transport.
 */
class NetworkingService : Service() {

    companion object {
        private const val CHANNEL_ID = "findit_networking"
        private const val NOTIFICATION_ID = 0xF17

        /** Starts (or refreshes) the foreground service. */
        fun start(context: Context) {
            val intent = Intent(context, NetworkingService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Stops the service and removes its notification. */
        fun stop(context: Context) {
            context.stopService(Intent(context, NetworkingService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // Not sticky: if the process is killed we do not want a notification
        // claiming FindIt is on while nothing is actually running.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Nearby networking",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown while FindIt is discovering nearby devices."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("FindIt is on")
            .setContentText("Discovering nearby devices and receiving messages.")
            .setSmallIcon(R.drawable.ic_stat_findit)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(openApp)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }
}

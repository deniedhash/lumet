package com.deniedhashtag.lumet.dashcam

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import com.deniedhashtag.lumet.MainActivity
import com.deniedhashtag.lumet.R

object DashcamNotification {

    const val CHANNEL_ID = "lumet.dashcam"
    const val NOTIFICATION_ID = 0x4C55 // 'LU'

    fun ensureChannel(context: Context) {
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.dashcam_channel_name),
            // No sound and no heads-up: this is a status indicator, not an alert.
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = context.getString(R.string.dashcam_channel_description)
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        context.getSystemService(NotificationManager::class.java)
            .createNotificationChannel(channel)
    }

    fun build(context: Context, state: DashcamState): Notification {
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val stop = PendingIntent.getService(
            context,
            1,
            Intent(context, DashcamService::class.java).setAction(DashcamService.ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_dashcam_rec)
            .setContentTitle(if (state.streaming) "Lumet — LIVE" else "Lumet — REC")
            .setContentText(state.summaryLine())
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            // Skip the 10s deferral: visible proof the dashcam is live is the
            // whole point of this notification.
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(open)
            .addAction(0, "Stop", stop)
            .build()
    }
}

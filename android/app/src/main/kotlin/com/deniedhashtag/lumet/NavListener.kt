package com.deniedhashtag.lumet

import android.app.Notification
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.Icon
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import java.io.ByteArrayOutputStream

/**
 * Reads the ongoing notification that navigation apps post while a route is
 * running, and forwards the turn instruction to Flutter.
 *
 * Matching is on Notification.CATEGORY_NAVIGATION rather than a package name,
 * so any navigation app that follows the platform convention works, not just
 * Google Maps.
 */
class NavListener : NotificationListenerService() {

    companion object {
        /** Set by MainActivity while the Flutter engine is attached. */
        var sink: ((Map<String, Any?>) -> Unit)? = null

        /** Last known state, so a late-attaching engine is not left blank. */
        var latest: Map<String, Any?>? = null

        private val main = Handler(Looper.getMainLooper())

        private fun emit(data: Map<String, Any?>) {
            latest = if (data["active"] == true) data else null
            main.post { sink?.invoke(data) }
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val notification = sbn.notification ?: return
        if (notification.category != Notification.CATEGORY_NAVIGATION) return

        val extras = notification.extras
        emit(
            mapOf(
                "active" to true,
                "package" to sbn.packageName,
                "distance" to extras.getCharSequence("android.title")?.toString(),
                "instruction" to extras.getCharSequence("android.text")?.toString(),
                "eta" to extras.getCharSequence("android.subText")?.toString(),
                "icon" to turnIcon(notification)
            )
        )
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        val notification = sbn.notification ?: return
        if (notification.category != Notification.CATEGORY_NAVIGATION) return
        emit(mapOf("active" to false))
    }

    /**
     * The turn arrow as PNG bytes.
     *
     * Prefers the ongoing-activity icon: it is larger and already tinted white,
     * which is what a HUD wants. Falls back to the notification's large icon.
     */
    private fun turnIcon(notification: Notification): ByteArray? {
        @Suppress("DEPRECATION")
        val icon = notification.extras
            .getParcelable<Icon>("android.ongoingActivityNoti.secondIcon")
            ?: notification.getLargeIcon()
            ?: return null

        return try {
            toPng(icon.loadDrawable(this) ?: return null)
        } catch (e: Exception) {
            null
        }
    }

    private fun toPng(drawable: Drawable): ByteArray? {
        val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
            drawable.bitmap
        } else {
            val width = drawable.intrinsicWidth.takeIf { it > 0 } ?: 144
            val height = drawable.intrinsicHeight.takeIf { it > 0 } ?: 144
            Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
                val canvas = Canvas(it)
                drawable.setBounds(0, 0, canvas.width, canvas.height)
                drawable.draw(canvas)
            }
        }
        val out = ByteArrayOutputStream()
        return if (bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) {
            out.toByteArray()
        } else {
            null
        }
    }
}

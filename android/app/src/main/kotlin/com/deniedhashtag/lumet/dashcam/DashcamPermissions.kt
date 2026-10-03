package com.deniedhashtag.lumet.dashcam

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

/**
 * Camera, microphone and notification permission state for the dashcam.
 *
 * Hand-rolled rather than pulling in permission_handler. The request has to come
 * from the visible activity regardless — a camera foreground service cannot be
 * started while the app is in the background — and [MainActivity] already owns a
 * method channel, so a plugin would add an AAR and an ActivityAware lifecycle
 * without solving the part that is actually hard. `lumet/nav_control` set the
 * precedent for hand-written capability checks.
 */
object DashcamPermissions {

    /**
     * Camera and microphone are hard requirements. POST_NOTIFICATIONS is not:
     * with it denied the service still runs, the notification is simply not
     * shown and the dashcam appears only in the foreground-service task manager.
     */
    fun required(): List<String> = buildList {
        add(Manifest.permission.CAMERA)
        add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            add(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    fun has(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED

    fun hasCamera(context: Context) = has(context, Manifest.permission.CAMERA)

    fun hasMicrophone(context: Context) = has(context, Manifest.permission.RECORD_AUDIO)

    /** Vacuously true below API 33, where the permission does not exist. */
    fun hasNotifications(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            has(context, Manifest.permission.POST_NOTIFICATIONS)

    /** Everything the recorder needs before it can run at all. */
    fun ready(context: Context) = hasCamera(context) && hasMicrophone(context)

    fun missing(context: Context): List<String> = required().filterNot { has(context, it) }

    /** No camera at all means the dashcam is never going to work on this device. */
    fun isSupported(context: Context): Boolean =
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)

    fun snapshot(context: Context): Map<String, Any?> = mapOf(
        "camera" to hasCamera(context),
        "microphone" to hasMicrophone(context),
        "notifications" to hasNotifications(context),
        "ready" to ready(context),
    )
}

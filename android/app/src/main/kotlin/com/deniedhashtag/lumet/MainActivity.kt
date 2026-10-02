package com.deniedhashtag.lumet

import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val eventChannelName = "lumet/nav"
    private val controlChannelName = "lumet/nav_control"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, eventChannelName).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    NavListener.sink = { data -> events?.success(data) }
                    // Replay the current route so a restart is not blank until
                    // the next turn.
                    NavListener.latest?.let { events?.success(it) }
                }

                override fun onCancel(arguments: Any?) {
                    NavListener.sink = null
                }
            }
        )

        MethodChannel(messenger, controlChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "isEnabled" -> result.success(isListenerEnabled())
                "openSettings" -> {
                    startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Notification access is granted by the user in Settings, not by a dialog. */
    private fun isListenerEnabled(): Boolean {
        val enabled = Settings.Secure.getString(
            contentResolver,
            "enabled_notification_listeners"
        ) ?: return false
        return enabled.split(":").any { it.startsWith("$packageName/") }
    }
}

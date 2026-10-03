package com.deniedhashtag.lumet

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.view.Surface
import androidx.core.app.ActivityCompat
import com.deniedhashtag.lumet.dashcam.DashcamBridge
import com.deniedhashtag.lumet.dashcam.DashcamConfig
import com.deniedhashtag.lumet.dashcam.DashcamKeyStore
import com.deniedhashtag.lumet.dashcam.DashcamPermissions
import com.deniedhashtag.lumet.dashcam.DashcamService
import com.deniedhashtag.lumet.dashcam.DashcamState
import com.deniedhashtag.lumet.dashcam.SegmentStore
import com.deniedhashtag.lumet.dashcam.Phase
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val eventChannelName = "lumet/nav"
    private val controlChannelName = "lumet/nav_control"
    private val dashcamControlChannelName = "lumet/dashcam_control"
    private val dashcamEventChannelName = "lumet/dashcam"

    private val dashcamPermissionRequest = 0x0D01
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var rationaleBefore: Map<String, Boolean> = emptyMap()

    /** A camera foreground service may only be started while we are visible. */
    private var visible = false

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

        EventChannel(messenger, dashcamEventChannelName).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    DashcamBridge.sink = { data -> events?.success(data) }
                    // The service outlives the engine, so a fresh engine has to be
                    // told the current state even when that state is "idle".
                    events?.success(DashcamBridge.latest ?: DashcamState().toMap())
                }

                override fun onCancel(arguments: Any?) {
                    DashcamBridge.sink = null
                }
            }
        )

        // Dashcam control. Handled here rather than in a service or a plugin
        // because a camera foreground service may only be started while the app
        // is visible, so every command has to originate from the activity.
        MethodChannel(messenger, dashcamControlChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(DashcamPermissions.isSupported(this))
                    "permissions" -> result.success(DashcamPermissions.snapshot(this))
                    "requestPermissions" -> requestDashcamPermissions(result)
                    "openAppSettings" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.fromParts("package", packageName, null)
                            )
                        )
                        result.success(null)
                    }
                    "rotation" -> result.success(cameraRotation())
                    // The key never travels anywhere but between the editor and
                    // these three methods, and is never written to a log.
                    "streamKey" -> result.success(DashcamKeyStore.get(this))
                    "setStreamKey" -> {
                        DashcamKeyStore.set(this, call.argument<String>("key") ?: "")
                        result.success(null)
                    }
                    "clearStreamKey" -> {
                        DashcamKeyStore.clear(this)
                        result.success(null)
                    }
                    "ingestUrl" -> result.success(DashcamKeyStore.ingestUrl(this))
                    "setIngestUrl" -> {
                        DashcamKeyStore.setIngestUrl(this, call.argument<String>("url") ?: "")
                        result.success(null)
                    }
                    // Opening a watch page in the browser rather than taking a
                    // dependency for one intent.
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrEmpty()) {
                            result.error("badArgument", "url is required", null)
                        } else {
                            startActivity(
                                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success(null)
                        }
                    }
                    "start" -> startDashcam(call.arguments, result)
                    "stop" -> {
                        DashcamService.stop(this)
                        result.success(null)
                    }
                    "state" -> result.success(
                        DashcamBridge.service?.currentState()?.toMap()
                            ?: DashcamBridge.latest
                            ?: DashcamState().toMap()
                    )
                    // The rest act on the live recorder, so they are direct calls
                    // rather than intents: same process, and they can return a
                    // value where an intent cannot.
                    "setMuted" -> withService(result) {
                        it.setMuted(call.argument<Boolean>("muted") == true)
                    }
                    "setStreamEnabled" -> withService(result) {
                        it.setStreamEnabled(call.argument<Boolean>("enabled") == true)
                    }
                    "setVideoBitrate" -> withService(result) {
                        it.setVideoBitrate(call.argument<Int>("bitrate") ?: 0)
                    }
                    "splitBroadcast" -> withService(result) { it.splitBroadcast() }
                    // The file operations are context-only on purpose: clips are
                    // browsed while parked, which is exactly when no recording
                    // service exists to ask.
                    "segments" -> result.success(
                        SegmentStore.list(this, DashcamBridge.service?.currentSegmentPath())
                    )
                    "exportSegments" -> result.success(
                        SegmentStore.export(
                            this,
                            call.argument<List<String>>("paths") ?: emptyList()
                        )
                    )
                    "purgeSegments" -> result.success(
                        SegmentStore.purge(this, DashcamBridge.service?.currentSegmentPath())
                    )
                    "storage" -> result.success(SegmentStore.storage(this))
                    else -> result.notImplemented()
                }
            }
    }

    private fun withService(
        result: MethodChannel.Result,
        action: (DashcamService) -> Any?
    ) {
        val service = DashcamBridge.service
        if (service == null) {
            result.error("notRunning", "The dashcam is not recording", null)
            return
        }
        result.success(action(service))
    }

    private fun startDashcam(arguments: Any?, result: MethodChannel.Result) {
        if (!DashcamPermissions.isSupported(this)) {
            result.error("cameraUnavailable", "This device has no camera", null)
            return
        }
        if (!DashcamPermissions.ready(this)) {
            result.error(
                "permissionDenied",
                "Camera and microphone are required",
                mapOf("missing" to DashcamPermissions.missing(this))
            )
            return
        }
        if (!visible) {
            result.error(
                "notVisible",
                "A camera foreground service cannot be started from the background",
                null
            )
            return
        }
        if (DashcamBridge.service != null) {
            result.error("alreadyRunning", "The dashcam is already recording", null)
            return
        }
        val args = arguments as? Map<*, *>
        if ((args?.get("ingestUrl") as? String).isNullOrEmpty()) {
            result.error("badArgument", "ingestUrl is required", mapOf("field" to "ingestUrl"))
            return
        }
        val bundle = DashcamConfig.toBundle(args)
        if (!bundle.containsKey("rotation")) bundle.putInt("rotation", cameraRotation())
        DashcamService.start(this, bundle)
        // Setup is asynchronous, so this is the starting snapshot only. The
        // session id and buffer directory arrive on the event channel once the
        // service has opened them.
        result.success(DashcamState(phase = Phase.STARTING).toMap())
    }

    override fun onResume() {
        super.onResume()
        visible = true
    }

    override fun onPause() {
        visible = false
        super.onPause()
    }

    /**
     * The camera's rotation for the current display orientation.
     *
     * Computed here and passed down rather than read inside the service:
     * `CameraHelper.getCameraOrientation` uses the deprecated
     * `getDefaultDisplay()`, which is wrong to call from a non-visual context.
     * The HUD locks landscapeLeft, so in practice this is 0 — reading it anyway
     * means a future landscapeRight does not produce upside-down video.
     */
    private fun cameraRotation(): Int = when (display?.rotation ?: Surface.ROTATION_90) {
        Surface.ROTATION_0 -> 90
        Surface.ROTATION_90 -> 0
        Surface.ROTATION_180 -> 270
        Surface.ROTATION_270 -> 180
        else -> 0
    }

    private fun requestDashcamPermissions(result: MethodChannel.Result) {
        val needed = DashcamPermissions.missing(this)
        if (needed.isEmpty()) {
            result.success(DashcamPermissions.snapshot(this))
            return
        }
        if (pendingPermissionResult != null) {
            result.error("alreadyRunning", "A permission request is already in flight", null)
            return
        }
        pendingPermissionResult = result
        // Captured before asking: still-denied with the rationale now gone is how
        // "Don't allow" twice is distinguished from a plain refusal.
        rationaleBefore = needed.associateWith { shouldShowRequestPermissionRationale(it) }
        ActivityCompat.requestPermissions(
            this,
            needed.toTypedArray(),
            dashcamPermissionRequest
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        // FlutterActivity's own override forwards to the plugin delegate and does
        // not call super itself, so this call is what keeps geolocator's location
        // permission flow working.
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != dashcamPermissionRequest) return

        val answer = DashcamPermissions.snapshot(this).toMutableMap()
        permissions.forEachIndexed { index, permission ->
            val granted = grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED
            val permanent = !granted &&
                rationaleBefore[permission] == true &&
                !shouldShowRequestPermissionRationale(permission)
            when (permission) {
                android.Manifest.permission.CAMERA ->
                    answer["cameraPermanentlyDenied"] = permanent
                android.Manifest.permission.RECORD_AUDIO ->
                    answer["microphonePermanentlyDenied"] = permanent
            }
        }
        pendingPermissionResult?.success(answer)
        pendingPermissionResult = null
        rationaleBefore = emptyMap()
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

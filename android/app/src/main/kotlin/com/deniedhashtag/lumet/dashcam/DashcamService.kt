package com.deniedhashtag.lumet.dashcam

import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.MediaRecorder
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.ServiceCompat
import com.pedro.common.AudioCodec
import com.pedro.common.ConnectChecker
import com.pedro.common.VideoCodec
import com.pedro.encoder.input.sources.audio.MicrophoneSource
import com.pedro.encoder.input.sources.video.Camera2Source
import com.pedro.encoder.input.video.CameraCallbacks
import com.pedro.encoder.input.video.CameraHelper
import com.pedro.library.rtmp.RtmpStream
import kotlin.math.abs
import kotlin.math.min

/**
 * Owns the capture pipeline for as long as a drive lasts.
 *
 * A foreground service rather than plain activity-scoped work for two reasons:
 * the camera must keep running when the HUD is backgrounded or the screen locks,
 * and the process must not be killed mid-drive. Note that the service type buys
 * continued camera access but NOT a running CPU — [acquireWakeLock] is what keeps
 * the encode and socket loops alive once the display goes off.
 *
 * It is only ever started from [com.deniedhashtag.lumet.MainActivity] while the
 * app is visible, because a camera-type foreground service cannot legally be
 * started from the background.
 */
class DashcamService : Service(), ConnectChecker {

    companion object {
        const val ACTION_START = "com.deniedhashtag.lumet.dashcam.START"
        const val ACTION_STOP = "com.deniedhashtag.lumet.dashcam.STOP"
        const val EXTRA_CONFIG = "config"

        /** Below this the picture is not worth keeping. */
        private const val MIN_BITRATE = 800_000

        private const val MAX_BITRATE = 12_000_000

        /** Send cache this full means the uplink cannot keep up. */
        private const val CONGESTION_PERCENT = 20f

        /**
         * Long enough to be past YouTube's reconnect grace window, so the old
         * broadcast definitely ends rather than silently resuming.
         */
        private const val SPLIT_GAP_MS = 60_000L

        /**
         * YouTube archives a stream of up to twelve hours; past that the archive
         * may not be captured at all. This is the one case where splitting beats
         * not splitting, because the alternative is losing the lot.
         */
        private const val ARCHIVE_GUARD_MS = 11 * 60 * 60 * 1000L + 45 * 60 * 1000L

        fun start(context: Context, config: android.os.Bundle) {
            val intent = Intent(context, DashcamService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_CONFIG, config)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, DashcamService::class.java).setAction(ACTION_STOP)
            )
        }
    }

    private lateinit var config: DashcamConfig
    private var stream: RtmpStream? = null
    private var camera: Camera2Source? = null
    private var microphone: MicrophoneSource? = null
    private var segments: SegmentStore? = null
    private var governor: ThermalGovernor? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var running = false
    private var retries = 0

    private val worker = HandlerThread("dashcam").apply { start() }
    private val work = Handler(worker.looper)
    private val main = Handler(Looper.getMainLooper())

    private var state = DashcamState()
    private var lastNotifiedAt = 0L

    private val archiveGuard: Runnable = Runnable {
        if (running && stream?.isStreaming == true) {
            splitBroadcast()
            publish(
                state.copy(
                    warning = DashcamState.error(
                        "archiveLimitSplit",
                        "Approaching YouTube's 12 hour archive limit; starting a new broadcast"
                    )
                )
            )
            work.postDelayed(archiveGuard, ARCHIVE_GUARD_MS)
        }
    }

    private val heartbeat = object : Runnable {
        override fun run() {
            if (!running) return
            publish(state)
            main.postDelayed(this, 1_000)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * START_NOT_STICKY is deliberate: a system-initiated restart after a process
     * kill would be a background start of a camera service, which throws.
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> shutdown(null)

            ACTION_START -> {
                if (running) return START_NOT_STICKY // idempotent
                val bundle = intent.getBundleExtra(EXTRA_CONFIG)
                if (bundle == null) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                config = DashcamConfig.fromBundle(bundle)
                running = true

                // Order matters. The notification has to be posted within five
                // seconds of onStartCommand, and posting it is the moment the
                // camera foreground-service grant is latched in — so it comes
                // before any camera or encoder work.
                DashcamNotification.ensureChannel(this)
                state = DashcamState(
                    phase = Phase.STARTING,
                    muted = config.muted,
                    resolution = config.resolution,
                    fps = config.fps,
                    videoBitrate = config.videoBitrate,
                    bufferMinutes = config.bufferMinutes,
                )
                ServiceCompat.startForeground(
                    this,
                    DashcamNotification.NOTIFICATION_ID,
                    DashcamNotification.build(this, state),
                    foregroundTypeMask()
                )
                acquireWakeLock()
                DashcamBridge.attach(this)
                publish(state)
                main.postDelayed(heartbeat, 1_000)
                work.postDelayed(archiveGuard, ARCHIVE_GUARD_MS)

                work.post { bringUp() }
            }
        }
        return START_NOT_STICKY
    }

    /**
     * Both types are declared in the manifest but the mask is computed here:
     * passing MICROPHONE without RECORD_AUDIO granted throws SecurityException.
     */
    private fun foregroundTypeMask(): Int {
        var mask = ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        if (DashcamPermissions.hasMicrophone(this)) {
            mask = mask or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        return mask
    }

    /**
     * Opens the camera, encoders and upload. Runs on [work], never on the main
     * thread.
     *
     * One encode feeds two sinks. There is no preview anywhere: `startPreview` is
     * opt-in, and without it the GL interface sets up an offscreen EGL pbuffer
     * context, so no window or View is involved.
     */
    private fun bringUp() {
        val videoSource = Camera2Source(this).apply {
            setCameraCallback(object : CameraCallbacks {
                override fun onCameraError(error: String) = fail("cameraError", error)
                override fun onCameraDisconnected() = fail("cameraDisconnected", null)
                override fun onCameraOpened() = Unit
                override fun onCameraChanged(facing: CameraHelper.Facing) = Unit
            })
        }
        // CAMCORDER is tuned for loud environments and applies less aggressive
        // gain control than MIC.
        val audioSource = MicrophoneSource(MediaRecorder.AudioSource.CAMCORDER)

        val rtmp = RtmpStream(this, this, videoSource, audioSource)
        // H264 and AAC are not negotiable here: the MP4 muxer rejects VP8/VP9 and
        // YouTube wants H264 regardless.
        rtmp.setVideoCodec(VideoCodec.H264)
        rtmp.setAudioCodec(AudioCodec.AAC)
        // Starting the GL interface spins up a sensor rotation manager by default.
        // Sensor noise must never reorient a dashcam feed, and the HUD is locked
        // to one orientation anyway.
        rtmp.getGlInterface().autoHandleOrientation = false

        val videoReady = rtmp.prepareVideo(
            width = config.width,
            height = config.height,
            bitrate = config.videoBitrate,
            fps = config.fps,
            iFrameInterval = config.iFrameInterval,
            rotation = config.rotation,
        )
        val audioReady = rtmp.prepareAudio(
            sampleRate = config.sampleRate,
            isStereo = config.stereo,
            bitrate = config.audioBitrate,
            // Road and engine noise is the evidence, not interference.
            echoCanceler = false,
            noiseSuppressor = false,
        )
        if (!videoReady || !audioReady) {
            fail("encoderFailed", "prepareVideo=$videoReady prepareAudio=$audioReady")
            return
        }

        rtmp.getStreamClient().apply {
            // With logs on, the client prints the connect URL — which contains the
            // stream key.
            setLogs(false)
            setReTries(Int.MAX_VALUE)
            // A mobile uplink readily produces a half-open socket where writes
            // succeed into a buffer that never drains.
            setCheckServerAlive(true)
            setBitrateExponentialFactor(0.5f)
        }

        stream = rtmp
        camera = videoSource
        microphone = audioSource

        videoSource.applyStabilization(config.videoStabilization)
        if (config.muted) audioSource.mute()

        // Recording starts before streaming on purpose: the local buffer is the
        // insurance, so it must be capturing even if the upload never connects.
        if (config.recordEnabled) {
            val store = SegmentStore(this, config, work)
            if (!store.begin(rtmp, ::publishStorage) { code, message -> fail(code, message) }) {
                fail("storageUnavailable", "External storage is not available")
                return
            }
            segments = store
        }

        if (config.canStream) {
            rtmp.startStream(config.ingestEndpoint())
        }

        governor = ThermalGovernor(this, rtmp, config, work).also { g ->
            g.start(
                onChange = { bitrate, throttled ->
                    publish(
                        state.copy(
                            videoBitrate = bitrate,
                            thermalThrottled = throttled,
                            thermalStatus = g.currentStatus(),
                        )
                    )
                },
                // Local recording costs no modem and no TLS, and it is the copy
                // that actually preserves the evidence.
                onEmergency = {
                    setStreamEnabled(false)
                    publish(
                        state.copy(
                            warning = DashcamState.error(
                                "thermalCritical",
                                "Upload stopped to let the device cool; still recording locally"
                            )
                        )
                    )
                },
            )
        }

        publish(
            state.copy(
                phase = Phase.ACTIVE,
                thermalStatus = governor?.currentStatus() ?: 0,
                streaming = rtmp.isStreaming,
                recording = rtmp.isRecording,
                muted = audioSource.isMuted(),
                sessionId = segments?.sessionId,
                dir = segments?.directory,
                segmentPath = segments?.currentPath(),
                segmentCount = segments?.segmentCount() ?: 0,
                bufferBytes = segments?.bufferBytes() ?: 0,
                freeBytes = segments?.freeBytes() ?: 0,
                lowStorage = segments?.lowStorage() ?: false,
            )
        )
    }

    /** Called on every segment rotation and prune. */
    private fun publishStorage() {
        val store = segments ?: return
        publish(
            state.copy(
                recording = stream?.isRecording == true,
                segmentPath = store.currentPath(),
                segmentCount = store.segmentCount(),
                bufferBytes = store.bufferBytes(),
                freeBytes = store.freeBytes(),
                lowStorage = store.lowStorage(),
            )
        )
    }

    /**
     * Best effort, and user-triggered only.
     *
     * With a persistent stream key the only move available is to stop the ingest
     * and start it again, and that is exactly the operation whose outcome YouTube
     * does not guarantee: reconnect quickly and the same broadcast resumes,
     * reconnect slowly and the old one ends but the new ingest may go nowhere
     * until the Studio page is reloaded. Local recording continues throughout, so
     * the gap is covered either way. Doing this reliably needs the Live Streaming
     * API, which means OAuth.
     */
    fun splitBroadcast(): Boolean {
        val rtmp = stream ?: return false
        if (!config.canStream) return false
        if (rtmp.isStreaming) rtmp.stopStream()
        publish(state.copy(streaming = false, connection = Connection.DISCONNECTED))
        work.postDelayed({
            if (running) {
                retries = 0
                rtmp.startStream(config.ingestEndpoint())
            }
        }, SPLIT_GAP_MS)
        return true
    }

    /** The file still being written, so a listing can mark it incomplete. */
    fun currentSegmentPath(): String? = segments?.currentPath()

    /**
     * Optical stabilization, never digital. EIS crops the frame, adds latency and
     * burns power, and dash vibration is high-frequency enough that OIS handles it.
     */
    private fun Camera2Source.applyStabilization(mode: String) {
        when (mode) {
            "optical" -> enableOpticalVideoStabilization()
            "digital" -> enableVideoStabilization()
            else -> {
                disableOpticalVideoStabilization()
                disableVideoStabilization()
            }
        }
        // The road sits at a varying distance and the light changes constantly.
        enableAutoFocus()
        enableAutoExposure()
    }

    /** Mid-drive mute. Zeroes the PCM buffer, so the AAC track stays continuous. */
    fun setMuted(muted: Boolean): Boolean {
        val source = microphone ?: return state.muted
        if (muted) source.mute() else source.unMute()
        publish(state.copy(muted = source.isMuted()))
        return source.isMuted()
    }

    /** Stops or starts the upload without touching the local recording. */
    fun setStreamEnabled(enabled: Boolean): Boolean {
        val rtmp = stream ?: return false
        if (enabled && !rtmp.isStreaming && config.canStream) {
            retries = 0
            rtmp.startStream(config.ingestEndpoint())
        } else if (!enabled && rtmp.isStreaming) {
            rtmp.stopStream()
        }
        publish(state.copy(streaming = rtmp.isStreaming))
        return rtmp.isStreaming
    }

    /** Live MediaCodec parameter change: no encoder restart, no stream break. */
    fun setVideoBitrate(bitrate: Int): Int {
        val clamped = bitrate.coerceIn(MIN_BITRATE, MAX_BITRATE)
        stream?.setVideoBitrateOnFly(clamped)
        publish(state.copy(videoBitrate = clamped))
        return clamped
    }

    /** Releases the pipeline, then the service. Safe to call more than once. */
    fun shutdown(error: Map<String, Any?>?) {
        if (!running) {
            stopSelf()
            return
        }
        running = false
        main.removeCallbacks(heartbeat)
        work.removeCallbacks(archiveGuard)
        publish(state.copy(phase = Phase.STOPPING))

        work.post {
            governor?.stop()
            governor = null
            // Finalises the segment being written before the encoders go away.
            segments?.end()
            segments = null
            // release() covers stopStream, stopRecord and stopSources.
            stream?.release()
            stream = null
            camera = null
            microphone = null
            main.post {
                releaseWakeLock()
                state = DashcamState(phase = Phase.IDLE, error = error)
                DashcamBridge.emit(state.toMap())
                DashcamBridge.detach()
                ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
    }

    fun fail(code: String, message: String?) {
        shutdown(DashcamState.error(code, message))
    }

    fun currentState(): DashcamState = state

    /**
     * A foreground service does not keep the CPU awake, and wakelock_plus only
     * holds the screen on while the activity is resumed. Without this, capture
     * stalls as soon as the display turns off.
     */
    private fun acquireWakeLock() {
        if (wakeLock != null) return
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "lumet:dashcam")
            .apply {
                setReferenceCounted(false)
                // No timeout: the lifetime is bounded by the service itself.
                acquire()
            }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    /** Emits to Dart and refreshes the notification, at most once a second. */
    fun publish(next: DashcamState) {
        state = next
        DashcamBridge.emit(next.toMap())

        val now = System.currentTimeMillis()
        if (next.phase == Phase.IDLE || now - lastNotifiedAt < 1_000) return
        lastNotifiedAt = now
        getSystemService(NotificationManager::class.java)
            .notify(DashcamNotification.NOTIFICATION_ID, DashcamNotification.build(this, next))
    }

    // --- ConnectChecker. A dead upload never stops the local recording; that is
    // --- the entire reason the rolling buffer exists.

    override fun onConnectionStarted(url: String) {
        // The URL contains the stream key, so only the host is ever surfaced.
        val host = runCatching { Uri.parse(url).host }.getOrNull()
        publish(state.copy(connection = Connection.CONNECTING, ingestHost = host))
    }

    override fun onConnectionSuccess() {
        retries = 0
        // The library decrements its retry counter on every reconnect and never
        // replenishes it, so without this the stream quietly stops retrying after
        // a few hours of flaky signal.
        stream?.getStreamClient()?.setReTries(Int.MAX_VALUE)
        publish(
            state.copy(
                connection = Connection.CONNECTED,
                streaming = true,
                retryCount = 0,
                nextRetryInMs = null,
                error = null,
            )
        )
    }

    override fun onConnectionFailed(reason: String) {
        // A malformed endpoint is a bad URL or key, not a network blip. Retrying
        // it forever would hide the real problem.
        if (reason.contains("Endpoint malformed", ignoreCase = true)) {
            publish(
                state.copy(
                    connection = Connection.FAILED,
                    streaming = false,
                    error = DashcamState.error(
                        "connectionFailed",
                        "Bad ingest URL or stream key"
                    ),
                )
            )
            return
        }

        retries++
        if (config.maxRetries > 0 && retries > config.maxRetries) {
            publish(
                state.copy(
                    connection = Connection.FAILED,
                    streaming = false,
                    error = DashcamState.error("connectionFailed", reason),
                )
            )
            return
        }

        // Capped deliberately low. YouTube's reconnect grace window is short, and
        // a long backoff lands outside it, which ends the broadcast rather than
        // resuming it.
        val delay = min(
            config.retryBaseMs shl min(retries - 1, 4),
            config.retryMaxMs
        )
        publish(
            state.copy(
                connection = Connection.RECONNECTING,
                retryCount = retries,
                nextRetryInMs = delay,
            )
        )
        if (stream?.getStreamClient()?.reTry(delay, reason) != true) {
            publish(
                state.copy(
                    connection = Connection.FAILED,
                    streaming = false,
                    error = DashcamState.error("connectionFailed", reason),
                )
            )
        }
    }

    override fun onDisconnect() {
        publish(state.copy(connection = Connection.DISCONNECTED, streaming = false))
    }

    override fun onAuthError() {
        publish(
            state.copy(
                connection = Connection.FAILED,
                streaming = false,
                error = DashcamState.error("authError", "Stream key rejected"),
            )
        )
    }

    /** YouTube's RTMPS ingest does not use RTMP authentication. */
    override fun onAuthSuccess() = Unit

    override fun onNewBitrate(bitrate: Long) {
        val congested = stream?.getStreamClient()?.hasCongestion(CONGESTION_PERCENT) == true
        publish(state.copy(uplinkBitrate = bitrate, congested = congested))
    }

    override fun onDestroy() {
        running = false
        main.removeCallbacks(heartbeat)
        releaseWakeLock()
        DashcamBridge.detach()
        worker.quitSafely()
        super.onDestroy()
    }
}

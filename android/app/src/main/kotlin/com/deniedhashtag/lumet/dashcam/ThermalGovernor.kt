package com.deniedhashtag.lumet.dashcam

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.PowerManager
import com.pedro.library.rtmp.RtmpStream
import kotlin.math.abs

/**
 * Trims the video bitrate when the device gets hot or the uplink falls behind.
 *
 * Worth being honest about the scale: on a phone on a sunny dashboard the encoder
 * is around 0.2 W while the HUD's own screen at full brightness is 2-3 W, so this
 * is the smaller of the two levers. The larger one belongs to Dart, which is why
 * the thermal status is published rather than only acted on here.
 *
 * Changes go through `setVideoBitrateOnFly`, a live MediaCodec parameter change —
 * no encoder restart, no stream interruption, no segment boundary.
 */
class ThermalGovernor(
    context: Context,
    private val stream: RtmpStream,
    private val config: DashcamConfig,
    private val work: Handler,
) {

    private val power = context.getSystemService(PowerManager::class.java)

    /** Multipliers on the configured bitrate, indexed by THERMAL_STATUS_*. */
    private val ladder = floatArrayOf(
        1.00f, // NONE
        1.00f, // LIGHT
        0.70f, // MODERATE
        0.45f, // SEVERE
        0.30f, // CRITICAL
        0.30f, // EMERGENCY  - also drops the upload entirely
        0.30f, // SHUTDOWN
    )

    private var applied = config.videoBitrate
    private var started = false

    private var onChange: ((Int, Boolean) -> Unit)? = null

    /** Stop streaming and keep recording, which is far cheaper than both. */
    private var onEmergency: (() -> Unit)? = null

    private val listener =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            PowerManager.OnThermalStatusChangedListener { status -> work.post { apply(status) } }
        } else {
            null
        }

    private val poll = object : Runnable {
        override fun run() {
            if (!started) return
            apply(currentStatus())
            work.postDelayed(this, POLL_MS)
        }
    }

    fun start(onChange: (bitrate: Int, throttled: Boolean) -> Unit, onEmergency: () -> Unit) {
        if (started) return
        started = true
        this.onChange = onChange
        this.onEmergency = onEmergency
        listener?.let { power.addThermalStatusListener(it) }
        apply(currentStatus())
        work.postDelayed(poll, POLL_MS)
    }

    fun stop() {
        started = false
        work.removeCallbacks(poll)
        listener?.let { runCatching { power.removeThermalStatusListener(it) } }
        onChange = null
        onEmergency = null
    }

    fun currentStatus(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) power.currentThermalStatus else 0

    private fun apply(status: Int) {
        if (!config.autoBitrate) return
        var target = (config.videoBitrate * ladder[status.coerceIn(0, 6)]).toInt()

        // The uplink's own verdict, independent of temperature.
        if (stream.getStreamClient().hasCongestion(CONGESTION_PERCENT)) {
            target = (target * CONGESTION_FACTOR).toInt()
        }
        val clamped = target.coerceAtLeast(MIN_BITRATE)

        // Hysteresis, so the bitrate does not oscillate around a threshold.
        if (abs(clamped - applied) > HYSTERESIS) {
            applied = clamped
            stream.setVideoBitrateOnFly(clamped)
            onChange?.invoke(clamped, clamped < config.videoBitrate)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            status >= PowerManager.THERMAL_STATUS_EMERGENCY
        ) {
            onEmergency?.invoke()
        }
    }

    private companion object {
        const val POLL_MS = 5_000L
        const val MIN_BITRATE = 800_000
        const val HYSTERESIS = 200_000
        const val CONGESTION_PERCENT = 20f
        const val CONGESTION_FACTOR = 0.75f
    }
}

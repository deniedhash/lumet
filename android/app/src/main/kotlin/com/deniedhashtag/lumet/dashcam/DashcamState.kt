package com.deniedhashtag.lumet.dashcam

/** Where the pipeline is as a whole. Orthogonal to [Connection]. */
enum class Phase {
    IDLE, STARTING, ACTIVE, STOPPING, ERROR;

    val wire: String get() = name.lowercase()
}

/** Where the RTMPS upload is. A dead upload never implies a dead recording. */
enum class Connection {
    DISCONNECTED, CONNECTING, CONNECTED, RECONNECTING, FAILED;

    val wire: String get() = name.lowercase()
}

/**
 * One snapshot of the recorder, as sent to Dart.
 *
 * The fields are deliberately orthogonal rather than collapsed into a single
 * enum: "writing an MP4 but not uploading" is a real and important state, and
 * flattening it here would lose it. Dart derives the flat phase it shows from
 * [phase], [connection], [recording] and [streaming].
 *
 * Carries no stream key, and must never gain one — this is the map that crosses
 * the channel and the thing that gets logged.
 */
data class DashcamState(
    val phase: Phase = Phase.IDLE,
    val recording: Boolean = false,
    val streaming: Boolean = false,
    val connection: Connection = Connection.DISCONNECTED,
    val muted: Boolean = false,
    val startedAtMs: Long? = null,
    /** Host only. The full ingest URL contains the key. */
    val ingestHost: String? = null,
    val videoBitrate: Int = 0,
    val uplinkBitrate: Long = 0,
    val droppedVideoFrames: Long = 0,
    val droppedAudioFrames: Long = 0,
    val congested: Boolean = false,
    val resolution: String? = null,
    val fps: Int = 0,
    val sessionId: String? = null,
    val dir: String? = null,
    val segmentCount: Int = 0,
    val segmentPath: String? = null,
    val bufferBytes: Long = 0,
    val bufferMinutes: Int = 0,
    val freeBytes: Long = 0,
    val lowStorage: Boolean = false,
    /** PowerManager.THERMAL_STATUS_*, 0..6. */
    val thermalStatus: Int = 0,
    val thermalThrottled: Boolean = false,
    val retryCount: Int = 0,
    val nextRetryInMs: Long? = null,
    val error: Map<String, Any?>? = null,
    val warning: Map<String, Any?>? = null,
) {

    val elapsedMs: Long
        get() = startedAtMs?.let { System.currentTimeMillis() - it } ?: 0L

    fun toMap(): Map<String, Any?> = mapOf(
        "phase" to phase.wire,
        "recording" to recording,
        "streaming" to streaming,
        "connection" to connection.wire,
        "muted" to muted,
        "startedAtMs" to startedAtMs,
        "elapsedMs" to elapsedMs,
        "ingestHost" to ingestHost,
        "videoBitrate" to videoBitrate,
        "uplinkBitrate" to uplinkBitrate,
        "droppedVideoFrames" to droppedVideoFrames,
        "droppedAudioFrames" to droppedAudioFrames,
        "congested" to congested,
        "resolution" to resolution,
        "fps" to fps,
        "sessionId" to sessionId,
        "dir" to dir,
        "segmentCount" to segmentCount,
        "segmentPath" to segmentPath,
        "bufferBytes" to bufferBytes,
        "bufferMinutes" to bufferMinutes,
        "freeBytes" to freeBytes,
        "lowStorage" to lowStorage,
        "thermalStatus" to thermalStatus,
        "thermalThrottled" to thermalThrottled,
        "retryCount" to retryCount,
        "nextRetryInMs" to nextRetryInMs,
        "error" to error,
        "warning" to warning,
    )

    /** Second line of the notification. */
    fun summaryLine(): String {
        val parts = mutableListOf<String>()
        resolution?.let { parts.add(if (fps > 0) "$it@$fps" else it) }
        if (streaming && uplinkBitrate > 0) {
            parts.add(String.format("%.1f Mbps", uplinkBitrate / 1_000_000.0))
        } else if (recording && !streaming) {
            parts.add("local only")
        }
        if (segmentCount > 0) parts.add("$segmentCount min buffered")
        if (muted) parts.add("muted")
        if (lowStorage) parts.add("storage low")
        return parts.joinToString("  ·  ")
    }

    companion object {
        fun error(code: String, message: String?): Map<String, Any?> =
            mapOf("code" to code, "message" to message)
    }
}

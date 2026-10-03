package com.deniedhashtag.lumet.dashcam

import android.os.Bundle

/**
 * Everything the recorder needs for one session, as handed down from Dart.
 *
 * The ingest URL and the stream key stay separate all the way down so that no
 * single string in a log line, an error message or a state map ever holds both.
 * Nothing here is persisted: the config arrives with every start and dies with
 * the service, which is what keeps "move the key to a backend later" a Dart-only
 * change.
 */
data class DashcamConfig(
    val ingestUrl: String,
    val streamKey: String,
    val width: Int,
    val height: Int,
    val fps: Int,
    val videoBitrate: Int,
    val iFrameInterval: Int,
    val rotation: Int,
    val audioEnabled: Boolean,
    val muted: Boolean,
    val sampleRate: Int,
    val stereo: Boolean,
    val audioBitrate: Int,
    val recordEnabled: Boolean,
    val bufferMinutes: Int,
    val segmentSeconds: Int,
    val maxBufferBytes: Long,
    val minFreeBytes: Long,
    val streamEnabled: Boolean,
    val autoBitrate: Boolean,
    val maxRetries: Int,
    val retryBaseMs: Long,
    val retryMaxMs: Long,
    val videoStabilization: String,
) {

    /** An empty key means record locally and never attempt an upload. */
    val canStream: Boolean get() = streamEnabled && streamKey.isNotEmpty()

    val resolution: String get() = "${width}x$height"

    /** The only place the two halves are joined. Never log the result. */
    fun ingestEndpoint(): String = "${ingestUrl.trimEnd('/')}/$streamKey"

    companion object {

        /** Unknown keys are ignored and absent keys take these defaults. */
        fun fromBundle(b: Bundle): DashcamConfig = DashcamConfig(
            ingestUrl = b.getString("ingestUrl", ""),
            streamKey = b.getString("streamKey", ""),
            width = b.getInt("width", 1280),
            height = b.getInt("height", 720),
            fps = b.getInt("fps", 30),
            // 720p30. YouTube's recommended band is 3-8 Mbps; this sits below it
            // to hold mobile data down, and is the first knob to raise if number
            // plates turn out illegible.
            videoBitrate = b.getInt("videoBitrate", 2_500_000),
            // YouTube requires <= 4s and recommends 2. Also bounds how much of a
            // segment is lost to an abrupt process death.
            iFrameInterval = b.getInt("iFrameInterval", 2),
            rotation = b.getInt("rotation", 0),
            audioEnabled = b.getBoolean("audioEnabled", true),
            muted = b.getBoolean("muted", false),
            sampleRate = b.getInt("sampleRate", 44_100),
            stereo = b.getBoolean("stereo", true),
            audioBitrate = b.getInt("audioBitrate", 128_000),
            recordEnabled = b.getBoolean("recordEnabled", true),
            bufferMinutes = b.getInt("bufferMinutes", 15),
            segmentSeconds = b.getInt("segmentSeconds", 60),
            maxBufferBytes = b.getLong("maxBufferBytes", 2L * 1024 * 1024 * 1024),
            minFreeBytes = b.getLong("minFreeBytes", 500L * 1024 * 1024),
            streamEnabled = b.getBoolean("streamEnabled", true),
            autoBitrate = b.getBoolean("autoBitrate", true),
            maxRetries = b.getInt("maxRetries", 0),
            retryBaseMs = b.getLong("retryBaseMs", 2_000),
            // Capped low on purpose: YouTube's reconnect grace window is short,
            // and a long backoff guarantees landing outside it and losing the
            // broadcast rather than resuming it.
            retryMaxMs = b.getLong("retryMaxMs", 10_000),
            videoStabilization = b.getString("videoStabilization", "optical"),
        )

        /** Builds the Bundle the activity puts in the start intent. */
        fun toBundle(args: Map<*, *>): Bundle = Bundle().apply {
            fun str(key: String) = (args[key] as? String)?.let { putString(key, it) }
            fun int(key: String) = (args[key] as? Number)?.let { putInt(key, it.toInt()) }
            fun long(key: String) = (args[key] as? Number)?.let { putLong(key, it.toLong()) }
            fun bool(key: String) = (args[key] as? Boolean)?.let { putBoolean(key, it) }

            str("ingestUrl"); str("streamKey"); str("videoStabilization")
            int("width"); int("height"); int("fps"); int("videoBitrate")
            int("iFrameInterval"); int("rotation"); int("sampleRate")
            int("audioBitrate"); int("bufferMinutes"); int("segmentSeconds")
            int("maxRetries")
            long("maxBufferBytes"); long("minFreeBytes")
            long("retryBaseMs"); long("retryMaxMs")
            bool("audioEnabled"); bool("muted"); bool("stereo")
            bool("recordEnabled"); bool("streamEnabled"); bool("autoBitrate")
        }
    }
}

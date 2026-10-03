package com.deniedhashtag.lumet.dashcam

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.StatFs
import android.provider.MediaStore
import com.pedro.library.base.recording.RecordController
import com.pedro.library.rtmp.RtmpStream
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.ceil

/**
 * The local rolling buffer: a ring of short MP4 segments written from the same
 * encode that feeds the upload, so a signal dropout does not mean lost footage.
 *
 * Segment rotation provably cannot disturb the stream. While streaming,
 * `stopRecord()` returns without calling `stopSources()` or resetting the track
 * formats, so the camera, GL context, encoders and socket are all untouched; the
 * record controller clears its timestamp base so the next file starts at PTS 0;
 * and the muxer holds frames until a keyframe arrives, requesting one if needed.
 * With a 2-second keyframe interval the join is sub-frame.
 */
class SegmentStore(
    private val context: Context,
    private val config: DashcamConfig,
    private val work: Handler,
) {

    /**
     * App-private external storage: no storage permission at any API level,
     * scoped-storage clean, and removed on uninstall. The Files app cannot browse
     * it since Android 11, which is what [export] is for.
     */
    private val dir: File? get() = directory(context)

    private val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).apply {
        // UTC so the session stem is DST-proof, and so Dart and Kotlin agree.
        timeZone = TimeZone.getTimeZone("UTC")
    }

    /** One more than the window needs, so the file being written is never the one pruned. */
    private val keep: Int
        get() = ceil(config.bufferMinutes * 60.0 / config.segmentSeconds).toInt() + 1

    lateinit var sessionId: String
        private set

    val directory: String? get() = dir?.absolutePath

    private var stream: RtmpStream? = null
    private var index = 0
    private var current: File? = null
    private var onChange: (() -> Unit)? = null
    private var active = false

    private val listener = object : RecordController.Listener {
        override fun onStatusChange(status: RecordController.Status) = Unit
        override fun onError(e: Exception?) {
            onFail?.invoke("recordError", e?.message)
        }
    }

    private var onFail: ((String, String?) -> Unit)? = null

    private val rotateTick = object : Runnable {
        override fun run() {
            if (!active) return
            rotate()
            work.postDelayed(this, config.segmentSeconds * 1000L)
        }
    }

    /** Returns false when external storage is unavailable. */
    fun begin(
        rtmp: RtmpStream,
        onChange: () -> Unit,
        onFail: (String, String?) -> Unit,
    ): Boolean {
        val target = dir ?: return false
        if (!target.exists() && !target.mkdirs()) return false

        this.stream = rtmp
        this.onChange = onChange
        this.onFail = onFail
        sessionId = stamp.format(Date())
        active = true

        reapOrphans()
        rotate()
        work.postDelayed(rotateTick, config.segmentSeconds * 1000L)
        return true
    }

    fun end() {
        active = false
        work.removeCallbacks(rotateTick)
        stream?.let { if (it.isRecording) it.stopRecord() }
        current = null
        stream = null
    }

    /** Closes the current segment, prunes, and opens the next one. */
    private fun rotate() {
        val rtmp = stream ?: return
        val target = dir ?: return
        if (rtmp.isRecording) rtmp.stopRecord()
        prune()

        if (lowStorage()) {
            // Streaming is the primary store, so give up the buffer rather than
            // the upload, and leave the user's own files alone.
            current = null
            onChange?.invoke()
            return
        }

        val next = File(target, "lumet_$sessionId-${index.toString().padStart(4, '0')}.mp4")
        index++
        rtmp.startRecord(next.absolutePath, RecordController.RecordTracks.ALL, listener)
        current = next
        onChange?.invoke()
    }

    /**
     * Three independent guards. The first two are self-limiting by construction;
     * the third is the one that matters, because the user's own photos filling the
     * volume is not something we control.
     */
    private fun prune() {
        val files = segmentFiles().toMutableList()

        // 1. The retention window, expressed as a segment count.
        while (files.size > keep) files.removeAt(0).delete()

        // 2. A byte ceiling, in case a bitrate spike outruns the count estimate.
        var total = files.sumOf { it.length() }
        while (files.size > 1 && total > config.maxBufferBytes) {
            val oldest = files.removeAt(0)
            total -= oldest.length()
            oldest.delete()
        }

        // 3. A free-space floor on the volume as a whole.
        if (freeBytes() < config.minFreeBytes) {
            while (files.size > 1 && freeBytes() < config.minFreeBytes) {
                files.removeAt(0).delete()
            }
        }
    }

    /**
     * A file that was mid-write when the process died has no moov atom and is
     * unplayable. Delete rather than attempt a repair.
     */
    private fun reapOrphans() {
        segmentFiles().forEach { if (it.length() == 0L) it.delete() }
    }

    private fun segmentFiles(): List<File> = files(context)

    fun freeBytes(): Long = freeBytes(context)

    fun bufferBytes(): Long = bufferBytes(context)

    fun segmentCount(): Int = segmentFiles().size

    fun currentPath(): String? = current?.absolutePath

    fun lowStorage(): Boolean = freeBytes() < config.minFreeBytes

    companion object {

        /**
         * App-private external storage: no storage permission at any API level,
         * scoped-storage clean, and removed on uninstall.
         *
         * These are deliberately context-only rather than methods on a live
         * recorder. Browsing clips is something you do parked, which is exactly
         * when no recording service exists.
         */
        fun directory(context: Context): File? =
            context.getExternalFilesDir(Environment.DIRECTORY_MOVIES)
                ?.let { File(it, "dashcam") }

        fun files(context: Context): List<File> =
            directory(context)
                ?.listFiles { f -> f.isFile && f.name.startsWith("lumet_") && f.extension == "mp4" }
                ?.sortedBy { it.name }
                ?: emptyList()

        fun freeBytes(context: Context): Long = directory(context)
            ?.let { runCatching { StatFs(it.path).availableBytes }.getOrDefault(0L) }
            ?: 0L

        fun bufferBytes(context: Context): Long = files(context).sumOf { it.length() }

        /** [current] marks the file still being written, when one is. */
        fun list(context: Context, current: String?): List<Map<String, Any?>> =
            files(context).map {
                mapOf(
                    "path" to it.absolutePath,
                    "name" to it.name,
                    "bytes" to it.length(),
                    "modifiedAtMs" to it.lastModified(),
                    "complete" to (it.absolutePath != current),
                )
            }

        fun storage(context: Context): Map<String, Any?> = mapOf(
            "dir" to directory(context)?.absolutePath,
            "bufferBytes" to bufferBytes(context),
            "freeBytes" to freeBytes(context),
            "segmentCount" to files(context).size,
        )

        fun purge(context: Context, current: String?): Int {
            var deleted = 0
            files(context).forEach {
                if (it.absolutePath != current && it.delete()) deleted++
            }
            return deleted
        }

        /**
         * Copies segments into the shared video collection so they are reachable
         * from Gallery and Files. Inserting your own media needs no permission on
         * API 29+.
         */
        fun export(context: Context, paths: List<String>): List<String> {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return emptyList()
            val dir = directory(context) ?: return emptyList()
            val resolver = context.contentResolver
            val exported = mutableListOf<String>()

            paths.forEach { path ->
                val file = File(path)
                if (!file.isFile || file.parentFile?.absolutePath != dir.absolutePath) {
                    return@forEach
                }
                val values = ContentValues().apply {
                    put(MediaStore.Video.Media.DISPLAY_NAME, file.name)
                    put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                    put(
                        MediaStore.Video.Media.RELATIVE_PATH,
                        "${Environment.DIRECTORY_MOVIES}/Lumet"
                    )
                    put(MediaStore.Video.Media.IS_PENDING, 1)
                }
                val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
                    ?: return@forEach
                runCatching {
                    resolver.openOutputStream(uri)?.use { out ->
                        file.inputStream().use { it.copyTo(out) }
                    }
                }.onFailure {
                    resolver.delete(uri, null, null)
                    return@forEach
                }
                resolver.update(
                    uri,
                    ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) },
                    null,
                    null
                )
                exported.add(uri.toString())
            }
            return exported
        }
    }
}

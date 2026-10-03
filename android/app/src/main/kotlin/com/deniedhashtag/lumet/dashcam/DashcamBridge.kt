package com.deniedhashtag.lumet.dashcam

import android.os.Handler
import android.os.Looper

/**
 * Bridge between [DashcamService] and the Flutter engine.
 *
 * Same idiom as `NavListener`: a companion sink the activity installs while the
 * engine is attached, plus the last emitted value so a late-attaching engine is
 * not left blank. The service outlives the engine — swiping the HUD away kills
 * the engine and leaves the recording running — so it can never hold an
 * EventSink directly.
 *
 * Unlike `NavListener`, [latest] is retained even for the idle state: the HUD
 * needs to know "not recording" on a cold start.
 */
object DashcamBridge {

    /** Installed by MainActivity while the engine is attached. */
    var sink: ((Map<String, Any?>) -> Unit)? = null

    var latest: Map<String, Any?>? = null
        private set

    /** Set while the service is alive, for commands that need a direct call. */
    @Volatile
    var service: DashcamService? = null
        private set

    private val main = Handler(Looper.getMainLooper())

    fun emit(data: Map<String, Any?>) {
        latest = data
        main.post { sink?.invoke(data) }
    }

    fun attach(instance: DashcamService) {
        service = instance
    }

    fun detach() {
        service = null
    }
}

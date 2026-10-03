package com.deniedhashtag.lumet.dashcam

import android.content.Context

/**
 * Persists the YouTube stream key in app-private preferences.
 *
 * Native rather than a Dart package for the same reason the buffer directory is:
 * the platform already owns storage here, and it keeps the Dart side free of
 * dependencies. A build-time `--dart-define` still works as a fallback, so a key
 * can be baked in without ever opening the editor.
 *
 * This is a credential. It is app-private, which puts it on a par with a password
 * saved by any other app — safe from other apps, readable with root or a debug
 * backup. Nothing here logs it, and nothing returns it to anywhere but the editor.
 * If it leaks, reset the key in YouTube Studio; that invalidates the old one.
 */
object DashcamKeyStore {

    private const val PREFS = "lumet.dashcam"
    private const val KEY = "stream_key"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun get(context: Context): String? =
        prefs(context).getString(KEY, null)?.takeIf { it.isNotBlank() }

    fun set(context: Context, key: String) {
        val trimmed = key.trim()
        prefs(context).edit().apply {
            if (trimmed.isEmpty()) remove(KEY) else putString(KEY, trimmed)
        }.apply()
    }

    fun clear(context: Context) {
        prefs(context).edit().remove(KEY).apply()
    }
}

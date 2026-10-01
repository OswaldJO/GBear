package com.example.companion_app

import android.content.Context
import android.os.SystemClock
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale

/**
 * The host Mac's video bitrate, for the stream's corner readout. Remote co-op gets it in the
 * relay's once-a-second `ping`; LAN streams ask `/gbear/v1/status`.
 */
object GBearHostBitrate {
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val SHOW_KEY = "flutter.stream.showHostBitrate"
    private const val STALE_MS = 4_000L

    @Volatile private var measured = 0
    @Volatile private var target = 0
    @Volatile private var receivedAtMs = 0L

    fun isEnabled(context: Context): Boolean =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getBoolean(SHOW_KEY, true)

    fun note(measuredBps: Int, targetBps: Int) {
        measured = measuredBps
        target = targetBps
        receivedAtMs = SystemClock.elapsedRealtime()
    }

    /** Picks the bitrate out of a relay ping or a status reply; ignores messages without one. */
    fun noteFrom(json: JSONObject) {
        if (!json.has("bitrate")) return
        note(json.optInt("bitrate"), json.optInt("targetBitrate"))
    }

    fun clear() {
        receivedAtMs = 0L
    }

    /** Null when nothing recent arrived (older host, or the stream stalled). */
    fun label(): String? {
        if (receivedAtMs == 0L || SystemClock.elapsedRealtime() - receivedAtMs > STALE_MS) return null
        val now = String.format(Locale.US, "%.1f", measured / 1_000_000.0)
        if (target <= 0) return "Host $now Mbit/s"
        return "Host $now / ${String.format(Locale.US, "%.1f", target / 1_000_000.0)} Mbit/s"
    }

    /** Blocking; call off the main thread. */
    fun pollStatus(host: String, controlPort: Int = 28765) {
        try {
            val connection = URL("http://$host:$controlPort/gbear/v1/status").openConnection() as HttpURLConnection
            connection.connectTimeout = 2_000
            connection.readTimeout = 2_000
            val body = connection.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
            connection.disconnect()
            noteFrom(JSONObject(body))
        } catch (_: Exception) {
        }
    }
}

package com.example.companion_app

import android.content.Context
import android.os.Build
import android.util.Log
import java.io.BufferedWriter
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Writes GBear video/stream diagnostics to app-private storage for user export.
 */
object GBearStreamLog {
    private const val TAG = "GBearVideo"
    private const val FILE_NAME = "gbear_stream.log"

    private val lock = Any()
    private var writer: BufferedWriter? = null

    fun startSession(
        context: Context,
        host: String,
        port: Int,
        width: Int,
        height: Int,
    ) {
        synchronized(lock) {
            closeWriterLocked()
            val file = logFile(context)
            writer = BufferedWriter(FileWriter(file, false))
            i("=== GBear stream log started ===")
            i("device=${Build.MANUFACTURER} ${Build.MODEL} api=${Build.VERSION.SDK_INT}")
            i("target=$host:$port ${width}x$height")
            i(
                "Logs include: video/audio, Swap on/off, Gamepad map … → GBK1, Keyboard GBK1 up/down, unmapped gamepad keys",
            )
        }
    }

    fun i(message: String) = write("I", message)

    fun w(message: String) = write("W", message)

    fun e(message: String, throwable: Throwable? = null) {
        if (throwable != null) {
            write("E", "$message (${throwable.javaClass.simpleName}: ${throwable.message})")
            write("E", Log.getStackTraceString(throwable))
        } else {
            write("E", message)
        }
    }

    fun endSession(reason: String) {
        synchronized(lock) {
            writeLocked("I", "=== GBear stream log ended: $reason ===")
            closeWriterLocked()
        }
    }

    fun logFilePath(context: Context): String? {
        val file = logFile(context)
        return if (file.exists() && file.length() > 0L) file.absolutePath else null
    }

    private fun write(level: String, message: String) {
        when (level) {
            "W" -> Log.w(TAG, message)
            "E" -> Log.e(TAG, message)
            else -> Log.i(TAG, message)
        }
        synchronized(lock) {
            writeLocked(level, message)
        }
    }

    private fun writeLocked(level: String, message: String) {
        val w = writer ?: return
        try {
            w.write("${timestamp()} [$level] $message")
            w.newLine()
            w.flush()
        } catch (ex: Exception) {
            Log.e(TAG, "Failed writing stream log", ex)
        }
    }

    private fun closeWriterLocked() {
        try {
            writer?.flush()
            writer?.close()
        } catch (_: Exception) {
        } finally {
            writer = null
        }
    }

    private fun logFile(context: Context): File =
        File(context.filesDir, FILE_NAME)

    private fun timestamp(): String =
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date())
}

package com.example.companion_app

import java.net.HttpURLConnection
import java.net.URL

/** Minimal HTTP client for GBear stream control plane (port 28765). */
object GBearHostControlClient {
    private const val DEFAULT_CONTROL_PORT = 28765

    /** Blocks until the Mac acknowledges stream stop (or times out). */
    fun stopStreamOnHost(host: String, controlPort: Int = DEFAULT_CONTROL_PORT) {
        if (host.isEmpty()) return
        try {
            val url = URL("http://$host:$controlPort/gbear/v1/stream/stop")
            val connection = url.openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.connectTimeout = 20_000
            connection.readTimeout = 20_000
            connection.connect()
            connection.inputStream.use { }
            connection.disconnect()
        } catch (_: Exception) {
        }
    }
}

package com.example.companion_app

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.util.Collections
import java.util.concurrent.Executors

/** Sends `GBK1` keyboard events to the Mac input port (native stream). */
class GBearKeyboardSender(
    private val host: String,
    private val port: Int,
) {
    private val socket = DatagramSocket()
    private val executor = Executors.newSingleThreadExecutor()
    private val keysHeld = Collections.synchronizedSet(mutableSetOf<Int>())

    fun sendKey(moonlightKeyCode: Int, down: Boolean) {
        val payload = GBearStreamProtocols.buildKeyboardPacket(moonlightKeyCode, down)
        executor.execute {
            try {
                socket.send(
                    DatagramPacket(
                        payload,
                        payload.size,
                        InetSocketAddress(host, port),
                    ),
                )
                synchronized(keysHeld) {
                    if (down) {
                        keysHeld.add(moonlightKeyCode)
                    } else {
                        keysHeld.remove(moonlightKeyCode)
                    }
                }
                if (packetsLogged < 64) {
                    packetsLogged++
                    GBearStreamLog.i(
                        "Keyboard GBK1 ${if (down) "down" else "up"} " +
                            "key=0x${moonlightKeyCode.toString(16)} → $host:$port " +
                            "(swap=${GBearStreamSession.swapMouseModeActive})",
                    )
                }
            } catch (e: Exception) {
                GBearStreamLog.w("Keyboard send failed key=0x${moonlightKeyCode.toString(16)}: ${e.message}")
            }
        }
    }

    fun sendChord(moonlightKeyCodes: List<Int>, down: Boolean) {
        if (moonlightKeyCodes.isEmpty()) return
        val order = if (down) moonlightKeyCodes else moonlightKeyCodes.asReversed()
        for (code in order) {
            sendKey(code, down)
        }
    }

    /** Sends key-up for anything still marked down (e.g. after Swap toggle). */
    fun releaseAllKeys() {
        val pending = synchronized(keysHeld) { keysHeld.toList() }
        if (pending.isEmpty()) return
        executor.execute {
            for (code in pending.reversed()) {
                try {
                    val payload = GBearStreamProtocols.buildKeyboardPacket(code, down = false)
                    socket.send(
                        DatagramPacket(
                            payload,
                            payload.size,
                            InetSocketAddress(host, port),
                        ),
                    )
                    if (packetsLogged < 64) {
                        packetsLogged++
                        GBearStreamLog.i(
                            "Keyboard GBK1 up key=0x${code.toString(16)} → $host:$port (releaseAll)",
                        )
                    }
                } catch (e: Exception) {
                    GBearStreamLog.w(
                        "Keyboard release failed key=0x${code.toString(16)}: ${e.message}",
                    )
                }
            }
            synchronized(keysHeld) { keysHeld.clear() }
        }
    }

    @Volatile
    private var packetsLogged = 0

    fun close() {
        releaseAllKeys()
        executor.shutdown()
        runCatching { socket.close() }
    }
}

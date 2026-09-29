package com.example.companion_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Remote co-op through a host Mac's invite relay (`GBEAR1` line).
 *
 * The relay carries the same `GBV1` / `GBA1` / `GBG1` packets as the LAN ports, wrapped in `GBTL`
 * frames on one WebSocket. This bridge serves them on loopback ports so [GBearVideoActivity],
 * [GBearAudioReceiver], and the input senders run unchanged against [LOOPBACK_HOST].
 */
object GBearRelayBridge {
    const val LOOPBACK_HOST = "127.0.0.1"

    private const val MAGIC = 0x4C544247
    private const val CHANNEL_CONTROL = 1
    private const val CHANNEL_VIDEO = 2
    private const val CHANNEL_AUDIO = 3
    private const val CHANNEL_INPUT = 4
    private const val MAX_RECONNECTS = 8
    private const val JOIN_TIMEOUT_MS = 45_000L

    sealed class JoinResult {
        data class Joined(val seat: Int) : JoinResult()
        data class Failed(val message: String) : JoinResult()
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()

    @Volatile var active = false
        private set

    private var appContext: Context? = null
    private var client: OkHttpClient? = null
    @Volatile private var socket: WebSocket? = null
    private var relayUrl = ""
    private var deviceId = ""
    private var deviceName = ""
    private var preferredSeat = 0
    @Volatile private var epoch = 0
    private var reconnectAttempts = 0
    private var joinCallback: ((JoinResult) -> Unit)? = null
    private var joinTimeout: Runnable? = null

    private var video: LoopbackStream? = null
    private var audio: LoopbackStream? = null
    private var input: DatagramSocket? = null
    private var inputThread: Thread? = null

    val videoPort: Int get() = video?.port ?: 0
    val audioTcpPort: Int get() = audio?.port ?: 0
    val inputPort: Int get() = input?.localPort ?: 0

    fun handlesHost(host: String): Boolean = active && host == LOOPBACK_HOST

    /** Opens loopback ports, joins the relay, and reports the seat from the host's `welcome`. */
    fun start(
        context: Context,
        url: String,
        deviceId: String,
        deviceName: String,
        preferredSeat: Int,
        onResult: (JoinResult) -> Unit,
    ) {
        stop("new join")
        synchronized(lock) {
            appContext = context.applicationContext
            relayUrl = url
            this.deviceId = deviceId
            this.deviceName = deviceName
            this.preferredSeat = preferredSeat
            reconnectAttempts = 0
            joinCallback = onResult
            try {
                video = LoopbackStream("GBearRelayVideo", capacity = 30, dependentFrames = true) {
                    sendHello()
                }
                audio = LoopbackStream("GBearRelayAudio", capacity = 60, dependentFrames = false)
                input = DatagramSocket(InetSocketAddress(InetAddress.getLoopbackAddress(), 0))
            } catch (e: Exception) {
                closeLocalPorts()
                joinCallback = null
                onResult(JoinResult.Failed("Could not open local stream ports: ${e.message}"))
                return
            }
            client = OkHttpClient.Builder()
                .connectTimeout(15, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.MILLISECONDS)
                .pingInterval(15, TimeUnit.SECONDS)
                .build()
            active = true
            startInputPump()
            val timeout = Runnable {
                finishJoin(JoinResult.Failed("The host did not answer. Make sure remote co-op is still running on the Mac."))
                stop("join timed out")
            }
            joinTimeout = timeout
            mainHandler.postDelayed(timeout, JOIN_TIMEOUT_MS)
            connectLocked()
        }
        GBearStreamLog.i("Relay bridge ports video=$videoPort audio=$audioTcpPort input=$inputPort")
    }

    fun stop(reason: String) {
        val wasActive: Boolean
        synchronized(lock) {
            wasActive = active
            active = false
            epoch += 1
            joinTimeout?.let { mainHandler.removeCallbacks(it) }
            joinTimeout = null
            joinCallback = null
            socket?.close(1000, "guest left")
            socket = null
            client?.dispatcher?.executorService?.shutdown()
            client = null
            closeLocalPorts()
        }
        if (wasActive) GBearStreamLog.i("Relay bridge stopped ($reason)")
    }

    private fun closeLocalPorts() {
        video?.close()
        video = null
        audio?.close()
        audio = null
        input?.close()
        input = null
        inputThread = null
    }

    private fun connectLocked() {
        val http = client ?: return
        val current = ++epoch
        val request = Request.Builder().url(relayUrl).build()
        socket = http.newWebSocket(request, object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                if (current != epoch) return
                handleBinary(webSocket, bytes)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                if (current != epoch) return
                handleText(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
                handleDrop(current, "closed ($code)")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                handleDrop(current, "closed ($code)")
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                handleDrop(current, t.message ?: t.javaClass.simpleName)
            }
        })
    }

    private fun handleText(text: String) {
        val type = runCatching { JSONObject(text).optString("type") }.getOrNull() ?: return
        when (type) {
            "relay_ready" -> {
                GBearStreamLog.i("Relay ready; saying hello")
                sendHello()
            }
            "peer_left" -> GBearStreamLog.w("Relay: host blipped; waiting for it to reconnect")
        }
    }

    private fun handleBinary(webSocket: WebSocket, bytes: ByteString) {
        val data = bytes.toByteArray()
        if (data.size < 9) return
        val header = ByteBuffer.wrap(data, 0, 9).order(ByteOrder.LITTLE_ENDIAN)
        if (header.int != MAGIC) return
        val channel = header.get().toInt() and 0xFF
        val length = header.int
        if (length < 0 || 9 + length > data.size) return
        when (channel) {
            CHANNEL_VIDEO -> {
                val keyframe = length > 8 && (data[9 + 8].toInt() and 1) != 0
                video?.enqueue(data.copyOfRange(9, 9 + length), keyframe)
            }
            CHANNEL_AUDIO -> {
                val framed = ByteBuffer.allocate(4 + length).order(ByteOrder.LITTLE_ENDIAN)
                framed.putInt(length)
                framed.put(data, 9, length)
                audio?.enqueue(framed.array(), keyframe = false)
            }
            CHANNEL_CONTROL -> handleControl(webSocket, String(data, 9, length, Charsets.UTF_8))
        }
    }

    private fun handleControl(webSocket: WebSocket, text: String) {
        val json = runCatching { JSONObject(text) }.getOrNull() ?: return
        when (json.optString("type")) {
            // Answered on the socket thread so the host's round trip measures the network, not this phone.
            "ping" -> {
                val pong = JSONObject().put("type", "pong").put("t", json.opt("t"))
                webSocket.send(frame(CHANNEL_CONTROL, pong.toString().toByteArray()))
            }
            "welcome" -> {
                val seat = json.optInt("seat", 2).coerceIn(1, 8)
                synchronized(lock) { reconnectAttempts = 0 }
                GBearStreamLog.i("Relay welcome: Player $seat")
                finishJoin(JoinResult.Joined(seat))
            }
            "error" -> {
                val message = json.optString("error").ifEmpty { "The host rejected the join." }
                GBearStreamLog.w("Relay error: $message")
                finishJoin(JoinResult.Failed(message))
                stop("host error")
            }
        }
    }

    private fun handleDrop(dropEpoch: Int, reason: String) {
        synchronized(lock) {
            if (!active || dropEpoch != epoch) return
            socket = null
            val retryEpoch = ++epoch
            reconnectAttempts += 1
            if (reconnectAttempts > MAX_RECONNECTS || joinCallback != null && reconnectAttempts > 2) {
                GBearStreamLog.w("Relay lost ($reason); giving up")
                mainHandler.post { endAfterRelayLoss(reason) }
                return
            }
            GBearStreamLog.w("Relay dropped ($reason); reconnect $reconnectAttempts/$MAX_RECONNECTS")
            val delayMs = 400L * reconnectAttempts
            mainHandler.postDelayed({
                synchronized(lock) {
                    if (active && retryEpoch == epoch) connectLocked()
                }
            }, delayMs)
        }
    }

    private fun endAfterRelayLoss(reason: String) {
        if (!active) return
        val pending = synchronized(lock) { joinCallback != null }
        if (pending) {
            finishJoin(JoinResult.Failed("Could not reach the host ($reason). Check the invite line and try again."))
            stop("relay unreachable")
            return
        }
        val context = appContext ?: run { stop("relay lost"); return }
        GBearStreamStopper.stopAll(context, "remote co-op relay lost ($reason)", recordPendingLogForResume = true)
        MainActivity.notifyFlutterStreamStoppedExternally()
    }

    private fun finishJoin(result: JoinResult) {
        val callback = synchronized(lock) {
            val cb = joinCallback
            joinCallback = null
            joinTimeout?.let { mainHandler.removeCallbacks(it) }
            joinTimeout = null
            cb
        } ?: return
        mainHandler.post { callback(result) }
    }

    /** Also sent when the player reconnects its video socket: the host answers with a fresh keyframe. */
    private fun sendHello() {
        val body = JSONObject()
            .put("type", "hello")
            .put("deviceId", deviceId)
            .put("deviceName", deviceName)
            .put("preferredSeat", preferredSeat)
        socket?.send(frame(CHANNEL_CONTROL, body.toString().toByteArray()))
    }

    private fun startInputPump() {
        val sock = input ?: return
        inputThread = Thread({
            val buffer = ByteArray(2048)
            val packet = DatagramPacket(buffer, buffer.size)
            while (active && !sock.isClosed) {
                try {
                    packet.length = buffer.size
                    sock.receive(packet)
                    socket?.send(frame(CHANNEL_INPUT, buffer.copyOfRange(0, packet.length)))
                } catch (_: Exception) {
                    if (sock.isClosed) break
                }
            }
        }, "GBearRelayInput").also { it.start() }
    }

    private fun frame(channel: Int, payload: ByteArray): ByteString {
        val buffer = ByteBuffer.allocate(9 + payload.size).order(ByteOrder.LITTLE_ENDIAN)
        buffer.putInt(MAGIC)
        buffer.put(channel.toByte())
        buffer.putInt(payload.size)
        buffer.put(payload)
        return buffer.array().toByteString()
    }

    /**
     * One loopback TCP port with a single reader. Writes happen on their own thread so a slow reader
     * never stalls the WebSocket (and with it the host's pings and controller acks).
     */
    private class LoopbackStream(
        name: String,
        capacity: Int,
        private val dependentFrames: Boolean,
        private val onClientConnected: () -> Unit = {},
    ) {
        private val server = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        private val queue = LinkedBlockingQueue<ByteArray>(capacity)
        @Volatile private var client: Socket? = null
        @Volatile private var output: OutputStream? = null
        @Volatile private var closed = false
        /** After a drop, H.264 frames reference the missing one, so skip until a keyframe. */
        @Volatile private var awaitingKeyframe = true

        val port: Int = server.localPort

        init {
            Thread({ acceptLoop() }, "$name-accept").start()
            Thread({ writeLoop() }, "$name-write").start()
        }

        fun enqueue(packet: ByteArray, keyframe: Boolean) {
            if (output == null) {
                awaitingKeyframe = true
                return
            }
            if (dependentFrames) {
                if (awaitingKeyframe && !keyframe) return
                if (keyframe) awaitingKeyframe = false
            }
            if (!queue.offer(packet)) {
                if (dependentFrames) {
                    queue.clear()
                    awaitingKeyframe = true
                }
            }
        }

        fun close() {
            closed = true
            runCatching { server.close() }
            runCatching { client?.close() }
            queue.clear()
            queue.offer(ByteArray(0))
        }

        private fun acceptLoop() {
            while (!closed) {
                val accepted = try {
                    server.accept()
                } catch (_: Exception) {
                    break
                }
                accepted.tcpNoDelay = true
                runCatching { client?.close() }
                queue.clear()
                awaitingKeyframe = true
                client = accepted
                output = accepted.getOutputStream()
                onClientConnected()
            }
        }

        private fun writeLoop() {
            while (!closed) {
                val packet = try {
                    queue.take()
                } catch (_: InterruptedException) {
                    break
                }
                if (packet.isEmpty()) continue
                val out = output ?: continue
                try {
                    out.write(packet)
                    out.flush()
                } catch (_: Exception) {
                    output = null
                    runCatching { client?.close() }
                    client = null
                }
            }
        }
    }
}

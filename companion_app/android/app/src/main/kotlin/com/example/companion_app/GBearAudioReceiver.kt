package com.example.companion_app

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Build
import java.io.InputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.PortUnreachableException
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Receives `GBA1` PCM from the Mac.
 * Prefers TCP (port 28769, length-prefixed frames); falls back to UDP after `GBAS` subscribe.
 */
class GBearAudioReceiver(
    private val host: String,
    private val udpPort: Int,
    private val tcpPort: Int,
) {
    private val running = AtomicBoolean(false)
    private var networkThread: Thread? = null
    private var playbackThread: Thread? = null
    private var socket: DatagramSocket? = null
    private var track: AudioTrack? = null
    private var trackRate = 0
    private var trackChannels = 0
    private var lockedSampleRate = false
    private val pcmQueue = LinkedBlockingQueue<ByteArray>(96)

    fun start() {
        if (!running.compareAndSet(false, true)) return
        playbackThread = Thread({ playbackLoop() }, "GBearAudioPlayback").also { it.start() }
        networkThread = Thread({
            if (!runTcpLoop()) {
                runUdpLoop()
            }
        }, "GBearAudioNetwork").also { it.start() }
    }

    private fun playbackLoop() {
        while (running.get() || pcmQueue.isNotEmpty()) {
            val chunk = pcmQueue.poll(50, TimeUnit.MILLISECONDS) ?: continue
            val local = track ?: continue
            var offset = 0
            while (offset < chunk.size) {
                val wrote = local.write(chunk, offset, chunk.size - offset)
                if (wrote <= 0) {
                    Thread.sleep(2)
                    continue
                }
                offset += wrote
            }
        }
    }

    private fun runTcpLoop(): Boolean {
        var tcpSocket: Socket? = null
        try {
            val sock = Socket()
            sock.connect(InetSocketAddress(host, tcpPort), 5_000)
            sock.soTimeout = 30_000
            tcpSocket = sock
            GBearStreamLog.i("Audio TCP connected to $host:$tcpPort")
            val input = sock.getInputStream()
            val lengthBuf = ByteArray(4)
            while (running.get()) {
                readFully(input, lengthBuf, 0, 4)
                val packetLen = ByteBuffer.wrap(lengthBuf).order(ByteOrder.LITTLE_ENDIAN).int
                if (packetLen <= 0 || packetLen > 256 * 1024) {
                    GBearStreamLog.w("Audio TCP bad frame length=$packetLen")
                    continue
                }
                val packet = ByteArray(packetLen)
                readFully(input, packet, 0, packetLen)
                if (!handleAudioPacket(packet)) continue
            }
            return true
        } catch (e: Exception) {
            if (running.get()) {
                GBearStreamLog.w(
                    "Audio TCP ended (${e.javaClass.simpleName}: ${e.message}); trying UDP",
                )
            }
            return false
        } finally {
            runCatching { tcpSocket?.close() }
        }
    }

    private fun runUdpLoop() {
        try {
            val sock = DatagramSocket(null)
            sock.reuseAddress = true
            sock.soTimeout = 3_000
            sock.bind(InetSocketAddress(0))
            socket = sock
            sendSubscribe(sock)

            val packet = DatagramPacket(ByteArray(64 * 1024), 64 * 1024)
            var lastSubscribeMs = System.currentTimeMillis()
            while (running.get()) {
                try {
                    packet.length = packet.data.size
                    sock.receive(packet)
                } catch (e: SocketTimeoutException) {
                    val now = System.currentTimeMillis()
                    if (now - lastSubscribeMs >= 2_000) {
                        sendSubscribe(sock)
                        lastSubscribeMs = now
                    }
                    continue
                } catch (e: PortUnreachableException) {
                    GBearStreamLog.w(
                        "Audio UDP port unreachable (retry subscribe): ${e.message}",
                    )
                    sendSubscribe(sock)
                    lastSubscribeMs = System.currentTimeMillis()
                    continue
                }
                if (packet.length < GBearStreamProtocols.AUDIO_HEADER_SIZE) continue
                val frame = packet.data.copyOfRange(0, packet.length)
                if (!handleAudioPacket(frame)) continue
            }
        } catch (e: Exception) {
            if (running.get()) {
                GBearStreamLog.e(
                    "Audio receiver ended: ${e.javaClass.simpleName}: ${e.message}",
                    e,
                )
            }
        } finally {
            runCatching { socket?.close() }
            socket = null
        }
    }

    private fun handleAudioPacket(packet: ByteArray): Boolean {
        if (packet.size < GBearStreamProtocols.AUDIO_HEADER_SIZE) return false
        val buf = ByteBuffer.wrap(packet).order(ByteOrder.LITTLE_ENDIAN)
        val magic = buf.int
        if (magic != GBearStreamProtocols.AUDIO_MAGIC) {
            GBearStreamLog.w("Audio ignored magic=0x${magic.toString(16)} len=${packet.size}")
            return false
        }
        val payloadLen = buf.int
        val sampleRate = buf.short.toInt() and 0xFFFF
        val channels = buf.get().toInt() and 0xFF
        if (payloadLen <= 0 || packet.size < GBearStreamProtocols.AUDIO_HEADER_SIZE + payloadLen) {
            return false
        }
        val pcm = packet.copyOfRange(
            GBearStreamProtocols.AUDIO_HEADER_SIZE,
            GBearStreamProtocols.AUDIO_HEADER_SIZE + payloadLen,
        )
        playPcm(pcm, sampleRate, channels)
        val count = audioPacketsHeard.incrementAndGet()
        if (count == 1 || count == 2 || count % 100 == 0) {
            GBearStreamLog.i("Audio packet #$count $payloadLen bytes (rate=$sampleRate ch=$channels)")
        }
        return true
    }

    private val audioPacketsHeard = java.util.concurrent.atomic.AtomicInteger(0)

    private fun sendSubscribe(sock: DatagramSocket) {
        val subscribe = GBearStreamProtocols.audioSubscribePacket()
        sock.send(
            DatagramPacket(
                subscribe,
                subscribe.size,
                InetSocketAddress(host, udpPort),
            ),
        )
        GBearStreamLog.i("Audio subscribed (UDP) to $host:$udpPort localPort=${sock.localPort}")
    }

    fun stop() {
        running.set(false)
        runCatching { socket?.close() }
        networkThread?.join(1_500)
        networkThread = null
        playbackThread?.join(1_500)
        playbackThread = null
        pcmQueue.clear()
        track?.stop()
        track?.release()
        track = null
        lockedSampleRate = false
    }

    private fun readFully(input: InputStream, buffer: ByteArray, offset: Int, length: Int) {
        var read = 0
        while (read < length) {
            val n = input.read(buffer, offset + read, length - read)
            if (n < 0) throw java.io.EOFException("Audio TCP stream closed")
            read += n
        }
    }

    private fun playPcm(pcm: ByteArray, sampleRate: Int, channels: Int) {
        val frameBytes = channels.coerceIn(1, 2) * 2
        if (pcm.size < frameBytes || pcm.size % frameBytes != 0) {
            GBearStreamLog.w("Audio skipped odd PCM size=${pcm.size} ch=$channels")
            return
        }
        val ch = if (channels == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        val rate = when {
            sampleRate in 8_000..96_000 -> sampleRate
            else -> 48_000
        }
        ensureAudioTrack(rate, ch, channels)
        if (!pcmQueue.offer(pcm)) {
            pcmQueue.poll()
            pcmQueue.offer(pcm)
        }
    }

    private fun ensureAudioTrack(rate: Int, ch: Int, channels: Int) {
        val needsNewTrack = track == null
            || (!lockedSampleRate && (trackRate != rate || trackChannels != channels))
        if (!needsNewTrack) return

        track?.release()
        val minBuf = AudioTrack.getMinBufferSize(
            rate,
            ch,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) {
            GBearStreamLog.w("AudioTrack min buffer size invalid: $minBuf")
            return
        }
        // ~100–200 ms of PCM; huge buffers cause underrun recovery failures on some devices.
        val frameBytes = channels.coerceIn(1, 2) * 2
        val bytesPerMs = rate * frameBytes / 1000
        val targetMs = 150
        val bufSize = (bytesPerMs * targetMs).coerceIn(minBuf * 2, minBuf * 8).coerceAtMost(65_536)

        val builder = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate)
                    .setChannelMask(ch)
                    .build(),
            )
            .setBufferSizeInBytes(bufSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        }
        val local = builder.build()
        local.play()
        track = local
        trackRate = rate
        trackChannels = channels
        lockedSampleRate = true
        GBearStreamLog.i("AudioTrack started ${rate}Hz ch=$channels buf=$bufSize (min=$minBuf)")
    }
}

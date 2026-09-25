package com.example.companion_app

import android.view.MotionEvent
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.util.concurrent.Executors
import kotlin.math.hypot

/**
 * Sends `GBI1` events to the Mac input port.
 *
 * - Move: relative deltas (cursor does not jump to the finger).
 * - Single-finger tap: left click at the current Mac cursor.
 * - Two-finger tap: right click at the current Mac cursor.
 * - Press, drag past slop, release: left-button drag (text selection).
 */
class GBearInputSender(
    private val host: String,
    private val port: Int,
    private val viewWidth: () -> Int,
    private val viewHeight: () -> Int,
    private val touchSlopPx: Float = 24f,
    private val cursorSensitivity: Float = 1f,
    private val tapTimeoutMs: Long = TAP_TIMEOUT_MS,
    private val minTapPressure: Float = 0.35f,
) {
    private val socket = DatagramSocket()
    private val executor = Executors.newSingleThreadExecutor()
    private var packetsSent = 0
    private var lastMoveSentMs = 0L
    @Volatile private var loggedSendFailure = false

    private var touchActive = false
    private var lastTouchX = 0f
    private var lastTouchY = 0f
    private var downX = 0f
    private var downY = 0f
    private var downTimeMs = 0L
    private var sentLeftDownForDrag = false
    private var twoFingerTapPending = false
    private var twoFingerDownTimeMs = 0L

    fun handleTouch(event: MotionEvent): Boolean {
        val w = viewWidth()
        val h = viewHeight()
        if (w <= 0 || h <= 0) return false

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                touchActive = true
                sentLeftDownForDrag = false
                twoFingerTapPending = false
                downX = event.x
                downY = event.y
                downTimeMs = System.currentTimeMillis()
                lastTouchX = event.x
                lastTouchY = event.y
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                if (event.pointerCount >= 2) {
                    twoFingerTapPending = true
                    twoFingerDownTimeMs = System.currentTimeMillis()
                    if (sentLeftDownForDrag) {
                        sendButton(type = 2, button = 0)
                        sentLeftDownForDrag = false
                    }
                }
            }

            MotionEvent.ACTION_MOVE -> {
                if (!touchActive) return true
                if (event.pointerCount >= 2) {
                    lastTouchX = event.getX(0)
                    lastTouchY = event.getY(0)
                    return true
                }

                val dx = event.x - lastTouchX
                val dy = event.y - lastTouchY
                lastTouchX = event.x
                lastTouchY = event.y
                sendRelativeMove(dx, dy, w, h)

                if (!sentLeftDownForDrag && !twoFingerTapPending) {
                    val dist = hypot((event.x - downX).toDouble(), (event.y - downY).toDouble())
                    if (dist > touchSlopPx) {
                        sendButton(type = 1, button = 0)
                        sentLeftDownForDrag = true
                    }
                }
            }

            MotionEvent.ACTION_POINTER_UP -> Unit

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (twoFingerTapPending) {
                    val elapsed = System.currentTimeMillis() - twoFingerDownTimeMs
                    if (elapsed < tapTimeoutMs && meetsTapPressure(event)) {
                        sendButton(type = 1, button = 1)
                        sendButton(type = 2, button = 1)
                    }
                    resetTouch()
                    return true
                }

                if (sentLeftDownForDrag) {
                    sendButton(type = 2, button = 0)
                } else if (touchActive && event.actionMasked != MotionEvent.ACTION_CANCEL) {
                    val elapsed = System.currentTimeMillis() - downTimeMs
                    val moved = hypot(
                        (event.x - downX).toDouble(),
                        (event.y - downY).toDouble(),
                    ) <= touchSlopPx
                    if (elapsed < tapTimeoutMs && moved && meetsTapPressure(event)) {
                        sendButton(type = 1, button = 0)
                        sendButton(type = 2, button = 0)
                    }
                }
                resetTouch()
            }
        }
        return true
    }

    private fun resetTouch() {
        touchActive = false
        sentLeftDownForDrag = false
        twoFingerTapPending = false
    }

    private fun sendRelativeMove(dx: Float, dy: Float, viewW: Int, viewH: Int) {
        if (dx == 0f && dy == 0f) return
        val now = System.currentTimeMillis()
        if (now - lastMoveSentMs < 16) return
        lastMoveSentMs = now

        val scale = cursorSensitivity.coerceIn(0.25f, 3f)
        val dxNorm = ((dx / viewW) * 32767f * scale).toInt().coerceIn(-32767, 32767)
        val dyNorm = ((dy / viewH) * 32767f * scale).toInt().coerceIn(-32767, 32767)
        val payload = GBearStreamProtocols.buildInputPacket(
            type = 0,
            button = 0,
            xNorm = dxNorm,
            yNorm = dyNorm,
        )
        executor.execute { sendPayload(payload, 0, dxNorm, dyNorm) }
    }

    /** [type] 1 = down, 2 = up; x/y omitted so Mac clicks at the current cursor. */
    private fun sendButton(type: Int, button: Int) {
        val payload = GBearStreamProtocols.buildInputPacket(
            type = type,
            button = button,
            xNorm = 0,
            yNorm = 0,
        )
        executor.execute { sendPayload(payload, type, 0, 0) }
    }

    private fun sendPayload(payload: ByteArray, type: Int, xNorm: Int, yNorm: Int) {
        try {
            socket.send(
                DatagramPacket(
                    payload,
                    payload.size,
                    InetSocketAddress(host, port),
                ),
            )
            packetsSent++
            if (packetsSent == 1 || packetsSent % 50 == 0) {
                GBearStreamLog.i("Input UDP #$packetsSent type=$type x=$xNorm y=$yNorm → $host:$port")
            }
            loggedSendFailure = false
        } catch (e: Exception) {
            if (!loggedSendFailure) {
                loggedSendFailure = true
                GBearStreamLog.w(
                    "Input send failed: ${e.javaClass.simpleName}: ${e.message}",
                )
            }
        }
    }

    private fun meetsTapPressure(event: MotionEvent): Boolean {
        val pressure = if (event.pointerCount > 0) event.getPressure(0) else event.pressure
        return pressure <= 0f || pressure >= minTapPressure.coerceIn(0.05f, 1f)
    }

    fun close() {
        executor.shutdownNow()
        runCatching { socket.close() }
    }

    companion object {
        const val TAP_TIMEOUT_MS = 400L
    }
}

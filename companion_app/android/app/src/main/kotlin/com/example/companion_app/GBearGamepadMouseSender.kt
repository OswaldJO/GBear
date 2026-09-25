package com.example.companion_app

import android.view.KeyEvent
import android.view.MotionEvent
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.util.concurrent.Executors
import kotlin.math.abs

/**
 * Notification **Swap** mode: left stick moves the Mac cursor; face buttons click / drag.
 * Xbox: A = left click, B = right click, X = hold + stick to drag. PlayStation: Cross / Circle / Square.
 */
class GBearGamepadMouseSender(
    private val host: String,
    private val port: Int,
    private var stickSensitivity: Float = 0.05f,
    private val stickDeadZone: Float = 0.12f,
) {
    /** Caps per-frame stick delta; touch uses small finger deltas, sticks report full [-1, 1]. */
    private val stickMoveGain = 0.38f
    private val socket = DatagramSocket()
    private val executor = Executors.newSingleThreadExecutor()
    private var lastMoveSentMs = 0L
    private var highlightDragHeld = false

    fun handleKeyEvent(event: KeyEvent): Boolean {
        when (event.keyCode) {
            KeyEvent.KEYCODE_BUTTON_A,
            KeyEvent.KEYCODE_DPAD_CENTER,
            -> {
                if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                    click(button = 0)
                }
                return true
            }
            KeyEvent.KEYCODE_BUTTON_B -> {
                if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                    click(button = 1)
                }
                return true
            }
            KeyEvent.KEYCODE_BUTTON_X -> {
                when (event.action) {
                    KeyEvent.ACTION_DOWN -> if (event.repeatCount == 0) {
                        highlightDragHeld = true
                        sendButton(type = 1, button = 0)
                    }
                    KeyEvent.ACTION_UP -> {
                        if (highlightDragHeld) {
                            sendButton(type = 2, button = 0)
                        }
                        highlightDragHeld = false
                    }
                }
                return true
            }
            else -> return false
        }
    }

    fun handleMotionEvent(event: MotionEvent): Boolean {
        val (rawX, rawY) = readLeftStickAxes(event)
        val stickX = applyStickDeadzone(rawX)
        val stickY = applyStickDeadzone(rawY)
        if (stickX == 0f && stickY == 0f) return true
        // AXIS_Y is negative when the stick is pushed up; Mac dy uses screen coords (down = +y).
        sendStickMove(stickX, stickY)
        return true
    }

    /** Release left button if Swap mode is turned off mid-drag. */
    fun releaseAll() {
        if (highlightDragHeld) {
            sendButton(type = 2, button = 0)
            highlightDragHeld = false
        }
    }

    private fun readLeftStickAxes(event: MotionEvent): Pair<Float, Float> {
        var x = event.getAxisValue(MotionEvent.AXIS_X)
        var y = event.getAxisValue(MotionEvent.AXIS_Y)
        if (abs(x) < 0.08f && abs(y) < 0.08f) {
            val zx = event.getAxisValue(MotionEvent.AXIS_Z)
            val zy = event.getAxisValue(MotionEvent.AXIS_RZ)
            if (abs(zx) > 0.12f || abs(zy) > 0.12f) {
                x = zx
                y = zy
            }
        }
        return x to y
    }

    private fun applyStickDeadzone(value: Float): Float {
        if (abs(value) < stickDeadZone) return 0f
        val sign = if (value > 0f) 1f else -1f
        val scaled = (abs(value) - stickDeadZone) / (1f - stickDeadZone)
        return sign * scaled.coerceIn(0f, 1f)
    }

    fun updateStickSensitivity(value: Float) {
        stickSensitivity = value.coerceIn(0.05f, 1f)
    }

    private fun sendStickMove(stickX: Float, stickY: Float) {
        val now = System.currentTimeMillis()
        if (now - lastMoveSentMs < 16) return
        lastMoveSentMs = now
        val scale = stickSensitivity.coerceIn(0.05f, 1f) * stickMoveGain
        val dxNorm = (stickX * 32767f * scale).toInt().coerceIn(-32767, 32767)
        val dyNorm = (stickY * 32767f * scale).toInt().coerceIn(-32767, 32767)
        val payload = GBearStreamProtocols.buildInputPacket(
            type = 0,
            button = 0,
            xNorm = dxNorm,
            yNorm = dyNorm,
        )
        executor.execute { sendPayload(payload) }
    }

    private fun click(button: Int) {
        sendButton(type = 1, button = button)
        sendButton(type = 2, button = button)
    }

    private fun sendButton(type: Int, button: Int) {
        val payload = GBearStreamProtocols.buildInputPacket(
            type = type,
            button = button,
            xNorm = 0,
            yNorm = 0,
        )
        executor.execute { sendPayload(payload) }
    }

    private fun sendPayload(payload: ByteArray) {
        try {
            socket.send(
                DatagramPacket(
                    payload,
                    payload.size,
                    InetSocketAddress(host, port),
                ),
            )
        } catch (_: Exception) {
        }
    }

    fun close() {
        releaseAll()
        executor.shutdownNow()
        runCatching { socket.close() }
    }
}

package com.example.companion_app

import android.util.Log
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs

/**
 * Sends structured [PlayniteStreamProtocols.GAMEPAD_MAGIC] (`PNG1`) state for co-op seats.
 * Used when co-op pad mode is enabled instead of keyboard-chord mapping.
 */
class PlayniteGamepadSender(
    private val host: String,
    private val port: Int,
    private val seat: Int,
) {
    private val socket = DatagramSocket()
    private val executor = Executors.newSingleThreadExecutor()
    private val closed = AtomicBoolean(false)
    private var buttons = 0
    private var leftX = 0f
    private var leftY = 0f
    private var rightX = 0f
    private var rightY = 0f
    private var leftTrigger = 0f
    private var rightTrigger = 0f

    fun handleKeyEvent(event: KeyEvent): Boolean {
        if (!isGamepad(event.device)) return false
        val bit = keyCodeToBit(event.keyCode) ?: return false
        val down = event.action == KeyEvent.ACTION_DOWN
        if (down) buttons = buttons or bit else buttons = buttons and bit.inv()
        flush()
        return true
    }

    fun handleMotion(event: MotionEvent): Boolean {
        if (!isGamepad(event.device)) return false
        leftX = axis(event, MotionEvent.AXIS_X)
        leftY = axis(event, MotionEvent.AXIS_Y)
        rightX = axis(event, MotionEvent.AXIS_Z)
        if (abs(rightX) < 0.01f) rightX = axis(event, MotionEvent.AXIS_RX)
        rightY = axis(event, MotionEvent.AXIS_RZ)
        if (abs(rightY) < 0.01f) rightY = axis(event, MotionEvent.AXIS_RY)
        leftTrigger = trigger(event, MotionEvent.AXIS_LTRIGGER, MotionEvent.AXIS_BRAKE)
        rightTrigger = trigger(event, MotionEvent.AXIS_RTRIGGER, MotionEvent.AXIS_GAS)

        val hatX = event.getAxisValue(MotionEvent.AXIS_HAT_X)
        val hatY = event.getAxisValue(MotionEvent.AXIS_HAT_Y)
        buttons = buttons and
            (PlayniteStreamProtocols.GamepadButtons.DPAD_UP or
                PlayniteStreamProtocols.GamepadButtons.DPAD_DOWN or
                PlayniteStreamProtocols.GamepadButtons.DPAD_LEFT or
                PlayniteStreamProtocols.GamepadButtons.DPAD_RIGHT).inv()
        if (hatY < -0.5f) buttons = buttons or PlayniteStreamProtocols.GamepadButtons.DPAD_UP
        if (hatY > 0.5f) buttons = buttons or PlayniteStreamProtocols.GamepadButtons.DPAD_DOWN
        if (hatX < -0.5f) buttons = buttons or PlayniteStreamProtocols.GamepadButtons.DPAD_LEFT
        if (hatX > 0.5f) buttons = buttons or PlayniteStreamProtocols.GamepadButtons.DPAD_RIGHT
        flush()
        return true
    }

    fun releaseAll() {
        buttons = 0
        leftX = 0f
        leftY = 0f
        rightX = 0f
        rightY = 0f
        leftTrigger = 0f
        rightTrigger = 0f
        flush()
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        releaseAll()
        executor.shutdownNow()
        runCatching { socket.close() }
    }

    private fun flush() {
        if (closed.get()) return
        val packet = PlayniteStreamProtocols.buildGamepadPacket(
            seat = seat,
            buttons = buttons,
            leftX = leftX,
            leftY = leftY,
            rightX = rightX,
            rightY = rightY,
            leftTrigger = leftTrigger,
            rightTrigger = rightTrigger,
        )
        executor.execute {
            try {
                val addr = InetAddress.getByName(host)
                socket.send(DatagramPacket(packet, packet.size, addr, port))
            } catch (e: Exception) {
                Log.w(TAG, "PNG1 send failed", e)
            }
        }
    }

    private fun axis(event: MotionEvent, axis: Int): Float {
        val v = event.getAxisValue(axis)
        return if (abs(v) < 0.12f) 0f else v.coerceIn(-1f, 1f)
    }

    private fun trigger(event: MotionEvent, primary: Int, fallback: Int): Float {
        var v = event.getAxisValue(primary)
        if (v <= 0f) v = event.getAxisValue(fallback)
        return v.coerceIn(0f, 1f)
    }

    private fun isGamepad(device: InputDevice?): Boolean {
        device ?: return false
        val sources = device.sources
        return sources and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD ||
            sources and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK
    }

    private fun keyCodeToBit(keyCode: Int): Int? = when (keyCode) {
        KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_DPAD_CENTER -> PlayniteStreamProtocols.GamepadButtons.A
        KeyEvent.KEYCODE_BUTTON_B -> PlayniteStreamProtocols.GamepadButtons.B
        KeyEvent.KEYCODE_BUTTON_X -> PlayniteStreamProtocols.GamepadButtons.X
        KeyEvent.KEYCODE_BUTTON_Y -> PlayniteStreamProtocols.GamepadButtons.Y
        KeyEvent.KEYCODE_BUTTON_L1 -> PlayniteStreamProtocols.GamepadButtons.L1
        KeyEvent.KEYCODE_BUTTON_R1 -> PlayniteStreamProtocols.GamepadButtons.R1
        KeyEvent.KEYCODE_BUTTON_THUMBL -> PlayniteStreamProtocols.GamepadButtons.L3
        KeyEvent.KEYCODE_BUTTON_THUMBR -> PlayniteStreamProtocols.GamepadButtons.R3
        KeyEvent.KEYCODE_BUTTON_START -> PlayniteStreamProtocols.GamepadButtons.START
        KeyEvent.KEYCODE_BUTTON_SELECT -> PlayniteStreamProtocols.GamepadButtons.SELECT
        KeyEvent.KEYCODE_BUTTON_MODE -> PlayniteStreamProtocols.GamepadButtons.GUIDE
        KeyEvent.KEYCODE_DPAD_UP -> PlayniteStreamProtocols.GamepadButtons.DPAD_UP
        KeyEvent.KEYCODE_DPAD_DOWN -> PlayniteStreamProtocols.GamepadButtons.DPAD_DOWN
        KeyEvent.KEYCODE_DPAD_LEFT -> PlayniteStreamProtocols.GamepadButtons.DPAD_LEFT
        KeyEvent.KEYCODE_DPAD_RIGHT -> PlayniteStreamProtocols.GamepadButtons.DPAD_RIGHT
        else -> null
    }

    companion object {
        private const val TAG = "PlayniteGamepadSender"
    }
}

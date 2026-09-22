package com.example.companion_app

import android.content.Context
import android.util.Log
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs

/**
 * Sends structured [PlayniteStreamProtocols.GAMEPAD_MAGIC] (`PNG1`) state for co-op seats.
 * Uses Eden-style auto-map (capability probe) plus per-control manual overrides.
 */
class PlayniteGamepadSender(
    private val host: String,
    private val port: Int,
    private val seat: Int,
    private val appContext: Context? = null,
    private val swapFaceButtons: Boolean = false,
    private val deadzone: Float = 0.12f,
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
    private val mappings = ConcurrentHashMap<String, PlayniteCoopPadMapping>()

    fun handleKeyEvent(event: KeyEvent): Boolean {
        if (!PlayniteGamepadAutoMapper.isPhysicalGameController(event.device)) return false
        val mapping = mappingFor(event.device) ?: return fallbackKey(event)
        val down = event.action == KeyEvent.ACTION_DOWN
        var handled = false
        for (binding in mapping.bindings) {
            if (binding.type != "key" || binding.keyCode != event.keyCode) continue
            val bit = logicalToBit(binding.logical) ?: continue
            buttons = if (down) buttons or bit else buttons and bit.inv()
            handled = true
        }
        if (handled) flush()
        return handled || GamepadInputFilter.isGamepadKey(event)
    }

    fun handleMotion(event: MotionEvent): Boolean {
        if (!PlayniteGamepadAutoMapper.isPhysicalGameController(event.device)) return false
        val mapping = mappingFor(event.device) ?: return fallbackMotion(event)
        buttons = buttons and
            (PlayniteStreamProtocols.GamepadButtons.DPAD_UP or
                PlayniteStreamProtocols.GamepadButtons.DPAD_DOWN or
                PlayniteStreamProtocols.GamepadButtons.DPAD_LEFT or
                PlayniteStreamProtocols.GamepadButtons.DPAD_RIGHT).inv()

        for (binding in mapping.bindings) {
            if (binding.type != "axis") continue
            val raw = event.getAxisValue(binding.axis)
            val value = if (binding.invert) -raw else raw
            when (binding.logical) {
                "leftStickX" -> leftX = deadzone(value)
                "leftStickY" -> leftY = deadzone(value)
                "rightStickX" -> rightX = deadzone(value)
                "rightStickY" -> rightY = deadzone(value)
                "leftTrigger" -> leftTrigger = triggerValue(raw, binding.invert)
                "rightTrigger" -> rightTrigger = triggerValue(raw, binding.invert)
                "dpadUp" -> if (value > 0.5f) buttons = buttons or PlayniteStreamProtocols.GamepadButtons.DPAD_UP
                "dpadDown" -> if (value > 0.5f) buttons = buttons or PlayniteStreamProtocols.GamepadButtons.DPAD_DOWN
                "dpadLeft" -> if (value > 0.5f) buttons = buttons or PlayniteStreamProtocols.GamepadButtons.DPAD_LEFT
                "dpadRight" -> if (value > 0.5f) buttons = buttons or PlayniteStreamProtocols.GamepadButtons.DPAD_RIGHT
            }
        }
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

    private fun mappingFor(device: InputDevice?): PlayniteCoopPadMapping? {
        device ?: return null
        val guid = PlayniteGamepadAutoMapper.guid(device)
        mappings[guid]?.let { return it }
        val context = appContext
        val mapped = if (context != null) {
            PlayniteCoopPadMappingStore.loadOrAutoMap(context, device, swapFaceButtons)
        } else {
            PlayniteGamepadAutoMapper.autoMap(device, swapFaceButtons)
        }
        mappings[guid] = mapped
        return mapped
    }

    private fun fallbackKey(event: KeyEvent): Boolean {
        val bit = keyCodeToBit(event.keyCode) ?: return false
        val down = event.action == KeyEvent.ACTION_DOWN
        buttons = if (down) buttons or bit else buttons and bit.inv()
        flush()
        return true
    }

    private fun fallbackMotion(event: MotionEvent): Boolean {
        leftX = deadzone(event.getAxisValue(MotionEvent.AXIS_X))
        leftY = deadzone(event.getAxisValue(MotionEvent.AXIS_Y))
        rightX = deadzone(event.getAxisValue(MotionEvent.AXIS_Z)).let {
            if (abs(it) < 0.01f) deadzone(event.getAxisValue(MotionEvent.AXIS_RX)) else it
        }
        rightY = deadzone(event.getAxisValue(MotionEvent.AXIS_RZ)).let {
            if (abs(it) < 0.01f) deadzone(event.getAxisValue(MotionEvent.AXIS_RY)) else it
        }
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

    private fun deadzone(value: Float): Float =
        if (abs(value) < deadzone) 0f else value.coerceIn(-1f, 1f)

    private fun trigger(event: MotionEvent, primary: Int, fallback: Int): Float {
        var v = event.getAxisValue(primary)
        if (v <= 0f) v = event.getAxisValue(fallback)
        return v.coerceIn(0f, 1f)
    }

    private fun triggerValue(raw: Float, invert: Boolean): Float {
        val v = if (invert) -raw else raw
        return v.coerceIn(0f, 1f)
    }

    companion object {
        private const val TAG = "PlayniteGamepadSender"
        const val MAX_SEAT = 8

        fun logicalToBit(logical: String): Int? = when (logical) {
            "buttonA" -> PlayniteStreamProtocols.GamepadButtons.A
            "buttonB" -> PlayniteStreamProtocols.GamepadButtons.B
            "buttonX" -> PlayniteStreamProtocols.GamepadButtons.X
            "buttonY" -> PlayniteStreamProtocols.GamepadButtons.Y
            "leftShoulder" -> PlayniteStreamProtocols.GamepadButtons.L1
            "rightShoulder" -> PlayniteStreamProtocols.GamepadButtons.R1
            "leftThumbstickButton" -> PlayniteStreamProtocols.GamepadButtons.L3
            "rightThumbstickButton" -> PlayniteStreamProtocols.GamepadButtons.R3
            "buttonMenu" -> PlayniteStreamProtocols.GamepadButtons.START
            "buttonOptions" -> PlayniteStreamProtocols.GamepadButtons.SELECT
            "buttonGuide" -> PlayniteStreamProtocols.GamepadButtons.GUIDE
            "dpadUp" -> PlayniteStreamProtocols.GamepadButtons.DPAD_UP
            "dpadDown" -> PlayniteStreamProtocols.GamepadButtons.DPAD_DOWN
            "dpadLeft" -> PlayniteStreamProtocols.GamepadButtons.DPAD_LEFT
            "dpadRight" -> PlayniteStreamProtocols.GamepadButtons.DPAD_RIGHT
            else -> null
        }

        fun keyCodeToBit(keyCode: Int): Int? = when (keyCode) {
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
    }
}

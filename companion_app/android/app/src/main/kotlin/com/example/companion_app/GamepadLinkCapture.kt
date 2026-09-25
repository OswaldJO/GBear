package com.example.companion_app

import android.view.KeyEvent
import android.view.MotionEvent
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs

/** One-shot capture of the next gamepad input while assigning manual links in settings. */
object GamepadLinkCapture {
    data class CapturedInput(
        val keyCode: Int,
        val label: String,
        val elementId: String,
        val guid: String = "",
        val deviceName: String = "",
    )

    private data class PendingLink(
        val targetElementId: String,
        val onCaptured: (CapturedInput) -> Unit,
    )

    private val pending = AtomicReference<PendingLink?>(null)
    private var motionEdgeId: String? = null

    fun beginListening(targetElementId: String, onCaptured: (CapturedInput) -> Unit): Boolean {
        motionEdgeId = null
        return pending.compareAndSet(null, PendingLink(targetElementId, onCaptured))
    }

    fun cancel() {
        motionEdgeId = null
        pending.set(null)
    }

    fun isListening(): Boolean = pending.get() != null

    fun tryConsume(event: KeyEvent): Boolean {
        if (!GamepadInputFilter.isGamepadKey(event)) return false
        if (event.action != KeyEvent.ACTION_DOWN || event.repeatCount > 0) {
            return pending.get() != null
        }
        val link = pending.getAndSet(null) ?: return false
        motionEdgeId = null
        val keyCode = event.keyCode
        val device = event.device
        link.onCaptured(
            CapturedInput(
                keyCode = keyCode,
                label = GamepadKeyCodes.labelForKeyCode(keyCode),
                elementId = link.targetElementId,
                guid = device?.let { GBearGamepadAutoMapper.guid(it) }.orEmpty(),
                deviceName = device?.name.orEmpty(),
            ),
        )
        return true
    }

    fun tryConsumeMotion(event: MotionEvent): Boolean {
        if (!GamepadInputFilter.isGamepadMotion(event)) return false
        val link = pending.get() ?: return false
        if (event.action != MotionEvent.ACTION_MOVE) return true

        val direction = resolveHatDirection(event, link.targetElementId)
            ?: resolveStickDirection(event, link.targetElementId)
        if (direction == null) {
            motionEdgeId = null
            return true
        }
        if (motionEdgeId == direction.id) return true

        val captured = pending.getAndSet(null) ?: return true
        captured.onCaptured(
            CapturedInput(
                keyCode = direction.keyCode,
                label = direction.label,
                elementId = captured.targetElementId,
                guid = event.device?.let { GBearGamepadAutoMapper.guid(it) }.orEmpty(),
                deviceName = event.device?.name.orEmpty(),
            ),
        )
        motionEdgeId = null
        return true
    }

    private data class LinkDirection(
        val id: String,
        val keyCode: Int,
        val label: String,
    )

    private fun resolveHatDirection(event: MotionEvent, targetElementId: String): LinkDirection? {
        if (!targetElementId.startsWith("dpad")) return null
        val hatX = event.getAxisValue(MotionEvent.AXIS_HAT_X)
        val hatY = event.getAxisValue(MotionEvent.AXIS_HAT_Y)
        val threshold = 0.45f
        val candidate = when {
            hatY < -threshold -> "dpadUp"
            hatY > threshold -> "dpadDown"
            hatX < -threshold -> "dpadLeft"
            hatX > threshold -> "dpadRight"
            else -> return null
        }
        if (candidate != targetElementId) return null
        val keyCode = GamepadKeyCodes.keyCodeForElementId(candidate) ?: return null
        return LinkDirection(
            id = "hat_$candidate",
            keyCode = keyCode,
            label = GamepadKeyCodes.labelForElementId(candidate),
        )
    }

    private fun resolveStickDirection(event: MotionEvent, targetElementId: String): LinkDirection? {
        if (!targetElementId.startsWith("leftStick") && !targetElementId.startsWith("rightStick")) {
            return resolveStickAsDpadFallback(event, targetElementId)
        }
        val useLeft = targetElementId.startsWith("leftStick")
        val axisSets = if (useLeft) {
            listOf(MotionEvent.AXIS_X to MotionEvent.AXIS_Y)
        } else {
            listOf(
                MotionEvent.AXIS_Z to MotionEvent.AXIS_RZ,
                MotionEvent.AXIS_RX to MotionEvent.AXIS_RY,
            )
        }
        val threshold = 0.55f
        for ((xAxis, yAxis) in axisSets) {
            val x = event.getAxisValue(xAxis)
            val y = event.getAxisValue(yAxis)
            if (abs(x) < threshold && abs(y) < threshold) continue
            val matched = matchStickElementId(targetElementId, x, y, threshold) ?: continue
            val keyCode = GamepadKeyCodes.keyCodeForElementId(matched) ?: continue
            return LinkDirection(
                id = "stick_$matched",
                keyCode = keyCode,
                label = GamepadKeyCodes.labelForElementId(matched),
            )
        }
        return null
    }

    private fun matchStickElementId(
        targetElementId: String,
        x: Float,
        y: Float,
        threshold: Float,
    ): String? = when (targetElementId) {
        "leftStickUp", "rightStickUp" ->
            if (y < -threshold && abs(y) >= abs(x)) targetElementId else null
        "leftStickDown", "rightStickDown" ->
            if (y > threshold && abs(y) >= abs(x)) targetElementId else null
        "leftStickLeft", "rightStickLeft" ->
            if (x < -threshold && abs(x) > abs(y)) targetElementId else null
        "leftStickRight", "rightStickRight" ->
            if (x > threshold && abs(x) > abs(y)) targetElementId else null
        else -> null
    }

    /** D-pad slots: accept hat or either stick pushed in that direction. */
    private fun resolveStickAsDpadFallback(event: MotionEvent, targetElementId: String): LinkDirection? {
        if (!targetElementId.startsWith("dpad")) return null
        val threshold = 0.55f
        val axisSets = listOf(
            MotionEvent.AXIS_X to MotionEvent.AXIS_Y,
            MotionEvent.AXIS_Z to MotionEvent.AXIS_RZ,
        )
        for ((xAxis, yAxis) in axisSets) {
            val x = event.getAxisValue(xAxis)
            val y = event.getAxisValue(yAxis)
            if (abs(x) < threshold && abs(y) < threshold) continue
            val elementId = when {
                y < -threshold && abs(y) >= abs(x) -> "dpadUp"
                y > threshold && abs(y) >= abs(x) -> "dpadDown"
                x < -threshold && abs(x) > abs(y) -> "dpadLeft"
                x > threshold && abs(x) > abs(y) -> "dpadRight"
                else -> continue
            }
            if (elementId != targetElementId) continue
            val keyCode = GamepadKeyCodes.keyCodeForElementId(elementId) ?: continue
            return LinkDirection(
                id = "stick_$elementId",
                keyCode = keyCode,
                label = GamepadKeyCodes.labelForElementId(elementId),
            )
        }
        return null
    }
}

package com.example.companion_app

import android.util.Log
import android.view.KeyEvent
import android.view.MotionEvent
import kotlin.math.abs
import org.json.JSONArray
import org.json.JSONObject

/**
 * Controller element → keyboard chord or Swap-toggle mappings for native GBear streaming.
 * Manual physical key links override automatic Android keyCode → element detection.
 */
class GBearGamepadMapping(bindingsJson: String) {
    data class ElementBinding(
        val elementId: String,
        val moonlightKeyCodes: List<Int>,
        val targetAction: String?,
        val physicalKeyCode: Int?,
        val manualPhysicalLink: Boolean,
    ) {
        val isSwapToggle: Boolean =
            targetAction == GBearSwapToggleMapping.TARGET_ACTION_TOGGLE_SWAP
    }

    private val bindingsByElement = mutableMapOf<String, ElementBinding>()
    private val physicalToElementManual = mutableMapOf<Int, String>()
    private val triggerDown = mutableMapOf<String, Boolean>()
    private val hatDpadDown = mutableMapOf<String, Boolean>()
    private val stickDirectionDown = mutableMapOf<String, Boolean>()

    init {
        if (bindingsJson.isNotEmpty()) {
            try {
                val array = JSONArray(bindingsJson)
                for (i in 0 until array.length()) {
                    val item = array.getJSONObject(i)
                    val elementId = item.optString("sourceElementId", "")
                    if (elementId.isEmpty()) continue
                    val action = item.optString("targetAction", "").ifEmpty { null }
                    val keys = parseKeyCodes(item)
                    val physical = if (item.has("physicalKeyCode")) item.optInt("physicalKeyCode", -1) else -1
                    val manual = item.optBoolean("manualPhysicalLink", false)
                    val isSwap = action == GBearSwapToggleMapping.TARGET_ACTION_TOGGLE_SWAP
                    if (keys.isEmpty() && !isSwap && !(manual && physical >= 0)) {
                        continue
                    }
                    val binding = ElementBinding(
                        elementId = elementId,
                        moonlightKeyCodes = keys,
                        targetAction = action,
                        physicalKeyCode = physical.takeIf { it >= 0 },
                        manualPhysicalLink = manual,
                    )
                    bindingsByElement[elementId] = binding
                    if (manual && physical >= 0) {
                        registerManualPhysicalLink(elementId, physical)
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to parse bindings", e)
            }
        }
        applyStartMenuAliases()
        mappingLogsEmitted = 0
    }

    fun hasBindings(): Boolean = bindingsByElement.isNotEmpty()

    /**
     * @return true if the event was consumed; false to allow Swap mouse mode for face buttons.
     */
    fun handleKeyEvent(
        event: KeyEvent,
        keyboard: GBearKeyboardSender?,
        swapModeActive: Boolean,
        onToggleSwap: () -> Unit,
    ): Boolean {
        if (bindingsByElement.isEmpty()) return false
        val elementId = resolveElementId(event) ?: run {
            logUnmappedKey(event)
            return false
        }
        val binding = bindingsByElement[elementId] ?: return handleUnmapped(event, swapModeActive)
        val down = event.action == KeyEvent.ACTION_DOWN
        val up = event.action == KeyEvent.ACTION_UP
        if (!down && !up) return true

        if (binding.isSwapToggle) {
            if (down && event.repeatCount == 0) {
                onToggleSwap()
            }
            return true
        }

        // Swap mouse mode only takes A / B / X; other mappings (Start → Enter, etc.) keep working.
        if (swapModeActive && elementUsesSwapMouse(elementId)) {
            return false
        }

        if (binding.moonlightKeyCodes.isEmpty()) return true
        keyboard ?: return true
        if (down && event.repeatCount > 0) return true
        keyboard.sendChord(binding.moonlightKeyCodes, down)
        if (down && event.repeatCount == 0) {
            logMappingFire(elementId, binding.moonlightKeyCodes, event.keyCode)
        }
        return true
    }

    /** Many pads report D-pad as [MotionEvent.AXIS_HAT_X/Y] instead of [KeyEvent] DPAD key codes. */
    fun handleHatDpad(
        event: MotionEvent,
        keyboard: GBearKeyboardSender?,
        swapModeActive: Boolean,
        onToggleSwap: () -> Unit,
    ): Boolean {
        if (bindingsByElement.isEmpty()) return false
        val hatX = event.getAxisValue(MotionEvent.AXIS_HAT_X)
        val hatY = event.getAxisValue(MotionEvent.AXIS_HAT_Y)
        val threshold = 0.45f
        val directions = listOf(
            "dpadUp" to (hatY < -threshold),
            "dpadDown" to (hatY > threshold),
            "dpadLeft" to (hatX < -threshold),
            "dpadRight" to (hatX > threshold),
        )
        var consumed = false
        for ((elementId, pressed) in directions) {
            val binding = bindingsByElement[elementId] ?: continue
            val wasDown = hatDpadDown[elementId] == true
            if (binding.isSwapToggle) {
                if (pressed && !wasDown) {
                    onToggleSwap()
                    consumed = true
                }
                if (pressed) hatDpadDown[elementId] = true else hatDpadDown.remove(elementId)
                continue
            }
            if (swapModeActive && elementUsesSwapMouse(elementId)) continue
            if (binding.moonlightKeyCodes.isEmpty()) continue
            keyboard ?: continue
            if (wasDown != pressed) {
                keyboard.sendChord(binding.moonlightKeyCodes, pressed)
                if (pressed) {
                    logMappingFire(elementId, binding.moonlightKeyCodes, syntheticHatKey(elementId))
                }
                consumed = true
            }
            if (pressed) hatDpadDown[elementId] = true else hatDpadDown.remove(elementId)
        }
        return consumed
    }

    /** Left / right analog stick cardinal directions (axis motion, not L3/R3). */
    fun handleAnalogSticks(
        event: MotionEvent,
        keyboard: GBearKeyboardSender?,
        swapModeActive: Boolean,
        onToggleSwap: () -> Unit,
    ): Boolean {
        if (bindingsByElement.isEmpty()) return false
        val threshold = 0.55f
        val sticks = listOf(
            StickAxes("leftStick", MotionEvent.AXIS_X, MotionEvent.AXIS_Y),
            StickAxes("rightStick", MotionEvent.AXIS_Z, MotionEvent.AXIS_RZ),
            StickAxes("rightStick", MotionEvent.AXIS_RX, MotionEvent.AXIS_RY),
        )
        var consumed = false
        for (stick in sticks) {
            if (stick.xAxis == MotionEvent.AXIS_RX) {
                val z = abs(event.getAxisValue(MotionEvent.AXIS_Z))
                val rz = abs(event.getAxisValue(MotionEvent.AXIS_RZ))
                if (z > 0.2f || rz > 0.2f) continue
            }
            val x = event.getAxisValue(stick.xAxis)
            val y = event.getAxisValue(stick.yAxis)
            val directions = listOf(
                "${stick.prefix}Up" to (y < -threshold && abs(y) >= abs(x)),
                "${stick.prefix}Down" to (y > threshold && abs(y) >= abs(x)),
                "${stick.prefix}Left" to (x < -threshold && abs(x) > abs(y)),
                "${stick.prefix}Right" to (x > threshold && abs(x) > abs(y)),
            )
            for ((elementId, pressed) in directions) {
                val binding = bindingsByElement[elementId] ?: continue
                val wasDown = stickDirectionDown[elementId] == true
                if (binding.isSwapToggle) {
                    if (pressed && !wasDown) {
                        onToggleSwap()
                        consumed = true
                    }
                    if (pressed) stickDirectionDown[elementId] = true else stickDirectionDown.remove(elementId)
                    continue
                }
                if (swapModeActive && elementUsesSwapMouse(elementId)) continue
                if (binding.moonlightKeyCodes.isEmpty()) continue
                keyboard ?: continue
                if (wasDown != pressed) {
                    keyboard.sendChord(binding.moonlightKeyCodes, pressed)
                    if (pressed) {
                        logMappingFire(
                            elementId,
                            binding.moonlightKeyCodes,
                            GamepadKeyCodes.keyCodeForElementId(elementId) ?: 0,
                        )
                    }
                    consumed = true
                }
                if (pressed) stickDirectionDown[elementId] = true else stickDirectionDown.remove(elementId)
            }
        }
        return consumed
    }

    private data class StickAxes(val prefix: String, val xAxis: Int, val yAxis: Int)

    fun handleTrigger(
        elementId: String,
        axisValue: Float,
        keyboard: GBearKeyboardSender?,
        swapModeActive: Boolean,
        onToggleSwap: () -> Unit,
    ): Boolean {
        val binding = bindingsByElement[elementId] ?: return false
        val down = axisValue > 0.65f
        val prev = triggerDown[elementId]

        if (binding.isSwapToggle) {
            if (down && prev != true) {
                triggerDown[elementId] = true
                onToggleSwap()
            } else if (!down) {
                triggerDown.remove(elementId)
            }
            return true
        }

        if (swapModeActive && elementUsesSwapMouse(elementId)) return false
        if (binding.moonlightKeyCodes.isEmpty()) return false
        if (prev != null && prev == down) return true
        triggerDown[elementId] = down
        keyboard?.sendChord(binding.moonlightKeyCodes, down)
        return true
    }

    private fun handleUnmapped(event: KeyEvent, swapModeActive: Boolean): Boolean {
        if (swapModeActive) return false
        return GamepadInputFilter.isGamepadKey(event)
    }

    private fun resolveElementId(event: KeyEvent): String? {
        val keyCode = event.keyCode
        physicalToElementManual[keyCode]?.let { return it }
        GamepadKeyCodes.elementIdForKeyCode(keyCode)?.let { elementId ->
            if (bindingsByElement.containsKey(elementId)) return elementId
        }
        if (GamepadKeyCodes.startMenuKeyCodes.contains(keyCode) &&
            bindingsByElement.containsKey("buttonMenu")
        ) {
            return "buttonMenu"
        }
        return null
    }

    /** Map Start / Menu / App to [buttonMenu] when that slot has any binding. */
    private fun elementUsesSwapMouse(elementId: String): Boolean =
        elementId == "buttonA" ||
            elementId == "buttonB" ||
            elementId == "buttonX" ||
            elementId.startsWith("leftStick")

    private fun applyStartMenuAliases() {
        if (!bindingsByElement.containsKey("buttonMenu")) return
        for (code in GamepadKeyCodes.startMenuKeyCodes) {
            physicalToElementManual.putIfAbsent(code, "buttonMenu")
        }
    }

    private fun registerManualPhysicalLink(elementId: String, physical: Int) {
        physicalToElementManual[physical] = elementId
        if (elementId == "buttonMenu") {
            for (code in GamepadKeyCodes.startMenuKeyCodes) {
                physicalToElementManual[code] = elementId
            }
        }
    }

    private fun logUnmappedKey(event: KeyEvent) {
        if (event.action != KeyEvent.ACTION_DOWN || event.repeatCount > 0) return
        if (!GamepadInputFilter.isGamepadKey(event)) return
        if (mappingLogsEmitted >= MAX_MAPPING_LOGS) return
        mappingLogsEmitted += 1
        GBearStreamLog.i(
            "Gamepad key not mapped keyCode=${event.keyCode} " +
                "(${GamepadKeyCodes.labelForKeyCode(event.keyCode)}) — use Link gamepad on Start / Menu",
        )
    }

    private fun syntheticHatKey(elementId: String): Int =
        GamepadKeyCodes.keyCodeForElementId(elementId) ?: 0

    private fun logMappingFire(elementId: String, codes: List<Int>, physicalKey: Int) {
        if (mappingLogsEmitted >= MAX_MAPPING_LOGS) return
        mappingLogsEmitted += 1
        val keys = codes.joinToString { "0x${it.toString(16)}" }
        GBearStreamLog.i(
            "Gamepad map $elementId physical=$physicalKey (${GamepadKeyCodes.labelForKeyCode(physicalKey)}) → GBK1 $keys",
        )
    }

    private fun parseKeyCodes(item: JSONObject): List<Int> {
        if (item.has("moonlightKeyCodes")) {
            val arr = item.optJSONArray("moonlightKeyCodes") ?: return emptyList()
            return (0 until arr.length()).mapNotNull { idx ->
                val code = arr.optInt(idx, 0)
                code.takeIf { it != 0 }
            }
        }
        val single = item.optInt("moonlightKeyCode", 0)
        return if (single != 0) listOf(single) else emptyList()
    }

    companion object {
        private const val TAG = "GBearGamepadMap"
        private const val MAX_MAPPING_LOGS = 64
        @Volatile
        private var mappingLogsEmitted = 0
    }
}

/** Shared keyCode ↔ logical gamepad element mapping. */
object GamepadKeyCodes {
    /** [KeyEvent.KEYCODE_APP] (API 24+); some pads use this for Start/Guide. */
    const val KEYCODE_APP_COMPAT = 88

    const val SYNTHETIC_LEFT_STICK_UP = 0x400001
    const val SYNTHETIC_LEFT_STICK_DOWN = 0x400002
    const val SYNTHETIC_LEFT_STICK_LEFT = 0x400003
    const val SYNTHETIC_LEFT_STICK_RIGHT = 0x400004
    const val SYNTHETIC_RIGHT_STICK_UP = 0x400005
    const val SYNTHETIC_RIGHT_STICK_DOWN = 0x400006
    const val SYNTHETIC_RIGHT_STICK_LEFT = 0x400007
    const val SYNTHETIC_RIGHT_STICK_RIGHT = 0x400008

    fun elementIdForKeyCode(keyCode: Int): String? = when (keyCode) {
        KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_DPAD_CENTER -> "buttonA"
        KeyEvent.KEYCODE_BUTTON_B -> "buttonB"
        KeyEvent.KEYCODE_BUTTON_X -> "buttonX"
        KeyEvent.KEYCODE_BUTTON_Y -> "buttonY"
        KeyEvent.KEYCODE_BUTTON_L1 -> "leftShoulder"
        KeyEvent.KEYCODE_BUTTON_R1 -> "rightShoulder"
        KeyEvent.KEYCODE_BUTTON_L2 -> "leftTrigger"
        KeyEvent.KEYCODE_BUTTON_R2 -> "rightTrigger"
        KeyEvent.KEYCODE_BUTTON_THUMBL -> "leftThumbstickButton"
        KeyEvent.KEYCODE_BUTTON_THUMBR -> "rightThumbstickButton"
        KeyEvent.KEYCODE_DPAD_UP -> "dpadUp"
        KeyEvent.KEYCODE_DPAD_DOWN -> "dpadDown"
        KeyEvent.KEYCODE_DPAD_LEFT -> "dpadLeft"
        KeyEvent.KEYCODE_DPAD_RIGHT -> "dpadRight"
        KeyEvent.KEYCODE_BUTTON_START,
        KeyEvent.KEYCODE_MENU,
        KEYCODE_APP_COMPAT,
        -> "buttonMenu"
        KeyEvent.KEYCODE_BUTTON_SELECT -> "buttonOptions"
        KeyEvent.KEYCODE_BUTTON_1 -> "macro1"
        KeyEvent.KEYCODE_BUTTON_2 -> "macro2"
        KeyEvent.KEYCODE_BUTTON_3 -> "macro3"
        KeyEvent.KEYCODE_BUTTON_4 -> "macro4"
        SYNTHETIC_LEFT_STICK_UP -> "leftStickUp"
        SYNTHETIC_LEFT_STICK_DOWN -> "leftStickDown"
        SYNTHETIC_LEFT_STICK_LEFT -> "leftStickLeft"
        SYNTHETIC_LEFT_STICK_RIGHT -> "leftStickRight"
        SYNTHETIC_RIGHT_STICK_UP -> "rightStickUp"
        SYNTHETIC_RIGHT_STICK_DOWN -> "rightStickDown"
        SYNTHETIC_RIGHT_STICK_LEFT -> "rightStickLeft"
        SYNTHETIC_RIGHT_STICK_RIGHT -> "rightStickRight"
        else -> null
    }

    fun keyCodeForElementId(elementId: String): Int? = when (elementId) {
        "buttonA" -> KeyEvent.KEYCODE_BUTTON_A
        "buttonB" -> KeyEvent.KEYCODE_BUTTON_B
        "buttonX" -> KeyEvent.KEYCODE_BUTTON_X
        "buttonY" -> KeyEvent.KEYCODE_BUTTON_Y
        "leftShoulder" -> KeyEvent.KEYCODE_BUTTON_L1
        "rightShoulder" -> KeyEvent.KEYCODE_BUTTON_R1
        "leftThumbstickButton" -> KeyEvent.KEYCODE_BUTTON_THUMBL
        "rightThumbstickButton" -> KeyEvent.KEYCODE_BUTTON_THUMBR
        "dpadUp" -> KeyEvent.KEYCODE_DPAD_UP
        "dpadDown" -> KeyEvent.KEYCODE_DPAD_DOWN
        "dpadLeft" -> KeyEvent.KEYCODE_DPAD_LEFT
        "dpadRight" -> KeyEvent.KEYCODE_DPAD_RIGHT
        "buttonMenu" -> KeyEvent.KEYCODE_BUTTON_START
        "buttonOptions" -> KeyEvent.KEYCODE_BUTTON_SELECT
        "macro1" -> KeyEvent.KEYCODE_BUTTON_1
        "macro2" -> KeyEvent.KEYCODE_BUTTON_2
        "macro3" -> KeyEvent.KEYCODE_BUTTON_3
        "macro4" -> KeyEvent.KEYCODE_BUTTON_4
        "leftStickUp" -> SYNTHETIC_LEFT_STICK_UP
        "leftStickDown" -> SYNTHETIC_LEFT_STICK_DOWN
        "leftStickLeft" -> SYNTHETIC_LEFT_STICK_LEFT
        "leftStickRight" -> SYNTHETIC_LEFT_STICK_RIGHT
        "rightStickUp" -> SYNTHETIC_RIGHT_STICK_UP
        "rightStickDown" -> SYNTHETIC_RIGHT_STICK_DOWN
        "rightStickLeft" -> SYNTHETIC_RIGHT_STICK_LEFT
        "rightStickRight" -> SYNTHETIC_RIGHT_STICK_RIGHT
        else -> null
    }

    fun labelForElementId(elementId: String): String =
        labelForKeyCode(keyCodeForElementId(elementId) ?: -1).let { label ->
            if (label == "Key -1") elementId else label
        }

    fun labelForKeyCode(keyCode: Int): String = when (keyCode) {
        KeyEvent.KEYCODE_BUTTON_A -> "A"
        KeyEvent.KEYCODE_BUTTON_B -> "B"
        KeyEvent.KEYCODE_BUTTON_X -> "X"
        KeyEvent.KEYCODE_BUTTON_Y -> "Y"
        KeyEvent.KEYCODE_BUTTON_L1 -> "L1"
        KeyEvent.KEYCODE_BUTTON_R1 -> "R1"
        KeyEvent.KEYCODE_BUTTON_L2 -> "L2"
        KeyEvent.KEYCODE_BUTTON_R2 -> "R2"
        KeyEvent.KEYCODE_BUTTON_THUMBL -> "L3"
        KeyEvent.KEYCODE_BUTTON_THUMBR -> "R3"
        KeyEvent.KEYCODE_DPAD_UP -> "D-pad up"
        KeyEvent.KEYCODE_DPAD_DOWN -> "D-pad down"
        KeyEvent.KEYCODE_DPAD_LEFT -> "D-pad left"
        KeyEvent.KEYCODE_DPAD_RIGHT -> "D-pad right"
        KeyEvent.KEYCODE_BUTTON_START -> "Start"
        KeyEvent.KEYCODE_MENU -> "Menu"
        KEYCODE_APP_COMPAT -> "App"
        KeyEvent.KEYCODE_BUTTON_SELECT -> "Select"
        KeyEvent.KEYCODE_BUTTON_1 -> "Macro 1"
        KeyEvent.KEYCODE_BUTTON_2 -> "Macro 2"
        KeyEvent.KEYCODE_BUTTON_3 -> "Macro 3"
        KeyEvent.KEYCODE_BUTTON_4 -> "Macro 4"
        SYNTHETIC_LEFT_STICK_UP -> "Left stick up"
        SYNTHETIC_LEFT_STICK_DOWN -> "Left stick down"
        SYNTHETIC_LEFT_STICK_LEFT -> "Left stick left"
        SYNTHETIC_LEFT_STICK_RIGHT -> "Left stick right"
        SYNTHETIC_RIGHT_STICK_UP -> "Right stick up"
        SYNTHETIC_RIGHT_STICK_DOWN -> "Right stick down"
        SYNTHETIC_RIGHT_STICK_LEFT -> "Right stick left"
        SYNTHETIC_RIGHT_STICK_RIGHT -> "Right stick right"
        else -> "Key $keyCode"
    }

    /** Android often reports Start as [KEYCODE_BUTTON_START] or [KEYCODE_MENU]. */
    val startMenuKeyCodes: List<Int> = listOf(
        KeyEvent.KEYCODE_BUTTON_START,
        KeyEvent.KEYCODE_MENU,
        KEYCODE_APP_COMPAT,
    )

    val probeKeyCodes: List<Int> = listOf(
        KeyEvent.KEYCODE_BUTTON_A,
        KeyEvent.KEYCODE_BUTTON_B,
        KeyEvent.KEYCODE_BUTTON_X,
        KeyEvent.KEYCODE_BUTTON_Y,
        KeyEvent.KEYCODE_BUTTON_L1,
        KeyEvent.KEYCODE_BUTTON_R1,
        KeyEvent.KEYCODE_BUTTON_L2,
        KeyEvent.KEYCODE_BUTTON_R2,
        KeyEvent.KEYCODE_BUTTON_THUMBL,
        KeyEvent.KEYCODE_BUTTON_THUMBR,
        KeyEvent.KEYCODE_DPAD_UP,
        KeyEvent.KEYCODE_DPAD_DOWN,
        KeyEvent.KEYCODE_DPAD_LEFT,
        KeyEvent.KEYCODE_DPAD_RIGHT,
        KeyEvent.KEYCODE_BUTTON_START,
        KeyEvent.KEYCODE_MENU,
        KEYCODE_APP_COMPAT,
        KeyEvent.KEYCODE_BUTTON_SELECT,
        KeyEvent.KEYCODE_BUTTON_1,
        KeyEvent.KEYCODE_BUTTON_2,
        KeyEvent.KEYCODE_BUTTON_3,
        KeyEvent.KEYCODE_BUTTON_4,
    )
}

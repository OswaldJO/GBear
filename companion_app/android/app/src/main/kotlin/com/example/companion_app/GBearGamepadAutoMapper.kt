package com.example.companion_app

import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import org.json.JSONArray
import org.json.JSONObject

/** Eden-style capability probe: keys/axes → GBG1 logical controls, with optional face-button swap. */
object GBearGamepadAutoMapper {
    fun guid(device: InputDevice): String =
        String.format("%016x%016x", device.productId, device.vendorId)

    fun isPhysicalGameController(device: InputDevice?): Boolean {
        device ?: return false
        if (device.isVirtual) return false
        val sources = device.sources
        val hasControllerSource =
            sources and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD ||
                sources and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK
        if (!hasControllerSource) return false
        val hasKeys = device.hasKeys(*probeKeyCodes).any { it }
        val hasAxes = device.motionRanges.any { probeAxes.contains(it.axis) }
        return hasKeys || hasAxes
    }

    fun autoMap(device: InputDevice, swapFaceButtons: Boolean): GBearCoopPadMapping {
        val availableKeys = probeKeyCodes.filter { code ->
            device.hasKeys(code).firstOrNull() == true
        }.toSet()
        val axes = device.motionRanges.map { it.axis }.toSet()
        val bindings = mutableListOf<GBearCoopPadBinding>()

        fun addKey(logical: String, keyCode: Int) {
            if (keyCode in availableKeys) {
                bindings.add(GBearCoopPadBinding.key(logical, keyCode))
            }
        }

        val flipAb = swapFaceButtons
        if (KeyEvent.KEYCODE_BUTTON_A in availableKeys) {
            addKey(if (flipAb) "buttonB" else "buttonA", KeyEvent.KEYCODE_BUTTON_A)
        }
        if (KeyEvent.KEYCODE_BUTTON_B in availableKeys) {
            addKey(if (flipAb) "buttonA" else "buttonB", KeyEvent.KEYCODE_BUTTON_B)
        }
        val flipXy = swapFaceButtons
        if (KeyEvent.KEYCODE_BUTTON_X in availableKeys) {
            addKey(if (flipXy) "buttonY" else "buttonX", KeyEvent.KEYCODE_BUTTON_X)
        }
        if (KeyEvent.KEYCODE_BUTTON_Y in availableKeys) {
            addKey(if (flipXy) "buttonX" else "buttonY", KeyEvent.KEYCODE_BUTTON_Y)
        }
        addKey("leftShoulder", KeyEvent.KEYCODE_BUTTON_L1)
        addKey("rightShoulder", KeyEvent.KEYCODE_BUTTON_R1)
        addKey("leftThumbstickButton", KeyEvent.KEYCODE_BUTTON_THUMBL)
        addKey("rightThumbstickButton", KeyEvent.KEYCODE_BUTTON_THUMBR)
        addKey("buttonMenu", KeyEvent.KEYCODE_BUTTON_START)
        addKey("buttonOptions", KeyEvent.KEYCODE_BUTTON_SELECT)
        addKey("buttonGuide", KeyEvent.KEYCODE_BUTTON_MODE)

        if (MotionEvent.AXIS_HAT_X in axes && MotionEvent.AXIS_HAT_Y in axes) {
            bindings.add(GBearCoopPadBinding.axis("dpadUp", MotionEvent.AXIS_HAT_Y, invert = true))
            bindings.add(GBearCoopPadBinding.axis("dpadDown", MotionEvent.AXIS_HAT_Y, invert = false))
            bindings.add(GBearCoopPadBinding.axis("dpadLeft", MotionEvent.AXIS_HAT_X, invert = true))
            bindings.add(GBearCoopPadBinding.axis("dpadRight", MotionEvent.AXIS_HAT_X, invert = false))
        } else {
            addKey("dpadUp", KeyEvent.KEYCODE_DPAD_UP)
            addKey("dpadDown", KeyEvent.KEYCODE_DPAD_DOWN)
            addKey("dpadLeft", KeyEvent.KEYCODE_DPAD_LEFT)
            addKey("dpadRight", KeyEvent.KEYCODE_DPAD_RIGHT)
        }

        if (MotionEvent.AXIS_LTRIGGER in axes) {
            bindings.add(GBearCoopPadBinding.axis("leftTrigger", MotionEvent.AXIS_LTRIGGER, invert = false))
        } else {
            addKey("leftTrigger", KeyEvent.KEYCODE_BUTTON_L2)
        }
        if (MotionEvent.AXIS_RTRIGGER in axes) {
            bindings.add(GBearCoopPadBinding.axis("rightTrigger", MotionEvent.AXIS_RTRIGGER, invert = false))
        } else {
            addKey("rightTrigger", KeyEvent.KEYCODE_BUTTON_R2)
        }

        if (MotionEvent.AXIS_X in axes && MotionEvent.AXIS_Y in axes) {
            bindings.add(GBearCoopPadBinding.axis("leftStickX", MotionEvent.AXIS_X, invert = false))
            bindings.add(GBearCoopPadBinding.axis("leftStickY", MotionEvent.AXIS_Y, invert = true))
        }
        when {
            MotionEvent.AXIS_RX in axes && MotionEvent.AXIS_RY in axes -> {
                bindings.add(GBearCoopPadBinding.axis("rightStickX", MotionEvent.AXIS_RX, invert = false))
                bindings.add(GBearCoopPadBinding.axis("rightStickY", MotionEvent.AXIS_RY, invert = true))
            }
            MotionEvent.AXIS_Z in axes && MotionEvent.AXIS_RZ in axes -> {
                bindings.add(GBearCoopPadBinding.axis("rightStickX", MotionEvent.AXIS_Z, invert = false))
                bindings.add(GBearCoopPadBinding.axis("rightStickY", MotionEvent.AXIS_RZ, invert = true))
            }
        }

        return GBearCoopPadMapping(
            guid = guid(device),
            deviceName = device.name ?: "Controller",
            bindings = bindings,
        )
    }

    private val probeKeyCodes = intArrayOf(
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
        KeyEvent.KEYCODE_BUTTON_START,
        KeyEvent.KEYCODE_BUTTON_SELECT,
        KeyEvent.KEYCODE_BUTTON_MODE,
        KeyEvent.KEYCODE_DPAD_UP,
        KeyEvent.KEYCODE_DPAD_DOWN,
        KeyEvent.KEYCODE_DPAD_LEFT,
        KeyEvent.KEYCODE_DPAD_RIGHT,
    )

    private val probeAxes = intArrayOf(
        MotionEvent.AXIS_X,
        MotionEvent.AXIS_Y,
        MotionEvent.AXIS_Z,
        MotionEvent.AXIS_RX,
        MotionEvent.AXIS_RY,
        MotionEvent.AXIS_RZ,
        MotionEvent.AXIS_HAT_X,
        MotionEvent.AXIS_HAT_Y,
        MotionEvent.AXIS_LTRIGGER,
        MotionEvent.AXIS_RTRIGGER,
    )
}

data class GBearCoopPadBinding(
    val logical: String,
    val type: String,
    val keyCode: Int = 0,
    val axis: Int = -1,
    val invert: Boolean = false,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("logical", logical)
        put("type", type)
        put("keyCode", keyCode)
        put("axis", axis)
        put("invert", invert)
    }

    fun summary(): String = when (type) {
        "key" -> GamepadKeyCodes.labelForKeyCode(keyCode)
        "axis" -> "Axis $axis${if (invert) "−" else "+"}"
        else -> type
    }

    companion object {
        fun key(logical: String, keyCode: Int) =
            GBearCoopPadBinding(logical = logical, type = "key", keyCode = keyCode)

        fun axis(logical: String, axis: Int, invert: Boolean) =
            GBearCoopPadBinding(logical = logical, type = "axis", axis = axis, invert = invert)

        fun fromJson(obj: JSONObject): GBearCoopPadBinding = GBearCoopPadBinding(
            logical = obj.optString("logical"),
            type = obj.optString("type"),
            keyCode = obj.optInt("keyCode"),
            axis = obj.optInt("axis", -1),
            invert = obj.optBoolean("invert"),
        )
    }
}

data class GBearCoopPadMapping(
    val guid: String,
    val deviceName: String,
    val bindings: List<GBearCoopPadBinding>,
) {
    fun bindingForLogical(logical: String): GBearCoopPadBinding? =
        bindings.lastOrNull { it.logical == logical }

    fun replacing(binding: GBearCoopPadBinding): GBearCoopPadMapping {
        val next = bindings.filterNot { it.logical == binding.logical } + binding
        return copy(bindings = next)
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("guid", guid)
        put("deviceName", deviceName)
        put("bindings", JSONArray().also { arr ->
            bindings.forEach { arr.put(it.toJson()) }
        })
    }

    fun toMap(): Map<String, Any> = mapOf(
        "guid" to guid,
        "deviceName" to deviceName,
        "bindings" to bindings.map {
            mapOf(
                "logical" to it.logical,
                "type" to it.type,
                "keyCode" to it.keyCode,
                "axis" to it.axis,
                "invert" to it.invert,
                "summary" to it.summary(),
            )
        },
    )

    companion object {
        fun fromJson(obj: JSONObject): GBearCoopPadMapping {
            val arr = obj.optJSONArray("bindings") ?: JSONArray()
            val list = mutableListOf<GBearCoopPadBinding>()
            for (i in 0 until arr.length()) {
                list.add(GBearCoopPadBinding.fromJson(arr.getJSONObject(i)))
            }
            return GBearCoopPadMapping(
                guid = obj.optString("guid"),
                deviceName = obj.optString("deviceName"),
                bindings = list,
            )
        }
    }
}

package com.example.companion_app

import android.content.Context
import android.view.InputDevice
import org.json.JSONObject

object PlayniteCoopPadMappingStore {
    private const val PREFS = "gbear_coop_pad_mappings"
    private const val KEY_PREFIX = "mapping."

    fun load(context: Context, guid: String): PlayniteCoopPadMapping? {
        val raw = prefs(context).getString(KEY_PREFIX + guid, null) ?: return null
        return runCatching { PlayniteCoopPadMapping.fromJson(JSONObject(raw)) }.getOrNull()
    }

    fun save(context: Context, mapping: PlayniteCoopPadMapping) {
        prefs(context).edit().putString(KEY_PREFIX + mapping.guid, mapping.toJson().toString()).apply()
    }

    fun loadOrAutoMap(
        context: Context,
        device: InputDevice,
        swapFaceButtons: Boolean,
    ): PlayniteCoopPadMapping {
        val guid = PlayniteGamepadAutoMapper.guid(device)
        load(context, guid)?.let { return it }
        val mapped = PlayniteGamepadAutoMapper.autoMap(device, swapFaceButtons)
        save(context, mapped)
        return mapped
    }

    fun autoMapAndSave(context: Context, swapFaceButtons: Boolean): List<Map<String, Any>> {
        val results = mutableListOf<Map<String, Any>>()
        for (id in InputDevice.getDeviceIds()) {
            val device = InputDevice.getDevice(id) ?: continue
            if (!PlayniteGamepadAutoMapper.isPhysicalGameController(device)) continue
            val mapping = PlayniteGamepadAutoMapper.autoMap(device, swapFaceButtons)
            save(context, mapping)
            results.add(mapping.toMap())
        }
        return results
    }

    fun all(context: Context): List<Map<String, Any>> {
        val out = mutableListOf<Map<String, Any>>()
        val prefs = prefs(context)
        for (key in prefs.all.keys) {
            if (!key.startsWith(KEY_PREFIX)) continue
            val raw = prefs.getString(key, null) ?: continue
            val mapping = runCatching { PlayniteCoopPadMapping.fromJson(JSONObject(raw)) }.getOrNull()
                ?: continue
            out.add(mapping.toMap())
        }
        return out
    }

    fun applyOverride(
        context: Context,
        guid: String,
        logical: String,
        keyCode: Int,
        axis: Int,
        invert: Boolean,
        deviceName: String,
    ): PlayniteCoopPadMapping {
        val existing = load(context, guid) ?: PlayniteCoopPadMapping(guid, deviceName, emptyList())
        val binding = if (axis >= 0) {
            PlayniteCoopPadBinding.axis(logical, axis, invert)
        } else {
            PlayniteCoopPadBinding.key(logical, keyCode)
        }
        val updated = existing.replacing(binding).copy(deviceName = deviceName.ifEmpty { existing.deviceName })
        save(context, updated)
        return updated
    }

    fun reset(context: Context, guid: String) {
        prefs(context).edit().remove(KEY_PREFIX + guid).apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

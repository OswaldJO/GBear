package com.example.companion_app

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** Reads/writes Flutter [StreamControllerMappingStore] bindings in SharedPreferences. */
object GBearStreamMappingPrefs {
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val BINDINGS_KEY = "flutter.stream.controller.bindings"

    fun loadBindingsJson(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getString(BINDINGS_KEY, null).orEmpty()
    }

    fun saveBindingsJson(context: Context, json: String) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(BINDINGS_KEY, json)
            .apply()
    }

    fun upsertPhysicalLink(
        context: Context,
        elementId: String,
        elementLabel: String,
        keyCode: Int,
        keyLabel: String,
    ): String {
        val array = try {
            JSONArray(loadBindingsJson(context).ifEmpty { "[]" })
        } catch (_: Exception) {
            JSONArray()
        }
        var found = false
        for (i in 0 until array.length()) {
            val item = array.optJSONObject(i) ?: continue
            if (item.optString("sourceElementId") != elementId) continue
            item.put("sourceLabel", elementLabel)
            item.put("physicalKeyCode", keyCode)
            item.put("manualPhysicalLink", true)
            val isSwap =
                item.optString("targetAction") == GBearSwapToggleMapping.TARGET_ACTION_TOGGLE_SWAP
            if (!isSwap) {
                val keys = item.optJSONArray("moonlightKeyCodes")
                if (keys == null || keys.length() == 0) {
                    item.put("targetLabel", keyLabel)
                }
            }
            found = true
            break
        }
        if (!found) {
            array.put(
                JSONObject()
                    .put("sourceElementId", elementId)
                    .put("sourceLabel", elementLabel)
                    .put("moonlightKeyCodes", JSONArray())
                    .put("targetLabel", keyLabel)
                    .put("physicalKeyCode", keyCode)
                    .put("manualPhysicalLink", true),
            )
        }
        val json = array.toString()
        saveBindingsJson(context, json)
        return json
    }

    fun bindingForElement(context: Context, elementId: String): JSONObject? {
        val array = try {
            JSONArray(loadBindingsJson(context).ifEmpty { "[]" })
        } catch (_: Exception) {
            return null
        }
        for (i in 0 until array.length()) {
            val item = array.optJSONObject(i) ?: continue
            if (item.optString("sourceElementId") == elementId) return item
        }
        return null
    }

    fun moonlightKeyCodesForElement(context: Context, elementId: String): List<Int> {
        val item = bindingForElement(context, elementId) ?: return emptyList()
        val arr = item.optJSONArray("moonlightKeyCodes") ?: return emptyList()
        return (0 until arr.length()).mapNotNull { idx ->
            arr.optInt(idx, 0).takeIf { it != 0 }
        }
    }

    fun upsertSwapToggleMapping(
        context: Context,
        elementId: String,
        elementLabel: String,
    ): String {
        val array = try {
            JSONArray(loadBindingsJson(context).ifEmpty { "[]" })
        } catch (_: Exception) {
            JSONArray()
        }
        var found = false
        for (i in 0 until array.length()) {
            val item = array.optJSONObject(i) ?: continue
            if (item.optString("sourceElementId") != elementId) continue
            item.put("sourceLabel", elementLabel)
            item.put("targetAction", GBearSwapToggleMapping.TARGET_ACTION_TOGGLE_SWAP)
            item.put("targetLabel", GBearSwapToggleMapping.TARGET_LABEL)
            item.put("moonlightKeyCodes", JSONArray())
            found = true
            break
        }
        if (!found) {
            array.put(
                JSONObject()
                    .put("sourceElementId", elementId)
                    .put("sourceLabel", elementLabel)
                    .put("targetAction", GBearSwapToggleMapping.TARGET_ACTION_TOGGLE_SWAP)
                    .put("targetLabel", GBearSwapToggleMapping.TARGET_LABEL)
                    .put("moonlightKeyCodes", JSONArray()),
            )
        }
        val json = array.toString()
        saveBindingsJson(context, json)
        return json
    }

    fun upsertKeyboardMapping(
        context: Context,
        elementId: String,
        elementLabel: String,
        moonlightKeyCodes: List<Int>,
        targetLabel: String,
    ): String {
        val array = try {
            JSONArray(loadBindingsJson(context).ifEmpty { "[]" })
        } catch (_: Exception) {
            JSONArray()
        }
        var found = false
        for (i in 0 until array.length()) {
            val item = array.optJSONObject(i) ?: continue
            if (item.optString("sourceElementId") != elementId) continue
            item.put("sourceLabel", elementLabel)
            item.put("moonlightKeyCodes", JSONArray(moonlightKeyCodes))
            item.put("targetLabel", targetLabel)
            item.remove("targetAction")
            found = true
            break
        }
        if (!found) {
            array.put(
                JSONObject()
                    .put("sourceElementId", elementId)
                    .put("sourceLabel", elementLabel)
                    .put("moonlightKeyCodes", JSONArray(moonlightKeyCodes))
                    .put("targetLabel", targetLabel),
            )
        }
        val json = array.toString()
        saveBindingsJson(context, json)
        return json
    }

    fun clearElementMapping(context: Context, elementId: String): String {
        val array = try {
            JSONArray(loadBindingsJson(context).ifEmpty { "[]" })
        } catch (_: Exception) {
            return "[]"
        }
        val kept = JSONArray()
        for (i in 0 until array.length()) {
            val item = array.optJSONObject(i) ?: continue
            if (item.optString("sourceElementId") == elementId) continue
            kept.put(item)
        }
        val json = kept.toString()
        saveBindingsJson(context, json)
        return json
    }

    fun targetLabelForElement(context: Context, elementId: String): String {
        val array = try {
            JSONArray(loadBindingsJson(context).ifEmpty { "[]" })
        } catch (_: Exception) {
            return "Unmapped"
        }
        for (i in 0 until array.length()) {
            val item = array.optJSONObject(i) ?: continue
            if (item.optString("sourceElementId") != elementId) continue
            if (item.optString("targetAction") == GBearSwapToggleMapping.TARGET_ACTION_TOGGLE_SWAP) {
                return GBearSwapToggleMapping.TARGET_LABEL
            }
            val label = item.optString("targetLabel", "")
            if (label.isNotEmpty()) return label
            val keys = item.optJSONArray("moonlightKeyCodes")
            if (keys != null && keys.length() > 0) return "Keyboard chord"
            val physical = if (item.has("physicalKeyCode")) item.optInt("physicalKeyCode", -1) else -1
            if (physical >= 0) return GamepadKeyCodes.labelForKeyCode(physical)
        }
        return "Unmapped"
    }
}

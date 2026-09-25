package com.example.companion_app

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** Reads Flutter [StreamShortcutsStore] JSON from SharedPreferences. */
object GBearStreamShortcutsPrefs {
    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val SHORTCUTS_KEY = "flutter.stream.shortcuts"

    data class Shortcut(
        val id: String,
        val name: String,
        val moonlightKeyCodes: List<Int>,
        val keyLabel: String,
    )

    fun load(context: Context): List<Shortcut> {
        val raw = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(SHORTCUTS_KEY, null)
            .orEmpty()
        if (raw.isEmpty()) return defaultShortcuts()
        return try {
            val array = JSONArray(raw)
            val list = mutableListOf<Shortcut>()
            for (i in 0 until array.length()) {
                val item = array.optJSONObject(i) ?: continue
                val id = item.optString("id", "")
                val name = item.optString("name", "")
                val codes = parseKeyCodes(item)
                if (id.isEmpty() || name.isEmpty() || codes.isEmpty()) continue
                val label = item.optString("keyLabel", "").ifEmpty { "Shortcut" }
                list.add(Shortcut(id, name, codes, label))
            }
            if (list.isEmpty()) defaultShortcuts() else list
        } catch (_: Exception) {
            defaultShortcuts()
        }
    }

    private fun defaultShortcuts(): List<Shortcut> = listOf(
        Shortcut(
            id = "close_app",
            name = "Close app",
            moonlightKeyCodes = listOf(0x805B, 0x8051),
            keyLabel = "Command + Q",
        ),
    )

    private fun parseKeyCodes(item: JSONObject): List<Int> {
        if (!item.has("moonlightKeyCodes")) return emptyList()
        val arr = item.optJSONArray("moonlightKeyCodes") ?: return emptyList()
        return (0 until arr.length()).mapNotNull { idx ->
            val code = arr.optInt(idx, 0)
            code.takeIf { it != 0 }
        }
    }
}

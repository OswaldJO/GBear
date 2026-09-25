package com.example.companion_app

import android.content.Context
import android.util.Log

/** Best-effort notification shade collapse; never throws (system APIs are restricted on modern Android). */
object NotificationShadeUtils {
    private const val TAG = "GBearNotification"

    fun collapse(context: Context) {
        try {
            val statusBarService = context.getSystemService("statusbar") ?: return
            val clazz = Class.forName("android.app.StatusBarManager")
            val collapsePanels = clazz.getMethod("collapsePanels")
            collapsePanels.invoke(statusBarService)
        } catch (e: Exception) {
            // Reflection and CLOSE_SYSTEM_DIALOGS are blocked on Android 12+ for normal apps.
            Log.d(TAG, "Could not collapse notification shade: ${e.message}")
        }
    }
}

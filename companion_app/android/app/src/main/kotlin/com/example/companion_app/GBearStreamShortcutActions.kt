package com.example.companion_app

import android.content.Context
import android.content.Intent

object GBearStreamShortcutActions {
    const val EXTRA_OPEN_SHORTCUTS = "openStreamShortcuts"

    fun openShortcutsUi(context: Context) {
        val appContext = context.applicationContext
        val video = GBearVideoActivity.current
        if (video != null && !video.isFinishing) {
            video.runOnUiThread { video.showStreamShortcutsOverlay() }
            return
        }
        val launch = Intent(appContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            putExtra(EXTRA_OPEN_SHORTCUTS, true)
        }
        appContext.startActivity(launch)
    }
}

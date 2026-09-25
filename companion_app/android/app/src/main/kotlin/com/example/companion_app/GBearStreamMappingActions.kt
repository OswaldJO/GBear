package com.example.companion_app

import android.content.Context
import android.content.Intent

object GBearStreamMappingActions {
    const val EXTRA_OPEN_MAPPING = "openControllerMapping"

    fun openMappingUi(context: Context) {
        val video = GBearVideoActivity.current
        if (video != null) {
            video.runOnUiThread { video.showControllerMappingOverlay() }
            return
        }
        val launch = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(EXTRA_OPEN_MAPPING, true)
        }
        context.startActivity(launch)
    }
}

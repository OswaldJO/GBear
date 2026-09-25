package com.example.companion_app

import android.content.Context
import android.widget.Toast

object GBearStreamSwapActions {
    fun toggle(context: Context) {
        if (!GBearStreamSession.hostStreamActive) return
        val wasActive = GBearStreamSession.swapMouseModeActive
        // Release keys held from prior mappings so Enter/modifiers are not stuck on the Mac.
        GBearStreamSession.keyboardSender()?.releaseAllKeys()
        GBearStreamSession.swapMouseModeActive = !wasActive
        if (!GBearStreamSession.swapMouseModeActive) {
            GBearVideoActivity.current?.onSwapMouseModeDisabled()
        } else {
            GBearVideoActivity.current?.gamepadMouseSender()?.releaseAll()
        }
        GBearStreamNotificationHelper.refresh(context)
        GBearStreamLog.i(
            if (GBearStreamSession.swapMouseModeActive) {
                "Swap on — stick moves cursor; A/B/X click and drag; other mappings still active"
            } else {
                "Swap off — controller mappings restored"
            },
        )
        val message = if (GBearStreamSession.swapMouseModeActive) {
            "Swap on — stick moves cursor, A/B/X click and drag"
        } else {
            "Swap off — using Controller tab mappings"
        }
        Toast.makeText(context.applicationContext, message, Toast.LENGTH_SHORT).show()
    }
}

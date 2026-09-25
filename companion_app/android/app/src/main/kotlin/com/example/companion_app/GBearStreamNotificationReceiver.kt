package com.example.companion_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class GBearStreamNotificationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            GBearStreamNotificationHelper.ACTION_MAPPING ->
                GBearStreamMappingActions.openMappingUi(context)

            GBearStreamNotificationHelper.ACTION_SHORTCUTS ->
                GBearStreamShortcutActions.openShortcutsUi(context)

            GBearStreamNotificationHelper.ACTION_STOP ->
                GBearStreamStopCoordinator.stopSession(context, notifyFlutter = true)

            GBearStreamNotificationHelper.ACTION_SWAP ->
                GBearStreamSwapActions.toggle(context)
        }
        // After launching UI; best-effort only — must not crash if blocked by the OS.
        NotificationShadeUtils.collapse(context)
    }
}

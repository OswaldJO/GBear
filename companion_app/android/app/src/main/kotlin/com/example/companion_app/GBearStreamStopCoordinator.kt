package com.example.companion_app

import android.content.Context

/**
 * Single stop path for Session tab Stop and notification Stop so teardown stays consistent.
 */
object GBearStreamStopCoordinator {
    data class StopResult(val logPath: String?)

    /**
     * @param notifyFlutter When true, tells Flutter the session ended outside the video UI (notification Stop).
     */
    fun stopSession(context: Context, notifyFlutter: Boolean): StopResult {
        val app = context.applicationContext
        val host = GBearStreamSession.host
        GBearStreamSession.deactivate()
        GBearStreamNotificationHelper.dismiss(app)
        GBearStreamSession.clearPendingExternalStopLog()
        val video = GBearVideoActivity.current
        if (video != null) {
            video.finishFromHost()
        } else {
            GBearStreamSession.clear()
            GBearStreamLog.endSession("stop requested from companion")
        }
        if (host.isNotEmpty()) {
            val macStop = Thread {
                GBearHostControlClient.stopStreamOnHost(host)
            }
            macStop.start()
            macStop.join(8_000)
        }
        val logPath = GBearStreamLog.logFilePath(app)
        if (notifyFlutter) {
            MainActivity.notifyFlutterStreamStoppedExternally()
        }
        return StopResult(logPath)
    }
}

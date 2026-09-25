package com.example.companion_app

import android.content.Context
import android.os.Handler
import android.os.Looper

/** Stops the Mac host stream, native video session, and stream notification. */
object GBearStreamStopper {
    private val mainHandler = Handler(Looper.getMainLooper())

    fun stopAll(
        context: Context,
        reason: String,
        blockUntilMacStop: Boolean = false,
        recordPendingLogForResume: Boolean = false,
    ) {
        val app = context.applicationContext
        val host = GBearStreamSession.host
        GBearStreamSession.deactivate()
        GBearStreamNotificationHelper.dismiss(app)
        val macStop = Thread {
            if (host.isNotEmpty()) {
                GBearHostControlClient.stopStreamOnHost(host)
            }
        }
        macStop.start()
        if (blockUntilMacStop) {
            macStop.join()
        }
        val video = GBearVideoActivity.current
        if (video != null) {
            mainHandler.post {
                video.finishFromHost()
                if (recordPendingLogForResume) {
                    GBearStreamSession.recordExternalStopLog(app)
                }
            }
        } else {
            GBearStreamSession.clear()
            GBearStreamLog.endSession(reason)
            if (recordPendingLogForResume) {
                GBearStreamSession.recordExternalStopLog(app)
            }
        }
    }
}

package com.example.companion_app

/**
 * Last native stream connection parameters. [hostStreamActive] stays true after the user
 * leaves [PlayniteVideoActivity] with Back until they tap Stop in the companion app.
 */
object PlayniteStreamSession {
    @Volatile var hostStreamActive: Boolean = false
    @Volatile var viewerOpen: Boolean = false

    /** Notification **Swap**: gamepad drives Mac mouse instead of keyboard mappings. */
    @Volatile var swapMouseModeActive: Boolean = false

    /**
     * Set while [PlayniteVideoActivity] closes via Back (viewer only). Suppresses Mac `stream/stop` in
     * [PlayniteVideoActivity.onDestroy] so **Resume stream view** can reconnect to the same host session.
     */
    @Volatile var leaveViewerWithoutMacStop: Boolean = false

    /**
     * Bumped on each Session Stop and each new [startStream]. Background Mac stops only run when
     * their captured generation still matches (avoids a late stop killing the next stream).
     */
    @Volatile
    private var macStopGeneration: Long = 0L

    /** Call when starting a new stream so an in-flight stop from the prior session is ignored. */
    fun cancelPendingMacStop() {
        macStopGeneration += 1
    }

    /** Schedules a background [PlayniteHostControlClient.stopStreamOnHost] (see [shouldRunBackgroundMacStop]). */
    fun scheduleBackgroundMacStop(): Long {
        macStopGeneration += 1
        return macStopGeneration
    }

    fun shouldRunBackgroundMacStop(generation: Long): Boolean = generation == macStopGeneration

    /** Set when stream ends outside Session UI (notification Stop); Flutter reads via [toMap]. */
    @Volatile var pendingExternalStopLogPath: String? = null

    /** Set by [MainActivity] before launching [PlayniteVideoActivity]; cleared after connect result. */
    @Volatile
    var pendingVideoConnectCallback: ((Boolean) -> Unit)? = null

    fun reportVideoConnectResult(success: Boolean) {
        val callback = pendingVideoConnectCallback
        pendingVideoConnectCallback = null
        callback?.invoke(success)
    }

    var host: String = ""
    var videoPort: Int = 28766
    var audioPort: Int = 28767
    var audioTcpPort: Int = 28769
    var inputPort: Int = 28768
    var width: Int = 1920
    var height: Int = 1080
    var cursorSpeed: Float = 1f
    var swapStickSensitivity: Float = 0.05f
    var tapSlopPercent: Int = 100
    var tapTimeoutMs: Long = PlayniteInputSender.TAP_TIMEOUT_MS
    var tapPressure: Float = 0.35f
    var controllerBindingsJson: String = ""
    /** Co-op seat 1…8 for PNG1 virtual pads. */
    var seat: Int = 1
    /** When true, send PNG1 gamepad state instead of keyboard chords. */
    var coopPadMode: Boolean = true
    var swapFaceButtons: Boolean = false
    var deadZonePercent: Int = 12
    var appContext: android.content.Context? = null

    @Volatile
    private var keyboardSender: PlayniteKeyboardSender? = null
    @Volatile
    private var gamepadSender: PlayniteGamepadSender? = null

    /** Shared UDP keyboard client for shortcuts and gamepad mapping for the active stream. */
    fun keyboardSender(): PlayniteKeyboardSender? {
        if (!hostStreamActive || host.isEmpty()) return null
        val existing = keyboardSender
        if (existing != null) return existing
        return PlayniteKeyboardSender(host, inputPort).also { keyboardSender = it }
    }

    fun gamepadSender(): PlayniteGamepadSender? {
        if (!hostStreamActive || host.isEmpty() || !coopPadMode) return null
        val existing = gamepadSender
        if (existing != null) return existing
        return PlayniteGamepadSender(
            host,
            inputPort,
            seat.coerceIn(1, 8),
            appContext = appContext,
            swapFaceButtons = swapFaceButtons,
            deadzone = (deadZonePercent.coerceIn(0, 40) / 100f).coerceAtLeast(0.04f),
        ).also { gamepadSender = it }
    }

    fun releaseKeyboardSender() {
        keyboardSender?.close()
        keyboardSender = null
    }

    fun releaseGamepadSender() {
        gamepadSender?.close()
        gamepadSender = null
    }

    fun applyFromIntent(intent: android.content.Intent) {
        host = intent.getStringExtra(PlayniteVideoActivity.EXTRA_HOST).orEmpty()
        videoPort = intent.getIntExtra(PlayniteVideoActivity.EXTRA_VIDEO_PORT, 28766)
        audioPort = intent.getIntExtra(PlayniteVideoActivity.EXTRA_AUDIO_PORT, 28767)
        audioTcpPort = intent.getIntExtra(PlayniteVideoActivity.EXTRA_AUDIO_TCP_PORT, 28769)
        inputPort = intent.getIntExtra(PlayniteVideoActivity.EXTRA_INPUT_PORT, 28768)
        width = intent.getIntExtra(PlayniteVideoActivity.EXTRA_WIDTH, 1920)
        height = intent.getIntExtra(PlayniteVideoActivity.EXTRA_HEIGHT, 1080)
        cursorSpeed = intent.getFloatExtra(PlayniteVideoActivity.EXTRA_CURSOR_SPEED, 1f)
        swapStickSensitivity =
            intent.getFloatExtra(PlayniteVideoActivity.EXTRA_SWAP_STICK_SENSITIVITY, 0.05f)
        tapSlopPercent = intent.getIntExtra(PlayniteVideoActivity.EXTRA_TAP_SLOP_PERCENT, 100)
        tapTimeoutMs = intent.getLongExtra(
            PlayniteVideoActivity.EXTRA_TAP_TIMEOUT_MS,
            PlayniteInputSender.TAP_TIMEOUT_MS,
        )
        tapPressure = intent.getFloatExtra(PlayniteVideoActivity.EXTRA_TAP_PRESSURE, 0.35f)
        controllerBindingsJson =
            intent.getStringExtra(PlayniteVideoActivity.EXTRA_CONTROLLER_BINDINGS_JSON).orEmpty()
        seat = intent.getIntExtra(PlayniteVideoActivity.EXTRA_SEAT, 1).coerceIn(1, 8)
        coopPadMode = intent.getBooleanExtra(PlayniteVideoActivity.EXTRA_COOP_PAD_MODE, true)
        swapFaceButtons = intent.getBooleanExtra(PlayniteVideoActivity.EXTRA_SWAP_FACE, false)
        deadZonePercent = intent.getIntExtra(PlayniteVideoActivity.EXTRA_DEADZONE, 12)
        releaseGamepadSender()
    }

    fun toIntentFlags(intent: android.content.Intent) {
        intent.putExtra(PlayniteVideoActivity.EXTRA_HOST, host)
        intent.putExtra(PlayniteVideoActivity.EXTRA_VIDEO_PORT, videoPort)
        intent.putExtra(PlayniteVideoActivity.EXTRA_AUDIO_PORT, audioPort)
        intent.putExtra(PlayniteVideoActivity.EXTRA_AUDIO_TCP_PORT, audioTcpPort)
        intent.putExtra(PlayniteVideoActivity.EXTRA_INPUT_PORT, inputPort)
        intent.putExtra(PlayniteVideoActivity.EXTRA_WIDTH, width)
        intent.putExtra(PlayniteVideoActivity.EXTRA_HEIGHT, height)
        intent.putExtra(PlayniteVideoActivity.EXTRA_CURSOR_SPEED, cursorSpeed)
        intent.putExtra(PlayniteVideoActivity.EXTRA_SWAP_STICK_SENSITIVITY, swapStickSensitivity)
        intent.putExtra(PlayniteVideoActivity.EXTRA_TAP_SLOP_PERCENT, tapSlopPercent)
        intent.putExtra(PlayniteVideoActivity.EXTRA_TAP_TIMEOUT_MS, tapTimeoutMs)
        intent.putExtra(PlayniteVideoActivity.EXTRA_TAP_PRESSURE, tapPressure)
        intent.putExtra(PlayniteVideoActivity.EXTRA_CONTROLLER_BINDINGS_JSON, controllerBindingsJson)
        intent.putExtra(PlayniteVideoActivity.EXTRA_SEAT, seat)
        intent.putExtra(PlayniteVideoActivity.EXTRA_COOP_PAD_MODE, coopPadMode)
        intent.putExtra(PlayniteVideoActivity.EXTRA_SWAP_FACE, swapFaceButtons)
        intent.putExtra(PlayniteVideoActivity.EXTRA_DEADZONE, deadZonePercent)
    }

    /**
     * Marks the stream inactive immediately (notification Stop, host teardown).
     * Keeps [host] so [PlayniteHostControlClient] can still POST stream/stop.
     */
    fun deactivate() {
        // Drop callback without invoking — reportVideoConnectResult(false) would re-enter stopAll.
        pendingVideoConnectCallback = null
        hostStreamActive = false
        viewerOpen = false
        swapMouseModeActive = false
        releaseKeyboardSender()
        releaseGamepadSender()
    }

    fun clear() {
        deactivate()
        host = ""
        controllerBindingsJson = ""
        seat = 1
        coopPadMode = true
    }

    fun recordExternalStopLog(context: android.content.Context) {
        pendingExternalStopLogPath = PlayniteStreamLog.logFilePath(context)
    }

    fun clearPendingExternalStopLog() {
        pendingExternalStopLogPath = null
    }

    fun toMap(): Map<String, Any?> = mapOf(
        "hostStreamActive" to hostStreamActive,
        "viewerOpen" to viewerOpen,
        "pendingExternalStopLogPath" to pendingExternalStopLogPath,
        "host" to host,
        "videoPort" to videoPort,
        "audioPort" to audioPort,
        "audioTcpPort" to audioTcpPort,
        "inputPort" to inputPort,
        "width" to width,
        "height" to height,
        "seat" to seat,
        "coopPadMode" to coopPadMode,
        "swapFaceButtons" to swapFaceButtons,
        "deadZonePercent" to deadZonePercent,
    )
}

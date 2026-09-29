package com.example.companion_app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.MotionEvent
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.util.concurrent.atomic.AtomicBoolean
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.gbear.companion/streaming_bridge"
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        const val EXTRA_STREAM_STOPPED_EXTERNAL = "gbear_stream_stopped_external"

        @Volatile
        var pendingOpenMapping: Boolean = false

        @Volatile
        var pendingOpenShortcuts: Boolean = false

        @Volatile
        private var streamChannel: MethodChannel? = null

        @Volatile
        private var appContext: android.content.Context? = null

        @Volatile
        private var pendingNotifyFlutterStreamStopped = false

        private val notifyFlutterHandler = Handler(Looper.getMainLooper())

        private var pendingStopNotifyRunnable: Runnable? = null

        private const val REQUEST_POST_NOTIFICATIONS = 9001

        /** Cancels a delayed stop notify so a new start is not overwritten with "Stream stopped". */
        fun cancelPendingFlutterStreamStoppedNotify() {
            pendingStopNotifyRunnable?.let { notifyFlutterHandler.removeCallbacks(it) }
            pendingStopNotifyRunnable = null
            pendingNotifyFlutterStreamStopped = false
        }

        /** Notifies Flutter that the stream was stopped outside the session UI (e.g. notification). */
        fun notifyFlutterStreamStoppedExternally() {
            cancelPendingFlutterStreamStoppedNotify()
            notifyFlutterHandler.post { dispatchFlutterStreamStoppedExternally() }
        }

        private fun dispatchFlutterStreamStoppedExternally() {
            if (GBearStreamSession.hostStreamActive) return
            val channel = streamChannel
            if (channel == null) {
                pendingNotifyFlutterStreamStopped = true
                return
            }
            pendingNotifyFlutterStreamStopped = false
            val ctx = appContext
            val logPath = ctx?.let { GBearStreamLog.logFilePath(it) }
            val payload: Map<String, String>? =
                if (logPath != null) hashMapOf("logPath" to logPath) else null
            channel.invokeMethod("onStreamStoppedExternally", payload)
        }

        private fun flushPendingFlutterStreamStopped() {
            if (pendingNotifyFlutterStreamStopped) {
                dispatchFlutterStreamStoppedExternally()
            }
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        volumeControlStream = AudioManager.STREAM_MUSIC
    }

    override fun onDestroy() {
        val host = GBearStreamSession.host
        if (host.isNotEmpty() && GBearStreamSession.hostStreamActive) {
            Thread { GBearHostControlClient.stopStreamOnHost(host) }.start()
        }
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        appContext = applicationContext
        streamChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        streamChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "discoverHosts" -> result.success(emptyList<Map<String, Any>>())

                "pairWithPin" -> result.success(true)

                "getStreamSession" -> result.success(GBearStreamSession.toMap())

                "clearPendingExternalStopLog" -> {
                    GBearStreamSession.clearPendingExternalStopLog()
                    result.success(null)
                }

                "startStream" -> {
                    val host = call.argument<String>("host").orEmpty()
                    if (host.isEmpty()) {
                        result.error("invalid_args", "Missing host", null)
                        return@setMethodCallHandler
                    }
                    GBearRelayBridge.stop()
                    GBearStreamSession.host = host
                    GBearStreamSession.videoPort = call.argument<Int>("videoPort") ?: 28766
                    GBearStreamSession.audioPort = call.argument<Int>("audioPort") ?: 28767
                    GBearStreamSession.audioTcpPort = call.argument<Int>("audioTcpPort") ?: 28769
                    GBearStreamSession.inputPort = call.argument<Int>("inputPort") ?: 28768
                    GBearStreamSession.width = call.argument<Int>("width") ?: 1920
                    GBearStreamSession.height = call.argument<Int>("height") ?: 1080
                    GBearStreamSession.seat = (call.argument<Int>("seat") ?: 1).coerceIn(1, 8)
                    applyPlayerSettings(call)
                    beginStreamSession()
                    launchStreamActivity(result)
                }

                "startRelayStream" -> {
                    val relayUrl = call.argument<String>("relayUrl").orEmpty()
                    val deviceId = call.argument<String>("deviceId").orEmpty()
                    if (relayUrl.isEmpty() || deviceId.isEmpty()) {
                        result.error("invalid_args", "Missing relay address", null)
                        return@setMethodCallHandler
                    }
                    GBearRelayBridge.start(
                        applicationContext,
                        url = relayUrl,
                        deviceId = deviceId,
                        deviceName = call.argument<String>("deviceName").orEmpty().ifEmpty { "Android phone" },
                        preferredSeat = call.argument<Int>("preferredSeat") ?: 0,
                    ) { outcome ->
                        when (outcome) {
                            is GBearRelayBridge.JoinResult.Failed ->
                                result.error("relay_failed", outcome.message, null)
                            is GBearRelayBridge.JoinResult.Joined -> {
                                GBearStreamSession.host = GBearRelayBridge.LOOPBACK_HOST
                                GBearStreamSession.videoPort = GBearRelayBridge.videoPort
                                GBearStreamSession.audioPort = GBearRelayBridge.audioTcpPort
                                GBearStreamSession.audioTcpPort = GBearRelayBridge.audioTcpPort
                                GBearStreamSession.inputPort = GBearRelayBridge.inputPort
                                GBearStreamSession.width = 1280
                                GBearStreamSession.height = 720
                                GBearStreamSession.seat = outcome.seat
                                applyPlayerSettings(call)
                                beginStreamSession()
                                launchStreamActivity(result)
                            }
                        }
                    }
                }

                "resumeStream" -> {
                    if (!GBearStreamSession.hostStreamActive || GBearStreamSession.host.isEmpty()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    if (GBearVideoActivity.current != null) {
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    GBearStreamSession.cancelPendingMacStop()
                    GBearStreamSession.leaveViewerWithoutMacStop = false
                    GBearStreamSession.hostStreamActive = true
                    launchStreamActivity(result)
                }

                "prepareForNewStream" -> {
                    GBearStreamSession.cancelPendingMacStop()
                    GBearStreamSession.swapMouseModeActive = false
                    GBearStreamSession.keyboardSender()?.releaseAllKeys()
                    val video = GBearVideoActivity.current
                    if (video != null) {
                        video.runOnUiThread { video.finishFromHost() }
                    } else if (GBearStreamSession.hostStreamActive) {
                        GBearStreamSession.deactivate()
                        GBearStreamNotificationHelper.dismiss(applicationContext)
                    }
                    result.success(null)
                }

                "stopStream" -> runOnUiThread { completeStopStreamFromSession(result) }

                "updateSwapStickSensitivity" -> {
                    val value =
                        (call.argument<Double>("swapStickSensitivity") ?: 0.05).toFloat()
                            .coerceIn(0.05f, 1f)
                    GBearStreamSession.swapStickSensitivity = value
                    GBearVideoActivity.current?.updateSwapStickSensitivity(value)
                    result.success(null)
                }

                "showStreamMappingOverlay" -> {
                    val video = GBearVideoActivity.current
                    if (video != null) {
                        video.runOnUiThread { video.showControllerMappingOverlay() }
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }

                "consumePendingOpenMapping" -> {
                    val pending = pendingOpenMapping
                    pendingOpenMapping = false
                    result.success(pending)
                }

                "showStreamShortcutsOverlay" -> {
                    val video = GBearVideoActivity.current
                    if (video != null) {
                        video.runOnUiThread { video.showStreamShortcutsOverlay() }
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }

                "consumePendingOpenShortcuts" -> {
                    val pending = pendingOpenShortcuts
                    pendingOpenShortcuts = false
                    result.success(pending)
                }

                "fireStreamShortcut" -> {
                    val codes = call.argument<List<Int>>("moonlightKeyCodes")?.filter { it != 0 }.orEmpty()
                    val sender = GBearStreamSession.keyboardSender()
                    if (!GBearStreamSession.hostStreamActive || codes.isEmpty() || sender == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    GBearStreamLog.i(
                        "Shortcut fire ${codes.size} keys → ${GBearStreamSession.host}:${GBearStreamSession.inputPort}",
                    )
                    sender.sendChord(codes, down = true)
                    mainHandler.postDelayed({
                        sender.sendChord(codes, down = false)
                    }, 140L)
                    result.success(true)
                }

                "syncStreamNotification" -> {
                    val active = call.argument<Boolean>("active") == true
                    val host = call.argument<String>("host").orEmpty()
                    if (active) {
                        ensureNotificationPermissionForStream()
                        GBearStreamNotificationHelper.show(
                            this,
                            host.ifEmpty { GBearStreamSession.host },
                        )
                    } else {
                        GBearStreamNotificationHelper.dismiss(this)
                    }
                    result.success(null)
                }

                "listConnectedControllers" -> {
                    result.success(ConnectedControllerProbe.list(this))
                }

                "autoMapCoopPads" -> {
                    val swap = call.argument<Boolean>("swapFaceButtons") ?: false
                    result.success(GBearCoopPadMappingStore.autoMapAndSave(this, swap))
                }

                "listCoopPadMappings" -> {
                    result.success(GBearCoopPadMappingStore.all(this))
                }

                "resetCoopPadMapping" -> {
                    val guid = call.argument<String>("guid").orEmpty()
                    if (guid.isNotEmpty()) {
                        GBearCoopPadMappingStore.reset(this, guid)
                    }
                    result.success(null)
                }

                "applyCoopPadOverride" -> {
                    val guid = call.argument<String>("guid").orEmpty()
                    val logical = call.argument<String>("logical").orEmpty()
                    val keyCode = call.argument<Int>("keyCode") ?: 0
                    val axis = call.argument<Int>("axis") ?: -1
                    val invert = call.argument<Boolean>("invert") ?: false
                    val deviceName = call.argument<String>("deviceName").orEmpty()
                    if (guid.isEmpty() || logical.isEmpty()) {
                        result.error("invalid_args", "guid and logical required", null)
                        return@setMethodCallHandler
                    }
                    val mapping = GBearCoopPadMappingStore.applyOverride(
                        this,
                        guid,
                        logical,
                        keyCode,
                        axis,
                        invert,
                        deviceName,
                    )
                    result.success(mapping.toMap())
                }

                "awaitGamepadButtonPress" -> {
                    val timeoutMs = call.argument<Int>("timeoutMs") ?: 15_000
                    val targetElementId = call.argument<String>("elementId").orEmpty()
                    val completed = AtomicBoolean(false)
                    if (!GamepadLinkCapture.beginListening(targetElementId) { captured ->
                        if (!completed.compareAndSet(false, true)) return@beginListening
                        mainHandler.post {
                            result.success(
                                hashMapOf(
                                    "keyCode" to captured.keyCode,
                                    "label" to captured.label,
                                    "elementId" to captured.elementId,
                                    "guid" to captured.guid,
                                    "deviceName" to captured.deviceName,
                                ),
                            )
                        }
                    }) {
                        result.error("busy", "Already waiting for a gamepad button", null)
                        return@setMethodCallHandler
                    }
                    mainHandler.postDelayed({
                        if (!completed.compareAndSet(false, true)) return@postDelayed
                        GamepadLinkCapture.cancel()
                        result.error(
                            "timeout",
                            "No gamepad input detected — press a button, D-pad, or push a stick",
                            null,
                        )
                    }, timeoutMs.toLong())
                }

                "cancelGamepadButtonPress" -> {
                    GamepadLinkCapture.cancel()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
        flushPendingFlutterStreamStopped()
    }

    override fun onResume() {
        super.onResume()
        deliverPendingExternalStreamStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getBooleanExtra(GBearStreamMappingActions.EXTRA_OPEN_MAPPING, false)) {
            pendingOpenMapping = true
        }
        if (intent.getBooleanExtra(GBearStreamShortcutActions.EXTRA_OPEN_SHORTCUTS, false)) {
            pendingOpenShortcuts = true
        }
        deliverPendingExternalStreamStop()
    }

    private fun deliverPendingExternalStreamStop() {
        val intent = intent ?: return
        if (!intent.getBooleanExtra(EXTRA_STREAM_STOPPED_EXTERNAL, false)) return
        intent.removeExtra(EXTRA_STREAM_STOPPED_EXTERNAL)
        // Flutter syncs session + log offer on resume via getStreamSession (MainActivity was stopped during video).
    }

    /** Session-tab Stop — same teardown as notification Stop ([GBearStreamStopCoordinator]). */
    private fun completeStopStreamFromSession(result: MethodChannel.Result) {
        val stop = GBearStreamStopCoordinator.stopSession(applicationContext, notifyFlutter = false)
        result.success(hashMapOf("logPath" to (stop.logPath ?: "")))
    }

    private fun applyPlayerSettings(call: MethodCall) {
        GBearStreamSession.cursorSpeed = (call.argument<Double>("cursorSpeed") ?: 1.0).toFloat()
        GBearStreamSession.swapStickSensitivity =
            (call.argument<Double>("swapStickSensitivity") ?: 0.05).toFloat()
        GBearStreamSession.tapSlopPercent = call.argument<Int>("tapSlopPercent") ?: 100
        GBearStreamSession.tapTimeoutMs = call.argument<Int>("tapTimeoutMs")?.toLong()
            ?: GBearInputSender.TAP_TIMEOUT_MS
        GBearStreamSession.tapPressure = (call.argument<Double>("tapPressure") ?: 0.35).toFloat()
        GBearStreamSession.controllerBindingsJson = call.argument<String>("controllerBindingsJson").orEmpty()
        GBearStreamSession.coopPadMode = call.argument<Boolean>("coopPadMode") ?: true
        GBearStreamSession.swapFaceButtons = call.argument<Boolean>("swapFaceButtons") ?: false
        GBearStreamSession.deadZonePercent = call.argument<Int>("deadZonePercent") ?: 12
        GBearStreamSession.appContext = applicationContext
        GBearStreamSession.releaseGamepadSender()
    }

    private fun beginStreamSession() {
        cancelPendingFlutterStreamStoppedNotify()
        GBearStreamSession.clearPendingExternalStopLog()
        GBearStreamSession.cancelPendingMacStop()
        GBearStreamSession.hostStreamActive = true
    }

    private fun launchStreamActivity(result: MethodChannel.Result) {
        ensureNotificationPermissionForStream()
        GBearStreamNotificationHelper.show(this, GBearStreamSession.host)
        val intent = Intent(this, GBearVideoActivity::class.java)
        GBearStreamSession.toIntentFlags(intent)
        val resultDelivered = java.util.concurrent.atomic.AtomicBoolean(false)
        val connectTimeoutMs = 22_000L
        val timeoutRunnable = Runnable {
            if (!resultDelivered.compareAndSet(false, true)) return@Runnable
            GBearStreamSession.pendingVideoConnectCallback = null
            GBearStreamStopper.stopAll(
                applicationContext,
                "video connect timed out waiting for Mac TCP",
                recordPendingLogForResume = true,
            )
            runOnUiThread { result.success(false) }
        }
        mainHandler.postDelayed(timeoutRunnable, connectTimeoutMs)
        GBearStreamSession.pendingVideoConnectCallback = connect@{ ok ->
            mainHandler.removeCallbacks(timeoutRunnable)
            if (!resultDelivered.compareAndSet(false, true)) return@connect
            // On failure, [GBearVideoActivity.handleConnectFailure] already called [stopAll].
            runOnUiThread { result.success(ok) }
        }
        startActivity(intent)
        // MethodChannel result completes after TCP connect (or timeout), not immediately.
    }

    private fun ensureNotificationPermissionForStream() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_POST_NOTIFICATIONS,
        )
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (GamepadInputFilter.isSystemVolumeOrNavigationKey(event.keyCode)) {
            return super.dispatchKeyEvent(event)
        }
        if (GamepadLinkCapture.tryConsume(event)) {
            return true
        }
        if (GamepadInputFilter.isGamepadKey(event)) {
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if (GamepadLinkCapture.tryConsumeMotion(event)) {
            return true
        }
        if (GamepadInputFilter.isGamepadMotion(event)) {
            return true
        }
        return super.dispatchGenericMotionEvent(event)
    }
}

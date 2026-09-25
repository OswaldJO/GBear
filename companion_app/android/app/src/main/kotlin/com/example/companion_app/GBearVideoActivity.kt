package com.example.companion_app

import android.app.Activity
import android.graphics.Color
import android.media.AudioManager
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.KeyEvent
import android.view.WindowManager
import android.widget.FrameLayout
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Full-screen H.264 receiver for GBear `GBV1` frames over TCP.
 */
class GBearVideoActivity : Activity(), SurfaceHolder.Callback {
    private lateinit var surfaceView: SurfaceView
    private var renderSurface: Surface? = null
    private var decoder: MediaCodec? = null
    private var socket: Socket? = null
    private val running = AtomicBoolean(false)
    private var streamThread: Thread? = null
    private var codecThread: HandlerThread? = null
    private var codecHandler: Handler? = null
    private val surfaceReady = CountDownLatch(1)
    @Volatile private var surfaceValid = false

    private var configuredWidth = 1920
    private var configuredHeight = 1080
    private var decoderConfigured = false
    private var presentationUs = 0L
    private val frameDurationUs = 16_667L

    private var cachedSps: ByteArray? = null
    private var cachedPps: ByteArray? = null
    private var needsIdrFrame = true
    private var framesReceived = 0
    private var framesQueued = 0
    @Volatile private var framesRendered = 0
    private var framesDropped = 0
    private var outputBuffersSeen = 0
    private var streamConnectedAt = 0L
    @Volatile private var logSessionEnded = false
    private var loggedDecoderStall = false
    private var loggedAvccFallback = false

    private var decodeProfileIndex = 0

    private var streamHost = ""
    private var audioPort = 28767
    private var audioTcpPort = 28769
    private var inputPort = 28768
    private var audioReceiver: GBearAudioReceiver? = null
    private var inputSender: GBearInputSender? = null
    private var keyboardSender: GBearKeyboardSender? = null
    private var gamepadMapping: GBearGamepadMapping? = null
    private var gamepadMappingJsonCache: String? = null
    private var gamepadMouseSender: GBearGamepadMouseSender? = null
    private var mappingOverlay: GBearControllerMappingOverlay? = null
    private var shortcutsOverlay: GBearStreamShortcutsOverlay? = null

    private val frameQueue = LinkedBlockingQueue<IncomingFrame>(128)

    private data class IncomingFrame(
        val payload: ByteArray,
        val isKeyframe: Boolean,
        val width: Int,
        val height: Int,
    )

    private enum class FeedMode {
        /** csd-0 avcC + length-prefixed slice NALs only (no in-band SPS/PPS). */
        AvccCsdSliceOnly, // slice-only AVCC when csd-0 is set
        /** Pass Mac Annex-B access units unchanged (no csd in MediaFormat). */
        AnnexBPassthrough,
        /** Annex-B SPS/PPS as CODEC_CONFIG buffer, then slice/IDR. */
        AnnexBSplitConfig,
    }

    private data class DecodeProfile(
        val codecNames: List<String>,
        val feedMode: FeedMode,
        val label: String,
    )

    private val decodeProfiles = buildDecodeProfiles()

    private fun buildDecodeProfiles(): List<DecodeProfile> {
        val software = listOf(
            "c2.android.avc.decoder",
            "OMX.google.h264.decoder",
        )
        val any = listOf(
            "c2.android.avc.decoder",
            "OMX.google.h264.decoder",
            "c2.qti.avc.decoder",
        )
        return listOf(
            DecodeProfile(software, FeedMode.AnnexBPassthrough, "annex-b+c2/omx"),
            DecodeProfile(software, FeedMode.AnnexBSplitConfig, "annex-b-split+c2/omx"),
            DecodeProfile(software, FeedMode.AvccCsdSliceOnly, "avcc-csd+c2/omx"),
            DecodeProfile(any, FeedMode.AnnexBPassthrough, "annex-b+any"),
            DecodeProfile(any, FeedMode.AvccCsdSliceOnly, "avcc-csd+any"),
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        volumeControlStream = AudioManager.STREAM_MUSIC
        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_FULLSCREEN,
        )

        streamHost = intent.getStringExtra(EXTRA_HOST).orEmpty()
        val port = intent.getIntExtra(EXTRA_VIDEO_PORT, 28766)
        audioPort = intent.getIntExtra(EXTRA_AUDIO_PORT, 28767)
        audioTcpPort = intent.getIntExtra(EXTRA_AUDIO_TCP_PORT, 28769)
        inputPort = intent.getIntExtra(EXTRA_INPUT_PORT, 28768)
        val cursorSpeed = intent.getFloatExtra(EXTRA_CURSOR_SPEED, 1f)
        val swapStickSensitivity =
            intent.getFloatExtra(EXTRA_SWAP_STICK_SENSITIVITY, 0.05f).coerceIn(0.05f, 1f)
        val tapSlopPercent = intent.getIntExtra(EXTRA_TAP_SLOP_PERCENT, 100)
        val tapTimeoutMs = intent.getLongExtra(EXTRA_TAP_TIMEOUT_MS, GBearInputSender.TAP_TIMEOUT_MS)
        val tapPressure = intent.getFloatExtra(EXTRA_TAP_PRESSURE, 0.35f)
        configuredWidth = intent.getIntExtra(EXTRA_WIDTH, 1920)
        configuredHeight = intent.getIntExtra(EXTRA_HEIGHT, 1080)

        if (streamHost.isEmpty()) {
            finish()
            return
        }

        GBearStreamSession.applyFromIntent(intent)
        GBearStreamSession.hostStreamActive = true
        GBearStreamSession.viewerOpen = true

        val bindingsJson = intent.getStringExtra(EXTRA_CONTROLLER_BINDINGS_JSON).orEmpty()
        gamepadMapping = GBearGamepadMapping(bindingsJson).takeIf { it.hasBindings() }
        keyboardSender = GBearStreamSession.keyboardSender()

        current = this
        logSessionEnded = false
        loggedDecoderStall = false
        loggedAvccFallback = false
        GBearStreamLog.startSession(applicationContext, streamHost, port, configuredWidth, configuredHeight)

        surfaceView = SurfaceView(this)
        surfaceView.holder.addCallback(this)
        val touchSlop = android.view.ViewConfiguration.get(this).scaledTouchSlop.toFloat() *
            (tapSlopPercent.coerceIn(50, 200) / 100f)
        val sensitivity = cursorSpeed.coerceIn(0.25f, 3f)
        inputSender = GBearInputSender(
            host = streamHost,
            port = inputPort,
            viewWidth = { surfaceView.width.coerceAtLeast(1) },
            viewHeight = { surfaceView.height.coerceAtLeast(1) },
            touchSlopPx = touchSlop,
            cursorSensitivity = sensitivity,
            tapTimeoutMs = tapTimeoutMs.coerceIn(150L, 800L),
            minTapPressure = tapPressure.coerceIn(0.1f, 0.9f),
        )
        gamepadMouseSender = GBearGamepadMouseSender(
            host = streamHost,
            port = inputPort,
            stickSensitivity = swapStickSensitivity,
        )
        surfaceView.setOnTouchListener { _, event ->
            inputSender?.handleTouch(event) == true
        }

        setContentView(
            FrameLayout(this).apply {
                setBackgroundColor(Color.BLACK)
                addView(
                    surfaceView,
                    FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT,
                    ),
                )
            },
        )

        codecThread = HandlerThread("GBearCodec").apply { start() }
        codecHandler = Handler(codecThread!!.looper)
        startCodecPump()

        running.set(true)
        GBearStreamLog.i(
            "Starting stream host=$streamHost video=$port audio=$audioPort tcp=$audioTcpPort input=$inputPort " +
                "${configuredWidth}x$configuredHeight",
        )
        streamThread = Thread {
            try {
                if (!surfaceReady.await(8, TimeUnit.SECONDS)) {
                    GBearStreamLog.w("Surface not ready before connect")
                    runOnUiThread { handleConnectFailure() }
                    return@Thread
                }
                val sock = connectVideoSocket(streamHost, port)
                socket = sock
                streamConnectedAt = SystemClock.elapsedRealtime()
                val audio = GBearAudioReceiver(streamHost, audioPort, audioTcpPort)
                audioReceiver = audio
                audio.start()
                try {
                    readFrames(DataInputStream(sock.getInputStream()))
                } catch (e: Exception) {
                    if (logSessionEnded) {
                        GBearStreamLog.i(
                            "Stream read ended after $framesReceived frames " +
                                "(${e.javaClass.simpleName}: ${e.message})",
                        )
                    } else if (!GBearStreamSession.hostStreamActive) {
                        GBearStreamLog.i(
                            "Stream read ended after host stop ($framesReceived frames, " +
                                "${e.javaClass.simpleName})",
                        )
                        runOnUiThread {
                            if (!logSessionEnded) {
                                finishFromHost()
                            }
                        }
                    } else {
                        GBearStreamLog.e("Stream failed after $framesReceived frames received", e)
                        runOnUiThread { abortStreamAfterError() }
                    }
                } finally {
                    running.set(false)
                    frameQueue.clear()
                    GBearStreamLog.i(
                        "Stream ended: received=$framesReceived queued=$framesQueued " +
                            "rendered=$framesRendered outputBuffers=$outputBuffersSeen " +
                            "dropped=$framesDropped decoder=$decoderConfigured profile=$decodeProfileIndex",
                    )
                }
            } catch (e: Exception) {
                GBearStreamLog.e("Connect failed", e)
                runOnUiThread { handleConnectFailure() }
            }
        }.also { it.start() }
    }

    private fun connectVideoSocket(host: String, port: Int): Socket {
        val maxAttempts = 16
        var lastError: Exception? = null
        Thread.sleep(400)
        repeat(maxAttempts) { attempt ->
            val sock = Socket()
            try {
                GBearStreamLog.i("Connecting to $host:$port (attempt ${attempt + 1}/$maxAttempts) …")
                sock.connect(InetSocketAddress(host, port), 4_000)
                GBearStreamLog.i("TCP connected, waiting for GBV1 frames")
                runOnUiThread { GBearStreamSession.reportVideoConnectResult(true) }
                return sock
            } catch (e: Exception) {
                lastError = e
                runCatching { sock.close() }
                if (attempt < maxAttempts - 1) {
                    Thread.sleep(350)
                }
            }
        }
        throw lastError ?: java.io.IOException("video connect failed")
    }

    private fun handleConnectFailure() {
        GBearStreamSession.reportVideoConnectResult(false)
        GBearStreamStopper.stopAll(
            this,
            "video connect failed",
            recordPendingLogForResume = true,
        )
    }

    private fun startCodecPump() {
        val handler = codecHandler ?: return
        handler.post(object : Runnable {
            override fun run() {
                var processed = false
                while (true) {
                    val frame = frameQueue.poll() ?: break
                    processFrame(frame)
                    processed = true
                }
                if (running.get() || frameQueue.isNotEmpty()) {
                    handler.postDelayed(this, if (processed) 0 else 8)
                } else {
                    releaseDecoder()
                }
            }
        })
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        holder.setFixedSize(configuredWidth, configuredHeight)
        renderSurface = holder.surface
        surfaceValid = holder.surface.isValid
        GBearStreamLog.i(
            "SurfaceView ready ${configuredWidth}x$configuredHeight valid=$surfaceValid",
        )
        surfaceReady.countDown()
        if (decoderConfigured && decoder != null) {
            needsIdrFrame = true
            GBearStreamLog.i("Surface recreated; waiting for keyframe")
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        holder.setFixedSize(configuredWidth, configuredHeight)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceValid = false
        renderSurface = null
        codecHandler?.post { releaseDecoder() }
        GBearStreamLog.w("Surface destroyed (stream still running=${running.get()})")
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        handleStreamBackNavigation()
    }

    private fun handleStreamBackNavigation() {
        if (GamepadLinkCapture.isListening()) {
            GamepadLinkCapture.cancel()
            return
        }
        if (mappingOverlay?.isShowing == true) {
            mappingOverlay?.dismiss()
            return
        }
        if (shortcutsOverlay?.isShowing == true) {
            shortcutsOverlay?.dismiss()
            return
        }
        GBearStreamLog.i("Back pressed — leaving stream view (host stream stays active)")
        leaveViewerOnly()
    }

    /** Closes the video UI; Mac host keeps streaming until Stop in the companion app. */
    private fun leaveViewerOnly() {
        GBearStreamSession.leaveViewerWithoutMacStop = true
        teardownStream(
            "viewer closed (received=$framesReceived rendered=$framesRendered dropped=$framesDropped)",
            releaseKeyboard = false,
        )
        GBearStreamSession.viewerOpen = false
        mappingOverlay?.dismiss()
        mappingOverlay = null
        shortcutsOverlay?.dismiss()
        shortcutsOverlay = null
        GBearStreamNotificationHelper.updateViewerHint(applicationContext, streamHost, false)
    }

    fun showStreamShortcutsOverlay() {
        if (GBearStreamSession.keyboardSender() == null) {
            GBearStreamLog.w("Shortcuts overlay unavailable — keyboard sender missing")
            return
        }
        shortcutsOverlay?.dismiss()
        mappingOverlay?.dismiss()
        mappingOverlay = null
        shortcutsOverlay = GBearStreamShortcutsOverlay(this)
        shortcutsOverlay?.show()
    }

    /** Called when notification Swap is turned off while this activity is open. */
    fun onSwapMouseModeDisabled() {
        gamepadMouseSender?.releaseAll()
        keyboardSender?.releaseAllKeys()
    }

    fun gamepadMouseSender(): GBearGamepadMouseSender? = gamepadMouseSender

    fun updateSwapStickSensitivity(value: Float) {
        gamepadMouseSender?.updateStickSensitivity(value)
    }

    fun showControllerMappingOverlay() {
        shortcutsOverlay?.dismiss()
        shortcutsOverlay = null
        mappingOverlay?.dismiss()
        mappingOverlay = GBearControllerMappingOverlay(this) { json ->
            gamepadMapping = GBearGamepadMapping(json).takeIf { it.hasBindings() }
        }
        mappingOverlay?.show()
    }

    fun finishFromHost() {
        if (logSessionEnded) {
            if (!isFinishing) {
                finish()
            }
            return
        }
        mappingOverlay?.dismiss()
        mappingOverlay = null
        shortcutsOverlay?.dismiss()
        shortcutsOverlay = null
        GBearStreamSession.clear()
        teardownStream(
            "stopped from companion (received=$framesReceived rendered=$framesRendered dropped=$framesDropped)",
        )
        GBearStreamNotificationHelper.dismiss(applicationContext)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (GamepadInputFilter.isSystemVolumeOrNavigationKey(event.keyCode)) {
            return super.dispatchKeyEvent(event)
        }
        if (event.keyCode == KeyEvent.KEYCODE_BACK) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                handleStreamBackNavigation()
            }
            return true
        }
        if (GamepadLinkCapture.tryConsume(event)) {
            return true
        }
        if (GBearStreamSession.coopPadMode) {
            val pad = GBearStreamSession.gamepadSender()
            if (pad != null && pad.handleKeyEvent(event)) {
                return true
            }
            if (GamepadInputFilter.isGamepadKey(event)) {
                return true
            }
        }
        val mapping = gamepadMappingForEvent()
        val keyboard = keyboardSender ?: GBearStreamSession.keyboardSender().also { keyboardSender = it }
        val swapActive = GBearStreamSession.swapMouseModeActive
        if (mapping != null) {
            if (mapping.handleKeyEvent(
                    event,
                    keyboard,
                    swapActive,
                ) { GBearStreamSwapActions.toggle(this) }) {
                return true
            }
        }
        if (swapActive) {
            val mouse = gamepadMouseSender
            if (mouse != null && mouse.handleKeyEvent(event)) {
                return true
            }
            if (GamepadInputFilter.isGamepadKey(event)) {
                return true
            }
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
        if (!GamepadInputFilter.isGamepadMotion(event)) {
            return super.dispatchGenericMotionEvent(event)
        }
        if (GBearStreamSession.coopPadMode) {
            GBearStreamSession.gamepadSender()?.handleMotion(event)
            return true
        }
        val mapping = gamepadMappingForEvent()
        val keyboard = keyboardSender ?: GBearStreamSession.keyboardSender().also { keyboardSender = it }
        val swapActive = GBearStreamSession.swapMouseModeActive
        if (swapActive) {
            gamepadMouseSender?.handleMotionEvent(event)
        }
        if (mapping != null) {
            val toggle = { GBearStreamSwapActions.toggle(this) }
            val lt = GamepadInputFilter.leftTriggerValue(event)
            val rt = GamepadInputFilter.rightTriggerValue(event)
            mapping.handleTrigger("leftTrigger", lt, keyboard, swapActive, toggle)
            mapping.handleTrigger("rightTrigger", rt, keyboard, swapActive, toggle)
            mapping.handleHatDpad(event, keyboard, swapActive, toggle)
            mapping.handleAnalogSticks(event, keyboard, swapActive, toggle)
        }
        if (swapActive) {
            return true
        }
        if (mapping != null && keyboard != null) {
            mapping.handleTrigger(
                "leftTrigger",
                GamepadInputFilter.leftTriggerValue(event),
                keyboard,
                false,
            ) {}
            mapping.handleTrigger(
                "rightTrigger",
                GamepadInputFilter.rightTriggerValue(event),
                keyboard,
                false,
            ) {}
        }
        return true
    }

    private fun abortStreamAfterError() {
        teardownStream(
            "stream error (received=$framesReceived rendered=$framesRendered dropped=$framesDropped)",
        )
    }

    /** Reload bindings from prefs so Controller-tab edits apply without restarting the stream. */
    private fun gamepadMappingForEvent(): GBearGamepadMapping? {
        val json = GBearStreamMappingPrefs.loadBindingsJson(applicationContext)
            .ifEmpty { GBearStreamSession.controllerBindingsJson }
        if (json.isNotEmpty()) {
            GBearStreamSession.controllerBindingsJson = json
        }
        if (json == gamepadMappingJsonCache) {
            return gamepadMapping
        }
        gamepadMappingJsonCache = json
        gamepadMapping = GBearGamepadMapping(json).takeIf { it.hasBindings() }
        return gamepadMapping
    }

    private fun teardownStream(endReason: String, releaseKeyboard: Boolean = true) {
        if (logSessionEnded) return
        running.set(false)
        codecHandler?.post { releaseDecoder() }
        endLogSession(endReason)
        audioReceiver?.stop()
        audioReceiver = null
        inputSender?.close()
        inputSender = null
        gamepadMouseSender?.close()
        gamepadMouseSender = null
        GBearStreamSession.releaseGamepadSender()
        if (releaseKeyboard) {
            GBearStreamSession.releaseKeyboardSender()
        }
        keyboardSender = null
        streamThread?.interrupt()
        runCatching { socket?.close() }
        if (!isFinishing) {
            finish()
        }
    }

    override fun onDestroy() {
        val hostToStop = streamHost.ifEmpty { GBearStreamSession.host }
        val viewerExit = GBearStreamSession.leaveViewerWithoutMacStop
        GBearStreamSession.leaveViewerWithoutMacStop = false
        if (hostToStop.isNotEmpty() && !viewerExit) {
            Thread {
                GBearHostControlClient.stopStreamOnHost(hostToStop)
            }.start()
        }
        mappingOverlay?.dismiss()
        mappingOverlay = null
        shortcutsOverlay?.dismiss()
        shortcutsOverlay = null
        running.set(false)
        GBearStreamSession.viewerOpen = false
        audioReceiver?.stop()
        audioReceiver = null
        inputSender?.close()
        inputSender = null
        gamepadMouseSender?.close()
        gamepadMouseSender = null
        if (!GBearStreamSession.hostStreamActive) {
            GBearStreamSession.releaseKeyboardSender()
        }
        keyboardSender = null
        streamThread?.interrupt()
        runCatching { socket?.close() }
        codecHandler?.post { releaseDecoder() }
        codecThread?.quitSafely()
        codecThread?.join(2_000)
        renderSurface = null
        surfaceValid = false
        endLogSession(
            "activity destroyed (received=$framesReceived rendered=$framesRendered dropped=$framesDropped)",
        )
        if (current === this) {
            current = null
        }
        super.onDestroy()
    }

    private fun endLogSession(reason: String) {
        if (logSessionEnded) return
        logSessionEnded = true
        GBearStreamLog.endSession(reason)
    }

    private fun releaseDecoder() {
        decoder?.runCatching {
            stop()
            release()
        }
        decoder = null
        decoderConfigured = false
        needsIdrFrame = true
    }

    private fun readFrames(input: DataInputStream) {
        val header = ByteArray(GBearVideoFrameFormat.HEADER_SIZE)
        while (running.get()) {
            input.readFully(header)
            val buffer = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
            val magic = buffer.int
            if (magic != GBearVideoFrameFormat.MAGIC) {
                GBearStreamLog.e("Bad magic 0x${magic.toUInt().toString(16)} (expected GBV1); closing stream")
                break
            }
            val length = buffer.int
            val flags = buffer.get().toInt() and 0xFF
            val width = buffer.short.toInt() and 0xFFFF
            val height = buffer.short.toInt() and 0xFFFF
            if (length <= 0 || length > 8 * 1024 * 1024) {
                GBearStreamLog.e("Invalid payload length=$length; closing stream")
                break
            }
            val payload = ByteArray(length)
            input.readFully(payload)
            val isKeyframe = flags and 0x1 != 0
            if (!frameQueue.offer(IncomingFrame(payload, isKeyframe, width, height))) {
                framesDropped++
            }
        }
    }

    private fun currentProfile(): DecodeProfile =
        decodeProfiles[decodeProfileIndex.coerceIn(decodeProfiles.indices)]

    private fun processFrame(frame: IncomingFrame) {
        framesReceived++
        val nals = parseAllNALUs(frame.payload)
        val (sps, pps) = extractSpsPps(nals)
        val effectiveKeyframe = frame.isKeyframe || containsIdr(nals)

        if (framesReceived == 1 || framesReceived % 60 == 0) {
            val format = if (looksLikeAnnexB(frame.payload)) "Annex-B" else "AVCC"
            val types = nals.map { if (it.isEmpty()) -1 else it[0].toInt() and 0x1F }
            val profile = currentProfile()
            GBearStreamLog.i(
                "Frame #$framesReceived keyframe=${frame.isKeyframe} effective=$effectiveKeyframe $format " +
                    "${frame.width}x${frame.height} bytes=${frame.payload.size} nals=${nals.size} " +
                    "types=$types sps=${sps?.size} pps=${pps?.size} decoder=$decoderConfigured " +
                    "profile=${profile.label}",
            )
        }

        if (nals.isEmpty()) {
            framesDropped++
            return
        }

        if (sps != null) cachedSps = sps
        if (pps != null) cachedPps = pps

        if (!containsSlice(nals)) {
            return
        }

        val useSps = sps ?: cachedSps
        val usePps = pps ?: cachedPps

        if (!surfaceValid || renderSurface?.isValid != true) {
            framesDropped++
            return
        }

        if (!decoderConfigured) {
            if (!effectiveKeyframe) {
                framesDropped++
                if (framesDropped <= 5) {
                    GBearStreamLog.i("Waiting for keyframe (frame #$framesReceived)")
                }
                return
            }
            if (useSps == null || usePps == null) {
                framesDropped++
                GBearStreamLog.w(
                    "Keyframe #$framesReceived missing SPS/PPS " +
                        "(inline sps=${sps?.size} pps=${pps?.size} cached sps=${cachedSps?.size} pps=${cachedPps?.size})",
                )
                return
            }
            if (!configureDecoder(useSps, usePps, frame.width, frame.height)) {
                framesDropped++
                return
            }
        }

        if (needsIdrFrame && !effectiveKeyframe) {
            framesDropped++
            return
        }

        val submitted = submitDecodedFrame(
            frame = frame,
            nals = nals,
            effectiveKeyframe = effectiveKeyframe,
            sps = useSps,
            pps = usePps,
        )
        if (!submitted) {
            framesDropped++
            return
        }

        logDecoderStallIfNeeded()
        maybeAdvanceDecodeProfile(useSps, usePps, frame.width, frame.height)
    }

    private fun submitDecodedFrame(
        frame: IncomingFrame,
        nals: List<ByteArray>,
        effectiveKeyframe: Boolean,
        sps: ByteArray?,
        pps: ByteArray?,
    ): Boolean {
        val codec = decoder ?: return false
        val profile = currentProfile()

        return when (profile.feedMode) {
            FeedMode.AnnexBPassthrough -> {
                val annexB = payloadAsAnnexB(frame.payload, nals) ?: return false
                var flags = 0
                if (effectiveKeyframe) {
                    flags = flags or MediaCodec.BUFFER_FLAG_KEY_FRAME
                    needsIdrFrame = false
                }
                queueInputAndDrain(codec, annexB, flags)
            }
            FeedMode.AnnexBSplitConfig -> {
                if (effectiveKeyframe && sps != null && pps != null) {
                    val configAnnexB = annexBParameterSets(sps, pps)
                    if (!queueInputAndDrain(codec, configAnnexB, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)) {
                        return false
                    }
                }
                val sliceAnnexB = toAnnexBSliceAccessUnit(nals) ?: return false
                var flags = 0
                if (effectiveKeyframe) {
                    flags = flags or MediaCodec.BUFFER_FLAG_KEY_FRAME
                    needsIdrFrame = false
                }
                queueInputAndDrain(codec, sliceAnnexB, flags)
            }
            FeedMode.AvccCsdSliceOnly -> {
                val avcc = toAvccSliceAccessUnit(nals) ?: return false
                var flags = 0
                if (effectiveKeyframe) {
                    flags = flags or MediaCodec.BUFFER_FLAG_KEY_FRAME
                    needsIdrFrame = false
                }
                queueInputAndDrain(codec, avcc, flags)
            }
        }
    }

    private fun payloadAsAnnexB(payload: ByteArray, nals: List<ByteArray>): ByteArray? {
        if (looksLikeAnnexB(payload)) {
            return payload
        }
        val converted = toAnnexBAccessUnit(nals)
        if (converted == null) {
            GBearStreamLog.w("Could not convert ${payload.size}B payload to Annex-B (nals=${nals.size})")
            return null
        }
        if (!loggedAvccFallback) {
            loggedAvccFallback = true
            GBearStreamLog.i("Converting AVCC payloads to Annex-B for decoder (${payload.size}B)")
        }
        return converted
    }

    private fun queueInputAndDrain(codec: MediaCodec, data: ByteArray, flags: Int): Boolean {
        if (!decoderConfigured || decoder !== codec) {
            return false
        }
        return try {
            val keyframe = (flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
            if (keyframe) {
                drainOutputs(codec, 0)
            }
            val index = codec.dequeueInputBuffer(20_000)
            if (index < 0) {
                GBearStreamLog.w("dequeueInputBuffer timeout flags=$flags bytes=${data.size}")
                drainOutputs(codec, 0)
                return false
            }
            val buffer = codec.getInputBuffer(index) ?: return false
            buffer.clear()
            if (data.size > buffer.remaining()) {
                GBearStreamLog.w("Input too large need=${data.size} have=${buffer.remaining()}")
                return false
            }
            buffer.put(data)
            val pts = presentationUs
            presentationUs += frameDurationUs
            codec.queueInputBuffer(index, 0, data.size, pts, flags)
            framesQueued++
            val config = (flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
            if (framesQueued <= 5 || keyframe || config) {
                GBearStreamLog.i(
                    "Queued #$framesQueued keyframe=$keyframe config=$config bytes=${data.size} " +
                        "profile=${currentProfile().label}",
                )
            }
            drainOutputs(codec, 30_000)
            true
        } catch (e: IllegalStateException) {
            handleDecoderFailure("queueInputAndDrain", e)
            false
        }
    }

    private fun drainOutputs(codec: MediaCodec, timeoutUs: Long) {
        if (!decoderConfigured || decoder !== codec) {
            return
        }
        try {
            val info = MediaCodec.BufferInfo()
            var waitUs = timeoutUs
            while (true) {
                val index = codec.dequeueOutputBuffer(info, waitUs)
                when {
                    index == MediaCodec.INFO_TRY_AGAIN_LATER -> return
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        GBearStreamLog.i("Output format changed")
                    }
                    index == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit
                    index >= 0 -> {
                        outputBuffersSeen++
                        val render = info.size > 0 &&
                            (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0
                        if (outputBuffersSeen <= 5 || (render && framesRendered < 3) ||
                            (render && framesRendered % 60 == 0)
                        ) {
                            GBearStreamLog.i(
                                "Output #$outputBuffersSeen size=${info.size} flags=${info.flags} " +
                                    "render=$render pts=${info.presentationTimeUs}",
                            )
                        }
                        codec.releaseOutputBuffer(index, render)
                        if (render) {
                            framesRendered++
                            if (framesRendered == 1 || framesRendered % 60 == 0) {
                                GBearStreamLog.i("Rendered frame #$framesRendered")
                            }
                        }
                        waitUs = 0
                    }
                    else -> return
                }
            }
        } catch (e: IllegalStateException) {
            handleDecoderFailure("drainOutputs", e)
        }
    }

    private fun handleDecoderFailure(where: String, error: Exception) {
        GBearStreamLog.e("Decoder failure at $where; will reconfigure on next keyframe", error)
        releaseDecoder()
        needsIdrFrame = true
        loggedDecoderStall = false
    }

    private fun logDecoderStallIfNeeded() {
        if (loggedDecoderStall || !decoderConfigured || outputBuffersSeen > 0) return
        if (framesQueued < 25) return
        if (SystemClock.elapsedRealtime() - streamConnectedAt < 2_500) return
        loggedDecoderStall = true
        val codecName = decoder?.name ?: "none"
        GBearStreamLog.w(
            "Decoder stall: queued=$framesQueued rendered=$framesRendered outputBuffers=$outputBuffersSeen " +
                "codec=$codecName profile=${currentProfile().label}",
        )
    }

    private fun maybeAdvanceDecodeProfile(
        sps: ByteArray?,
        pps: ByteArray?,
        width: Int,
        height: Int,
    ) {
        if (framesRendered > 0) return
        if (SystemClock.elapsedRealtime() - streamConnectedAt < 2_000) return
        if (framesQueued < 30) return
        if (outputBuffersSeen > 0) return
        if (sps == null || pps == null) return
        if (decodeProfileIndex >= decodeProfiles.lastIndex) return

        decodeProfileIndex++
        loggedDecoderStall = false
        GBearStreamLog.w(
            "No decoded output after $framesQueued inputs; trying profile #$decodeProfileIndex " +
                "${currentProfile().label}",
        )
        releaseDecoder()
        configureDecoder(sps, pps, width, height)
        needsIdrFrame = true
    }

    private fun createAvcDecoder(names: List<String>): MediaCodec {
        for (name in names) {
            runCatching {
                return MediaCodec.createByCodecName(name)
            }.onFailure {
                GBearStreamLog.w("Decoder $name unavailable: ${it.message}")
            }
        }
        return MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    }

    private fun configureDecoder(sps: ByteArray, pps: ByteArray, width: Int, height: Int): Boolean {
        val surface = renderSurface
        if (surface == null || !surface.isValid) {
            GBearStreamLog.w("Surface invalid, cannot configure decoder")
            return false
        }

        val w = if (width > 0) width else configuredWidth
        val h = if (height > 0) height else configuredHeight
        val profile = currentProfile()

        releaseDecoder()

        return runCatching {
            val newCodec = createAvcDecoder(profile.codecNames)
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h)
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, w * h * 3 / 2)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, 60)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }

            if (profile.feedMode == FeedMode.AvccCsdSliceOnly) {
                val avcC = buildAvcC(sps, pps)
                format.setByteBuffer("csd-0", ByteBuffer.wrap(avcC))
            }

            newCodec.configure(format, surface, null, 0)
            newCodec.start()
            decoder = newCodec
            decoderConfigured = true
            needsIdrFrame = true
            configuredWidth = w
            configuredHeight = h
            presentationUs = 0L
            outputBuffersSeen = 0
            GBearStreamLog.i(
                "Decoder configured ${w}x$h codec=${newCodec.name} profile=${profile.label} " +
                    "sps=${sps.size}B pps=${pps.size}B",
            )
            true
        }.getOrElse {
            GBearStreamLog.e("Decoder configure failed (${profile.label})", it)
            false
        }
    }

    companion object {
        @Volatile
        var current: GBearVideoActivity? = null

        const val EXTRA_HOST = "host"
        const val EXTRA_VIDEO_PORT = "videoPort"
        const val EXTRA_AUDIO_PORT = "audioPort"
        const val EXTRA_AUDIO_TCP_PORT = "audioTcpPort"
        const val EXTRA_INPUT_PORT = "inputPort"
        const val EXTRA_CURSOR_SPEED = "cursorSpeed"
        const val EXTRA_SWAP_STICK_SENSITIVITY = "swapStickSensitivity"
        const val EXTRA_TAP_SLOP_PERCENT = "tapSlopPercent"
        const val EXTRA_TAP_TIMEOUT_MS = "tapTimeoutMs"
        const val EXTRA_TAP_PRESSURE = "tapPressure"
        const val EXTRA_WIDTH = "width"
        const val EXTRA_HEIGHT = "height"
        const val EXTRA_CONTROLLER_BINDINGS_JSON = "controllerBindingsJson"
        const val EXTRA_SEAT = "seat"
        const val EXTRA_COOP_PAD_MODE = "coopPadMode"
        const val EXTRA_SWAP_FACE = "swapFaceButtons"
        const val EXTRA_DEADZONE = "deadZonePercent"

        private const val MAX_SPS_BYTES = 512
        private const val MAX_PPS_BYTES = 512

        fun extractSpsPps(data: ByteArray): Pair<ByteArray?, ByteArray?> = extractSpsPps(parseAllNALUs(data))

        private fun extractSpsPps(nals: List<ByteArray>): Pair<ByteArray?, ByteArray?> {
            var sps: ByteArray? = null
            var pps: ByteArray? = null
            for (nal in nals) {
                if (nal.isEmpty()) continue
                when (nal[0].toInt() and 0x1F) {
                    7 -> if (sps == null && nal.size <= MAX_SPS_BYTES) {
                        sps = nal
                    }
                    8 -> if (pps == null && nal.size <= MAX_PPS_BYTES) {
                        pps = nal
                    }
                    in 1..5 -> break
                }
            }
            return sps to pps
        }

        private fun annexBParameterSets(sps: ByteArray, pps: ByteArray): ByteArray {
            val start = byteArrayOf(0, 0, 0, 1)
            return ByteArrayOutputStream(sps.size + pps.size + 16).apply {
                write(start)
                write(sps)
                write(start)
                write(pps)
            }.toByteArray()
        }

        fun toAnnexBAccessUnit(nals: List<ByteArray>): ByteArray? {
            if (nals.isEmpty()) return null
            val start = byteArrayOf(0, 0, 0, 1)
            val out = ByteArrayOutputStream()
            for (nal in nals) {
                if (nal.isEmpty()) continue
                out.write(start)
                out.write(nal)
            }
            return if (out.size() > 0) out.toByteArray() else null
        }

        private fun toAnnexBSliceAccessUnit(nals: List<ByteArray>): ByteArray? {
            val sliceNals = nals.filter { nal ->
                nal.isNotEmpty() && (nal[0].toInt() and 0x1F) in setOf(1, 2, 3, 4, 5)
            }
            if (sliceNals.isEmpty()) return null
            val start = byteArrayOf(0, 0, 0, 1)
            val out = ByteArrayOutputStream()
            for (nal in sliceNals) {
                out.write(start)
                out.write(nal)
            }
            return out.toByteArray()
        }

        private fun looksLikeAnnexB(data: ByteArray): Boolean {
            if (!is4ByteStartCode(data, 0) || data.size < 5) return false
            val nalType = data[4].toInt() and 0x1F
            return nalType in 1..23
        }

        private fun is4ByteStartCode(bytes: ByteArray, offset: Int): Boolean {
            return offset + 3 < bytes.size &&
                bytes[offset] == 0.toByte() &&
                bytes[offset + 1] == 0.toByte() &&
                bytes[offset + 2] == 0.toByte() &&
                bytes[offset + 3] == 1.toByte()
        }

        private fun containsIdr(nals: List<ByteArray>): Boolean {
            return nals.any { nal -> nal.isNotEmpty() && (nal[0].toInt() and 0x1F) == 5 }
        }

        private fun containsSlice(nals: List<ByteArray>): Boolean {
            return nals.any { nal ->
                nal.isNotEmpty() && (nal[0].toInt() and 0x1F) in setOf(1, 2, 3, 4, 5)
            }
        }

        fun parseAllNALUs(data: ByteArray): List<ByteArray> {
            if (looksLikeAnnexB(data)) {
                return extractAnnexBNALUs(data)
            }
            val avcc = extractAllAvccNALUs(data)
            if (avcc.isNotEmpty()) {
                return avcc
            }
            return extractAnnexBNALUs(data)
        }

        fun toAvccSliceAccessUnit(nals: List<ByteArray>): ByteArray? {
            val sliceNals = nals.filter { nal ->
                nal.isNotEmpty() && (nal[0].toInt() and 0x1F) in setOf(1, 2, 3, 4, 5)
            }
            return nalsToAvcc(sliceNals)
        }

        fun buildAvcC(sps: ByteArray, pps: ByteArray): ByteArray {
            val profile = if (sps.size >= 2) sps[1].toInt() and 0xFF else 0x42
            val compat = if (sps.size >= 3) sps[2].toInt() and 0xFF else 0x00
            val level = if (sps.size >= 4) sps[3].toInt() and 0xFF else 0x28
            val out = ByteArrayOutputStream(sps.size + pps.size + 16)
            out.write(1)
            out.write(profile)
            out.write(compat)
            out.write(level)
            out.write(0xFF) // 4-byte NAL lengths (lengthSizeMinusOne = 3)
            out.write(0xE1) // one SPS
            out.write((sps.size shr 8) and 0xFF)
            out.write(sps.size and 0xFF)
            out.write(sps)
            out.write(1) // one PPS
            out.write((pps.size shr 8) and 0xFF)
            out.write(pps.size and 0xFF)
            out.write(pps)
            return out.toByteArray()
        }

        private fun nalsToAvcc(nals: List<ByteArray>): ByteArray? {
            if (nals.isEmpty()) return null
            var total = 0
            for (nal in nals) total += 4 + nal.size
            val out = ByteArray(total)
            var offset = 0
            for (nal in nals) {
                val size = nal.size
                out[offset] = (size shr 24).toByte()
                out[offset + 1] = (size shr 16).toByte()
                out[offset + 2] = (size shr 8).toByte()
                out[offset + 3] = size.toByte()
                System.arraycopy(nal, 0, out, offset + 4, size)
                offset += 4 + size
            }
            return out
        }

        private fun extractAllAvccNALUs(data: ByteArray): List<ByteArray> {
            val nals = mutableListOf<ByteArray>()
            var offset = 0
            while (offset + 4 <= data.size) {
                val size = ((data[offset].toInt() and 0xFF) shl 24) or
                    ((data[offset + 1].toInt() and 0xFF) shl 16) or
                    ((data[offset + 2].toInt() and 0xFF) shl 8) or
                    (data[offset + 3].toInt() and 0xFF)
                offset += 4
                if (size <= 0 || offset + size > data.size) break
                nals.add(data.copyOfRange(offset, offset + size))
                offset += size
            }
            return nals
        }

        private fun extractAnnexBNALUs(annexB: ByteArray): List<ByteArray> {
            val bytes = annexB
            val units = mutableListOf<ByteArray>()
            var i = 0
            while (i < bytes.size) {
                if (!is4ByteStartCode(bytes, i)) {
                    i++
                    continue
                }
                val start = i + 4
                var end = start
                while (end < bytes.size) {
                    if (is4ByteStartCode(bytes, end)) break
                    end++
                }
                if (end > start) {
                    units.add(bytes.copyOfRange(start, end))
                }
                i = end
            }
            return units
        }
    }
}

object GBearVideoFrameFormat {
    const val MAGIC = 0x31564247 // GBV1
    const val HEADER_SIZE = 13
}

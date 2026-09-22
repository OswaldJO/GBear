import Foundation

/// Native Playnite streaming host (in-app capture + HTTP control + H.264 video).
@MainActor
@Observable
final class PlayniteStreamHostManager {
    static let shared = PlayniteStreamHostManager()

    enum HostState: Equatable {
        case idle
        case preparing
        case running
        case unavailable(String)
    }

    private(set) var state: HostState = .idle
    private(set) var pendingPairRequests: [PlayniteStreamControlServer.PendingPairRequest] = []
    private(set) var isVideoStreaming = false
    private(set) var coopSession: PlayniteCoopSessionState?
    private(set) var lastStreamLogURL: URL?

    private let server = PlayniteStreamControlServer()
    private let video = PlayniteVideoStreamServer()
    private let audio = PlayniteAudioStreamServer()
    private let input = PlayniteStreamInputServer()
    private let capture = PlayniteScreenCapturePipeline()
    private var pendingPollTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var streamOperationChain: Task<Void, Never>?

    private init() {
        PlayniteLocalOutputMute.setStreamingMuted(false)
    }

    var isCaptureReady: Bool {
        capture.isReady
    }

    /// Show the Allow button only when capture is not ready and we still need TCC consent.
    var needsScreenCaptureConsent: Bool {
        !capture.isReady && !capture.hasSystemAuthorization
    }

    var captureGuidance: String? {
        guard let err = capture.lastError else { return nil }
        if needsScreenCaptureConsent {
            return "\(err) Tap Allow Screen Recording below for the system prompt."
        }
        return "\(err) Restart the streaming host after changing Screen Recording."
    }

    /// Shows the macOS Screen Recording consent dialog (not Settings). No-op if already granted.
    func requestScreenCaptureAccess() async -> Bool {
        let granted = await capture.requestSystemPrompt()
        await server.setCaptureReady(capture.isReady)
        return granted
    }

    var statusLine: String {
        switch state {
        case .idle: return "Pairing host is idle."
        case .preparing: return "Starting pairing host…"
        case .running:
            if isVideoStreaming {
                let seats = coopSession?.seats.count ?? 0
                return "Streaming desktop to \(seats) companion viewer(s)."
            }
            return "Ready for pairing — capture starts when the companion starts a stream."
        case .unavailable(let message): return message
        }
    }

    func refreshCapturePermission() async {
        await capture.refresh()
        await server.setCaptureReady(capture.isReady)
    }

    /// Starts HTTP control and keeps video/audio/input listeners bound until [stop] / [restartHost].
    func ensureReady() async {
        state = .preparing
        PlayniteLocalOutputMute.setStreamingMuted(false)
        await refreshCapturePermission()
        await wireStreamCallbacks()
        await wirePairingCallbacks()

        do {
            try await server.start()
            try await startTransportListeners()
            AccessibilityPermission.promptIfNeeded()
            state = .running
            await refreshPendingPairRequests()
            startPendingPoll()
        } catch {
            state = .unavailable("Could not start Playnite pairing host: \(error.localizedDescription)")
        }
    }

    /// Ends an active companion stream (e.g. after the phone force-quit without Stop).
    /// Returns a log file URL when a session journal was written this stream.
    @discardableResult
    func stopActiveVideoStream() async -> URL? {
        PlayniteStreamSessionLog.i("Stop active stream tapped on Mac Streaming tab")
        await endVideoStream(reason: "stopped from Mac Streaming tab")
        return lastStreamLogURL
    }

    func restartHost() async {
        stopPendingPoll()
        await endVideoStream()
        await stopTransportListeners()
        await server.stop()
        state = .idle
        await ensureReady()
    }

    func stop() async {
        stopPendingPoll()
        await endVideoStream()
        await stopTransportListeners()
        await server.stop()
        PlayniteLocalOutputMute.setStreamingMuted(false)
        state = .idle
        pendingPairRequests = []
    }

    func startWatchingPairingRequests() {
        startPendingPoll()
    }

    func stopWatchingPairingRequests() {
        stopPendingPoll()
    }

    func approvePairing(deviceID: String) async -> Bool {
        await server.approve(deviceID: deviceID)
    }

    func denyPairing(deviceID: String) async -> Bool {
        await server.deny(deviceID: deviceID)
    }

    func fetchPairedClientNames() async -> [String] {
        await server.pairedNames()
    }

    func ping() async -> Bool {
        await server.isListening
    }

    private func wireStreamCallbacks() async {
        await server.setStreamHandlers(
            onStart: { deviceID, width, height, fps in
                await PlayniteStreamHostManager.shared.beginVideoStream(
                    deviceID: deviceID,
                    width: width,
                    height: height,
                    fps: fps
                )
            },
            onStop: {
                await PlayniteStreamHostManager.shared.endVideoStream(reason: "companion POST stream/stop")
            }
        )
    }

    private func wirePairingCallbacks() async {
        await server.setPairingQueueHandler { [weak self] in
            await self?.refreshPendingPairRequests()
        }
        await server.setSessionChangedHandler { [weak self] in
            await self?.refreshCoopSession()
        }
    }

    func refreshPendingPairRequests() async {
        pendingPairRequests = await server.pendingRequests()
    }

    func refreshCoopSession() async {
        coopSession = await server.currentSession()
        if let session = coopSession {
            let ownerSeat: UInt8?
            if let ownerID = session.cursorOwnerDeviceID,
               let seat = session.seat(for: ownerID)?.seat {
                ownerSeat = UInt8(seat)
            } else {
                ownerSeat = 1
            }
            await input.setCursorOwnerSeat(ownerSeat)
            await input.setShortcutOwnerSeat(1)
        }
    }

    @discardableResult
    func createCoopSession() async -> PlayniteCoopSessionState {
        let session = await server.ensureSession()
        coopSession = session
        return session
    }

    func endCoopSession() async {
        await server.endSession()
        coopSession = nil
    }

    func reassignSeat(deviceID: String, seat: Int) async -> Bool {
        let ok = await server.reassignSeat(deviceID: deviceID, seat: seat)
        await refreshCoopSession()
        return ok
    }

    func setCursorOwner(deviceID: String) async -> Bool {
        let ok = await server.setCursorOwner(deviceID: deviceID)
        await refreshCoopSession()
        return ok
    }

    func beginVideoStream(deviceID: String, width: Int, height: Int, fps: Int) async {
        await enqueueStreamOperation {
            await self.beginVideoStreamUnlocked(deviceID: deviceID, width: width, height: height, fps: fps)
        }
    }

    /// Runs [body] after any prior start/stop work finishes.
    private func enqueueStreamOperation(_ body: @escaping @MainActor () async -> Void) async {
        let previous = streamOperationChain
        let task = Task { @MainActor in
            if let previous {
                await previous.value
            }
            await body()
        }
        streamOperationChain = task
        await task.value
    }

    private func beginVideoStreamUnlocked(deviceID: String, width: Int, height: Int, fps: Int) async {
        await refreshCoopSession()
        // Second viewer attaches to existing capture — do not restart encode.
        if isVideoStreaming, captureTask != nil {
            PlayniteStreamSessionLog.i("Viewer \(deviceID) attached to existing capture session")
            print("[PlayniteStream] viewer attached without restarting capture")
            return
        }
        await endVideoStreamUnlocked(reason: "starting new capture session")
        if !capture.isReady {
            guard await capture.requestSystemPrompt() else { return }
            await server.setCaptureReady(capture.isReady)
            guard capture.isReady else { return }
        }
        let deviceName = await server.pairedDeviceName(deviceID: deviceID)
        PlayniteStreamSessionLog.startSession(deviceName: deviceName, width: width, height: height, fps: fps)
        PlayniteKeyboardPlayback.resetModifierState()
        await PlayniteVirtualGamepadManager.shared.ensurePads()
        isVideoStreaming = true
        await server.setVideoStreaming(true)
        PlayniteLocalOutputMute.setStreamingMuted(true)
        let audioServer = audio
        captureTask?.cancel()
        captureTask = Task { @MainActor in
            do {
                try await video.startCapture(width: width, height: height, fps: fps) { pcm, sampleRate, channels in
                    Task { await audioServer.sendPCM(pcm, sampleRate: sampleRate, channels: channels) }
                }
                PlayniteStreamSessionLog.i("Capture started \(width)x\(height) @ \(fps)fps")
                print("[PlayniteStream] companion stream \(width)x\(height) @ \(fps)fps")
            } catch {
                if !Task.isCancelled {
                    let message = error.localizedDescription
                    PlayniteStreamSessionLog.e("Capture start failed: \(message)")
                    print("[PlayniteStream] capture start failed: \(message)")
                    await self.endVideoStreamUnlocked(reason: "capture start failed")
                }
            }
        }
    }

    private func endVideoStream(reason: String = "stream ended") async {
        await enqueueStreamOperation {
            await self.endVideoStreamUnlocked(reason: reason)
        }
    }

    private func endVideoStreamUnlocked(reason: String) async {
        captureTask?.cancel()
        captureTask = nil
        await video.stopStream()
        isVideoStreaming = false
        await server.setVideoStreaming(false)
        PlayniteKeyboardPlayback.resetModifierState()
        await PlayniteVirtualGamepadManager.shared.resetAll()
        PlayniteLocalOutputMute.setStreamingMuted(false)
        lastStreamLogURL = PlayniteStreamSessionLog.endSession(reason: reason)
        await refreshCoopSession()
        print("[PlayniteStream] stream ended")
    }

    private func startTransportListeners() async throws {
        try await video.startListener()
        try await audio.startListener()
        try await audio.startTCPListener()
        try await input.startListener()
    }

    private func stopTransportListeners() async {
        await video.stop()
        await audio.stop()
        await input.stop()
    }

    private func startPendingPoll() {
        pendingPollTask?.cancel()
        pendingPollTask = Task { @MainActor in
            while !Task.isCancelled {
                if case .running = state {
                    await refreshPendingPairRequests()
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func stopPendingPoll() {
        pendingPollTask?.cancel()
        pendingPollTask = nil
    }
}

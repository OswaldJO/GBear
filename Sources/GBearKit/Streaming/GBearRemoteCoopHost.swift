import AppKit
import Foundation

/// Host side of remote co-op: local relay, outbound tunnel, invite line, video/audio/input.
@MainActor
@Observable
final class GBearRemoteCoopHost {
    static let shared = GBearRemoteCoopHost()

    private(set) var statusMessage = "Start a remote session, then send the invite line to your friend."
    private(set) var inviteLine = ""
    private(set) var isRunning = false
    private(set) var isStarting = false

    private let relay = GBearLocalRelayServer()
    private var tunnelProcess: Process?
    private var tunnelOutput: OutputCollector?
    nonisolated private let videoPump = GBearRelaySendPump(dependentFrames: true)
    nonisolated private let audioPump = GBearRelaySendPump(dependentFrames: false)
    nonisolated private let bitrate = GBearRelayBitrateController()
    private var pingTask: Task<Void, Never>?
    private(set) var pictureNote = ""
    private var socket: GBearRelayWebSocket?
    private var relayURL: URL?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var stayAwake: NSObjectProtocol?
    private var guestDropTask: Task<Void, Never>?
    private var admittedGuestID: String?
    private var admittedSeat: Int?

    private init() {
        videoPump.onDrop = { [bitrate] in bitrate.handleDrop() }
        bitrate.onKeyframeNeeded = {
            Task { await GBearStreamHostManager.shared.requestRelayKeyframe() }
        }
        bitrate.onBitRateChange = { rate in
            Task { @MainActor in
                await GBearStreamHostManager.shared.setRelayBitRate(rate)
                GBearRemoteCoopHost.shared.updatePictureNote(rate)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                GBearRemoteCoopHost.shared.tunnelProcess?.terminate()
            }
        }
    }

    func start() async {
        guard !isStarting, !isRunning else { return }
        isStarting = true
        inviteLine = ""
        admittedGuestID = nil
        admittedSeat = nil
        statusMessage = "Starting the relay on this Mac…"
        do {
            try await relay.start()
            statusMessage = "Downloading the network connector if it is not already installed…"
            let cloudflared = try await GBearCloudflaredBinary.ensure()
            statusMessage = "Opening an outbound path your friend can reach…"
            let publicURL = try await launchTunnel(cloudflared)
            let coord = GBearSessionCoordinatorClient.shared
            coord.configure(baseURLString: "http://127.0.0.1:8787")
            guard await coord.signIn(idToken: "dev:host@gbear.local") else {
                throw failure(coord.lastError ?? "Could not sign in to the local relay.")
            }
            guard let sessionID = await coord.createRemoteSession() else {
                throw failure(coord.lastError ?? "Could not create a remote session.")
            }
            guard let code = await coord.mintInvite() else {
                throw failure(coord.lastError ?? "Could not create an invite code.")
            }
            guard let socketURL = GBearRelayWebSocket.relayURL(
                base: URL(string: "http://127.0.0.1:8787")!,
                deviceID: coord.hostDeviceID,
                sessionID: sessionID
            ) else {
                throw failure("Could not build the relay address.")
            }
            relayURL = socketURL
            reconnectAttempts = 0
            connectRelay(socketURL)
            inviteLine = "GBEAR1 \(code) \(publicURL.absoluteString)"
            isRunning = true
            beginStayAwake()
            statusMessage = "Send the invite line to your friend. Leave this screen open. When they join, launch the game and set up both players in the emulator’s controller settings."
        } catch {
            await stop()
            statusMessage = error.localizedDescription
        }
        isStarting = false
    }

    func stop() async {
        isRunning = false
        reconnectTask?.cancel()
        reconnectTask = nil
        guestDropTask?.cancel()
        guestDropTask = nil
        stopPings()
        endStayAwake()
        let guestID = admittedGuestID
        admittedGuestID = nil
        admittedSeat = nil
        videoPump.send = nil
        audioPump.send = nil
        relayURL = nil
        socket?.close()
        socket = nil
        if let guestID {
            await GBearStreamHostManager.shared.releaseRelayGuest(deviceID: guestID)
        } else {
            await GBearStreamHostManager.shared.setRelaySinks(video: nil, audio: nil)
        }
        tunnelProcess?.terminate()
        tunnelProcess = nil
        tunnelOutput?.stop()
        tunnelOutput = nil
        await GBearSessionCoordinatorClient.shared.endRemoteSession()
        relay.stop()
        if inviteLine.isEmpty == false {
            statusMessage = "Remote session ended."
        }
        inviteLine = ""
    }

    func copyInvite() {
        guard !inviteLine.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(inviteLine, forType: .string)
        statusMessage = "Invite copied. Send it to your friend, then wait on this screen."
    }

    private func wirePumps(_ socket: GBearRelayWebSocket) {
        videoPump.send = { data, done in
            socket.send(data, completion: done)
        }
        audioPump.send = { data, done in
            socket.send(data, completion: done)
        }
    }

    private func handleText(_ text: String) {
        guard let type = jsonType(text) else { return }
        if type == "congestion" {
            bitrate.handleDrop()
        } else if type == "peer_left" {
            statusMessage = "Your friend disconnected. Waiting for them to reconnect…"
            guestDropTask?.cancel()
            let guestID = admittedGuestID
            guestDropTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, self.admittedGuestID == guestID else { return }
                await self.dropGuest()
                self.statusMessage = "Your friend left. The invite still works if they join again."
            }
        }
    }

    private func connectRelay(_ url: URL) {
        let socket = GBearRelayWebSocket()
        self.socket = socket
        wirePumps(socket)
        socket.setHandlers(
            onBinary: { [weak self] data in
                self?.handleRelayBinary(data)
            },
            onText: { [weak self] text in
                Task { @MainActor in self?.handleText(text) }
            },
            onClose: { [weak self] reason in
                Task { @MainActor in self?.handleRelayClosed(reason) }
            }
        )
        socket.connect(url)
    }

    /// Video frames stay off the main actor. Only controller and control messages hop over,
    /// so a busy game cannot bury `GBG1` behind the picture (BJ-097).
    private nonisolated func handleRelayBinary(_ data: Data) {
        guard let (channel, payload) = GBearTunnelFrame.unpack(data) else { return }
        switch channel {
        case .input:
            if let event = GBearGamepadEventFormat.parse(payload) {
                Task { await GBearVirtualGamepadManager.shared.apply(event) }
            }
        case .control:
            if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               json["type"] as? String == "pong",
               let sent = json["t"] as? Double {
                bitrate.handlePong(sentMillis: sent)
                return
            }
            Task { @MainActor in await self.handleControl(payload) }
        case .video, .audio:
            break
        }
    }

    private func startPings() {
        pingTask?.cancel()
        pingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, admittedGuestID != nil else { continue }
                sendControl(bitrate.pingMessage())
                bitrate.tick()
            }
        }
    }

    private func stopPings() {
        pingTask?.cancel()
        pingTask = nil
        pictureNote = ""
    }

    fileprivate func updatePictureNote(_ rate: Int) {
        guard admittedGuestID != nil else { return }
        pictureNote = String(format: "Picture: %.1f Mbit/s (adjusts to your friend’s connection)", Double(rate) / 1_000_000)
    }

    private func handleRelayClosed(_ reason: String) {
        guard isRunning, let relayURL else { return }
        guard reconnectTask == nil else { return }
        reconnectAttempts += 1
        if reconnectAttempts > 15 {
            statusMessage = "Connection dropped (\(reason)). Start remote co-op again and send a new invite."
            return
        }
        statusMessage = "Connection dropped (\(reason)). Reconnecting…"
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            reconnectTask = nil
            guard !Task.isCancelled, isRunning, self.relayURL == relayURL else { return }
            connectRelay(relayURL)
        }
    }

    private func handleControl(_ payload: Data) async {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              json["type"] as? String == "hello",
              let deviceID = json["deviceId"] as? String else { return }
        guestDropTask?.cancel()
        guestDropTask = nil
        reconnectAttempts = 0
        if admittedGuestID == deviceID, let admittedSeat {
            sendControl(["type": "welcome", "seat": admittedSeat])
            await GBearStreamHostManager.shared.requestRelayKeyframe()
            return
        }
        let name = (json["deviceName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred = json["preferredSeat"] as? Int
        let seatPref = (preferred ?? 0) >= 1 ? preferred : nil
        statusMessage = "Your friend connected. Starting the stream…"
        bitrate.reset()
        await GBearStreamHostManager.shared.setRelaySinks(
            video: { [videoPump] packet in
                let frame = GBearTunnelFrame.pack(channel: .video, payload: packet)
                let keyframe = packet.count > 8 && (packet[8] & 1) != 0
                videoPump.enqueue(frame, keyframe: keyframe)
            },
            audio: { [audioPump] packet in
                let frame = GBearTunnelFrame.pack(channel: .audio, payload: packet)
                audioPump.enqueue(frame, keyframe: false)
            }
        )
        guard let seat = await GBearStreamHostManager.shared.attachRelayGuest(
            deviceID: deviceID,
            deviceName: name?.isEmpty == false ? name! : "Remote Mac",
            preferredSeat: seatPref
        ) else {
            sendControl(["type": "error", "error": "Could not join. Allow Screen Recording for GBear and try again."])
            statusMessage = "Could not start the stream. Allow Screen Recording for GBear, then start the remote session again."
            await GBearStreamHostManager.shared.setRelaySinks(video: nil, audio: nil)
            return
        }
        admittedGuestID = deviceID
        admittedSeat = seat
        sendControl(["type": "welcome", "seat": seat])
        updatePictureNote(bitrate.currentBitRate)
        startPings()
        if AccessibilityPermission.isGranted {
            statusMessage = "Your friend is Player \(seat). Launch the game. In the emulator, set Player 1 to your controller. For Player \(seat), choose the keyboard, then click each button slot while your friend presses that button. This Mac’s speakers stay quiet while they are connected."
        } else {
            AccessibilityPermission.promptIfNeeded()
            statusMessage = "Your friend is Player \(seat), but their controller can’t reach the game yet. Allow \(AccessibilityPermission.settingsAppName) in System Settings → Privacy & Security → Accessibility, then quit and reopen GBear."
        }
    }

    private func dropGuest() async {
        stopPings()
        let guestID = admittedGuestID
        admittedGuestID = nil
        admittedSeat = nil
        if let guestID {
            await GBearStreamHostManager.shared.releaseRelayGuest(deviceID: guestID)
        }
        statusMessage = "Your friend left. The invite still works if they join again."
    }

    private func sendControl(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        socket?.send(GBearTunnelFrame.pack(channel: .control, payload: data))
    }

    private func jsonType(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["type"] as? String
    }

    /// Tunnels outlive GBear when it crashes or is force-quit; they would keep pointing at this relay port.
    private static func terminateStaleTunnels(_ executable: URL) {
        let path = executable.path.replacingOccurrences(of: ".", with: "\\.")
        let pattern = path + " tunnel --url http://127\\.0\\.0\\.1:8787"
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", pattern]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    private func launchTunnel(_ executable: URL) async throws -> URL {
        Self.terminateStaleTunnels(executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "tunnel",
            "--url", "http://127.0.0.1:8787",
            "--no-autoupdate",
        ]
        let collector = OutputCollector()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        collector.start(pipe)
        tunnelProcess = process
        tunnelOutput = collector
        try process.run()
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if let url = Self.publicURL(in: collector.snapshot()) {
                return url
            }
            if !process.isRunning {
                let tail = collector.snapshot().suffix(400)
                throw failure("The outbound path closed. \(tail)")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw failure("Timed out opening an outbound path. \(collector.snapshot().suffix(400))")
    }

    private static func publicURL(in text: String) -> URL? {
        guard let match = text.range(of: #"https://[a-zA-Z0-9-]+\.trycloudflare\.com"#, options: .regularExpression) else {
            return nil
        }
        return URL(string: String(text[match]))
    }

    private func beginStayAwake() {
        guard stayAwake == nil else { return }
        stayAwake = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "GBear is hosting remote co-op"
        )
    }

    private func endStayAwake() {
        guard let stayAwake else { return }
        ProcessInfo.processInfo.endActivity(stayAwake)
        self.stayAwake = nil
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "GBearRemoteCoop", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Drops stale frames so a slow link cannot queue seconds of picture.
/// H.264 frames depend on the one before, so once a video frame is dropped every frame up to
/// the next keyframe is dropped too; sending them would smear the picture until then.
final class GBearRelaySendPump: @unchecked Sendable {
    private let lock = NSLock()
    private let dependentFrames: Bool
    private var sending = false
    private var pending: Data?
    private var pendingIsKeyframe = false
    private var awaitingKeyframe = false
    var send: (@Sendable (Data, @escaping @Sendable () -> Void) -> Void)?
    var onDrop: (@Sendable () -> Void)?

    init(dependentFrames: Bool) {
        self.dependentFrames = dependentFrames
    }

    func enqueue(_ data: Data, keyframe: Bool) {
        lock.lock()
        if dependentFrames {
            if awaitingKeyframe, !keyframe {
                lock.unlock()
                return
            }
            if keyframe { awaitingKeyframe = false }
        }
        let deliver = send
        if sending {
            if !dependentFrames || keyframe || pending == nil {
                pending = data
                pendingIsKeyframe = keyframe
                lock.unlock()
                return
            }
            awaitingKeyframe = true
            let dropped = onDrop
            lock.unlock()
            dropped?()
            return
        }
        sending = true
        lock.unlock()
        guard let deliver else {
            lock.lock()
            sending = false
            lock.unlock()
            return
        }
        deliver(data) { [weak self] in
            self?.complete()
        }
    }

    private func complete() {
        lock.lock()
        let next = pending
        pending = nil
        pendingIsKeyframe = false
        let deliver = send
        if next == nil || deliver == nil {
            sending = false
            lock.unlock()
            return
        }
        lock.unlock()
        deliver?(next!) { [weak self] in
            self?.complete()
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var handle: FileHandle?

    func start(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            self?.append(chunk)
        }
    }

    func stop() {
        handle?.readabilityHandler = nil
        handle = nil
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }

    private func append(_ chunk: String) {
        lock.lock()
        text += chunk
        if text.count > 16_000 {
            text = String(text.suffix(8_000))
        }
        lock.unlock()
    }
}

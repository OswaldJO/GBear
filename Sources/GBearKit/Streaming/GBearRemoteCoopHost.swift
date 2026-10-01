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
    /// 20 chunks = 200 ms of sound can wait behind a large video frame.
    nonisolated private let audioPump = GBearRelaySendPump(dependentFrames: false, maxPending: 20)
    nonisolated private let bitrate = GBearRelayBitrateController()
    private var pingTask: Task<Void, Never>?
    private(set) var pictureNote = ""
    private var socket: GBearRelayWebSocket?
    private var relayURL: URL?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var stayAwake: NSObjectProtocol?
    /// Seated friends by device ID. Several can share one invite, up to the session's seats.
    private var guests: [String: RelayGuest] = [:]
    private var joiningDeviceIDs: Set<String> = []
    nonisolated private let peerSeats = PeerSeatTable()

    private struct RelayGuest {
        var name: String
        var seat: Int
        /// The relay's number for this friend's current socket; changes when they reconnect.
        var peer: UInt8
        var dropTask: Task<Void, Never>?
    }

    private init() {
        videoPump.onDrop = { [bitrate] in
            bitrate.handleDrop()
            Task { await GBearStreamHostManager.shared.noteStreamEvent("relay: frame dropped on this Mac") }
        }
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
        guests = [:]
        joiningDeviceIDs = []
        peerSeats.removeAll()
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
            statusMessage = Self.waitingMessage
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
        stopPings()
        endStayAwake()
        let leaving = guests
        guests = [:]
        joiningDeviceIDs = []
        peerSeats.removeAll()
        videoPump.send = nil
        audioPump.send = nil
        relayURL = nil
        socket?.close()
        socket = nil
        await GBearStreamHostManager.shared.setRelaySinks(video: nil, audio: nil)
        for (deviceID, guest) in leaving {
            guest.dropTask?.cancel()
            await GBearStreamHostManager.shared.releaseRelayGuest(deviceID: deviceID)
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
        statusMessage = "Invite copied. Send it to your friends (up to \(GBearLocalRelayServer.maxGuests)), then wait on this screen."
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
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        if type == "congestion" {
            bitrate.handleDrop()
            let who = (json["peer"] as? Int).flatMap(UInt8.init(exactly:))
                .flatMap { peer in guests.values.first { $0.peer == peer } }
                .map { "Player \($0.seat)" } ?? "a friend"
            Task { await GBearStreamHostManager.shared.noteStreamEvent("relay: congestion to \(who)") }
        } else if type == "peer_left", let peer = (json["peer"] as? Int).flatMap(UInt8.init(exactly:)) {
            guard let (deviceID, guest) = guests.first(where: { $0.value.peer == peer }) else { return }
            statusMessage = "\(guest.name) (Player \(guest.seat)) disconnected. Waiting for them to reconnect…"
            guests[deviceID]?.dropTask?.cancel()
            guests[deviceID]?.dropTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, self.guests[deviceID]?.peer == peer else { return }
                await self.dropGuest(deviceID: deviceID)
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
        guard let (peer, frame) = GBearTunnelPeerFrame.unwrap(data),
              let (channel, payload) = GBearTunnelFrame.unpack(frame) else { return }
        switch channel {
        case .input:
            // Each friend drives only the seat the host gave them.
            guard let seat = peerSeats.seat(for: peer), payload.count > 4 else { return }
            var packet = payload
            packet[packet.startIndex + 4] = seat
            if let event = GBearGamepadEventFormat.parse(packet) {
                Task { await GBearVirtualGamepadManager.shared.apply(event) }
            }
        case .control:
            if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               json["type"] as? String == "pong",
               let sent = json["t"] as? Double {
                if let rtt = bitrate.handlePong(sentMillis: sent) {
                    Task { await GBearStreamHostManager.shared.noteRelayRoundTrip(millis: rtt) }
                }
                return
            }
            Task { @MainActor in await self.handleControl(payload, peer: peer) }
        case .video, .audio:
            break
        }
    }

    private func startPings() {
        pingTask?.cancel()
        pingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !guests.isEmpty else { continue }
                // Friends show the host's bitrate from the ping; older guests ignore the extra keys.
                let host = GBearStreamHostManager.shared
                await host.refreshVideoBitRate()
                var ping = bitrate.pingMessage()
                if let rate = host.videoBitRate {
                    ping["bitrate"] = rate.measured
                    ping["targetBitrate"] = rate.target
                }
                sendControl(ping)
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
        guard !guests.isEmpty else { return }
        let whose = guests.count == 1 ? "your friend’s connection" : "the slowest friend’s connection"
        pictureNote = String(format: "Picture: %.1f Mbit/s (adjusts to %@)", Double(rate) / 1_000_000, whose)
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

    private func handleControl(_ payload: Data, peer: UInt8) async {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              json["type"] as? String == "hello",
              let deviceID = json["deviceId"] as? String else { return }
        reconnectAttempts = 0
        if var guest = guests[deviceID] {
            guest.dropTask?.cancel()
            guest.dropTask = nil
            guest.peer = peer
            guests[deviceID] = guest
            peerSeats.set(peer: peer, seat: guest.seat)
            sendControl(["type": "welcome", "seat": guest.seat], to: peer)
            await GBearStreamHostManager.shared.requestRelayKeyframe()
            refreshGuestStatus()
            return
        }
        guard !joiningDeviceIDs.contains(deviceID) else { return }
        joiningDeviceIDs.insert(deviceID)
        defer { joiningDeviceIDs.remove(deviceID) }
        let trimmed = (json["deviceName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = trimmed.isEmpty ? "Remote Mac" : trimmed
        let preferred = json["preferredSeat"] as? Int
        let seatPref = (preferred ?? 0) >= 1 ? preferred : nil
        statusMessage = "\(name) connected. Starting the stream…"
        if guests.isEmpty {
            bitrate.reset()
            await GBearStreamHostManager.shared.setRelaySinks(
                video: { [videoPump, bitrate] packet in
                    let frame = GBearTunnelFrame.pack(channel: .video, payload: packet)
                    let keyframe = packet.count > 8 && (packet[8] & 1) != 0
                    bitrate.noteVideoSent(bytes: frame.count)
                    videoPump.enqueue(frame, keyframe: keyframe)
                },
                audio: { [audioPump] packet in
                    let frame = GBearTunnelFrame.pack(channel: .audio, payload: packet)
                    audioPump.enqueue(frame, keyframe: false)
                }
            )
        }
        let result = await GBearStreamHostManager.shared.attachRelayGuest(
            deviceID: deviceID,
            deviceName: name,
            preferredSeat: seatPref
        )
        guard isRunning else {
            if case .seated = result {
                await GBearStreamHostManager.shared.releaseRelayGuest(deviceID: deviceID)
            }
            return
        }
        guard case .seated(let seat) = result else {
            if case .sessionFull = result {
                sendControl(["type": "error", "error": "This session is full. Ask the host to free a player slot."], to: peer)
                statusMessage = "\(name) could not join: every player slot is taken."
            } else {
                sendControl(["type": "error", "error": "Could not join. Allow Screen Recording for GBear and try again."], to: peer)
                statusMessage = "Could not start the stream. Allow Screen Recording for GBear, then start the remote session again."
            }
            if guests.isEmpty {
                await GBearStreamHostManager.shared.setRelaySinks(video: nil, audio: nil)
            }
            return
        }
        guests[deviceID] = RelayGuest(name: name, seat: seat, peer: peer)
        peerSeats.set(peer: peer, seat: seat)
        await GBearStreamHostManager.shared.noteStreamEvent("friend joined as Player \(seat)")
        sendControl(["type": "welcome", "seat": seat], to: peer)
        updatePictureNote(bitrate.currentBitRate)
        if pingTask == nil { startPings() }
        if !AccessibilityPermission.isGranted {
            AccessibilityPermission.promptIfNeeded()
        }
        refreshGuestStatus()
    }

    private func dropGuest(deviceID: String) async {
        guard let guest = guests.removeValue(forKey: deviceID) else { return }
        guest.dropTask?.cancel()
        await GBearStreamHostManager.shared.noteStreamEvent("friend left (Player \(guest.seat))")
        peerSeats.remove(peer: guest.peer)
        if guests.isEmpty {
            stopPings()
            await GBearStreamHostManager.shared.setRelaySinks(video: nil, audio: nil)
        }
        await GBearStreamHostManager.shared.releaseRelayGuest(deviceID: deviceID)
        refreshGuestStatus(left: guest)
    }

    private static let waitingMessage = "Send the invite line to your friends. Up to \(GBearLocalRelayServer.maxGuests) can join with it. Leave this screen open. When they join, launch the game and set up each player in the emulator’s controller settings."

    private func refreshGuestStatus(left: RelayGuest? = nil) {
        let seated = guests.values.sorted { $0.seat < $1.seat }
        guard !seated.isEmpty else {
            if let left {
                statusMessage = "\(left.name) left. The invite still works if they join again."
            } else {
                statusMessage = Self.waitingMessage
            }
            return
        }
        guard AccessibilityPermission.isGranted else {
            let players = seated.map { "Player \($0.seat)" }.joined(separator: ", ")
            statusMessage = "Friends joined as \(players), but their controllers can’t reach the game yet. Allow \(AccessibilityPermission.settingsAppName) in System Settings → Privacy & Security → Accessibility, then quit and reopen GBear."
            return
        }
        let prefix = left.map { "\($0.name) left. " } ?? ""
        if seated.count == 1, let guest = seated.first {
            statusMessage = prefix + "Your friend is Player \(guest.seat). Launch the game. In the emulator, set Player 1 to your controller. For Player \(guest.seat), choose the keyboard, then click each button slot while your friend presses that button. This Mac’s speakers stay quiet while they are connected."
        } else {
            let roster = seated.map { "\($0.name) is Player \($0.seat)" }.joined(separator: ", ")
            statusMessage = prefix + "\(roster). Launch the game. In the emulator, set Player 1 to your controller. For each friend’s player, choose the keyboard, then click each button slot while that friend presses the button. This Mac’s speakers stay quiet while friends are connected."
        }
    }

    /// Nil [peer] sends to every friend.
    private func sendControl(_ json: [String: Any], to peer: UInt8? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        let frame = GBearTunnelFrame.pack(channel: .control, payload: data)
        socket?.send(peer.map { GBearTunnelPeerFrame.wrap(peer: $0, frame: frame) } ?? frame)
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

/// Relay peer number → seat, read off the main actor for each controller packet.
private final class PeerSeatTable: @unchecked Sendable {
    private let lock = NSLock()
    private var seats: [UInt8: UInt8] = [:]

    func seat(for peer: UInt8) -> UInt8? {
        lock.lock()
        defer { lock.unlock() }
        return seats[peer]
    }

    func set(peer: UInt8, seat: Int) {
        lock.lock()
        seats[peer] = UInt8(clamping: seat)
        lock.unlock()
    }

    func remove(peer: UInt8) {
        lock.lock()
        seats[peer] = nil
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        seats.removeAll()
        lock.unlock()
    }
}

/// Drops stale frames so a slow link cannot queue seconds of picture.
/// H.264 frames depend on the one before, so once a video frame is dropped every frame up to
/// the next keyframe is dropped too; sending them would smear the picture until then.
/// Audio arrives as 10 ms chunks, 100 a second, so it keeps a short FIFO instead: a big video
/// frame on the same socket would otherwise make it discard chunk after chunk (audible tearing).
final class GBearRelaySendPump: @unchecked Sendable {
    private let lock = NSLock()
    private let dependentFrames: Bool
    private let maxPending: Int
    private var sending = false
    private var pending: [Data] = []
    private var awaitingKeyframe = false
    var send: (@Sendable (Data, @escaping @Sendable () -> Void) -> Void)?
    var onDrop: (@Sendable () -> Void)?

    init(dependentFrames: Bool, maxPending: Int = 1) {
        self.dependentFrames = dependentFrames
        self.maxPending = max(1, maxPending)
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
            if dependentFrames {
                if keyframe || pending.isEmpty {
                    pending = [data]
                    lock.unlock()
                    return
                }
                awaitingKeyframe = true
                pending.removeAll()
                let dropped = onDrop
                lock.unlock()
                dropped?()
                return
            }
            pending.append(data)
            if pending.count > maxPending {
                pending.removeFirst(pending.count - maxPending)
            }
            lock.unlock()
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
        let deliver = send
        guard deliver != nil, !pending.isEmpty else {
            pending.removeAll()
            sending = false
            lock.unlock()
            return
        }
        let next = pending.removeFirst()
        lock.unlock()
        deliver?(next) { [weak self] in
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

import AVFoundation
import CoreMedia
import Foundation
import SwiftUI

/// Computer-to-computer guest: pair with a host Mac, receive video/audio, send local pads as GBG1.
@MainActor
@Observable
final class GBearStreamGuestManager {
    static let shared = GBearStreamGuestManager()

    enum Phase: Equatable {
        case idle
        case pairing
        case connected
        case streaming
        case failed(String)
    }

    var hostAddress: String = ""
    var inviteLine: String = ""
    var preferredSeat: Int = 0
    var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            syncVideoWindow()
        }
    }
    var statusMessage: String = "Enter a host LAN IP to join as a computer guest." {
        didSet { GBearGuestVideoWindow.shared.updateTitle(statusMessage) }
    }
    var remoteStatusMessage: String = "Paste the invite line from the host Mac."
    var assignedSeat: Int = 1

    private let video = GBearVideoStreamClient()
    private let audio = GBearAudioStreamClient()
    private var padSender: GBearGuestGamepadSender?
    private var relaySocket: GBearRelayWebSocket?
    private var relayURL: URL?
    private var wantsRelay = false
    private var relayEpoch = UUID()
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var stayAwake: NSObjectProtocol?
    private var deviceID: String {
        let key = "gbear.guest.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    private var deviceName: String {
        "\(ProcessInfo.processInfo.hostName) (computer)"
    }

    func pairAndJoin() async {
        let host = hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            phase = .failed("Enter the host Mac’s LAN IP.")
            return
        }
        phase = .pairing
        statusMessage = "Asking host to pair…"
        do {
            _ = try await post(host: host, path: "/gbear/v1/pair/request", body: [
                "deviceId": deviceID,
                "deviceName": deviceName,
                "clientKind": GBearCoopClientKind.computerGuest.rawValue,
            ])
            let deadline = Date().addingTimeInterval(5 * 60)
            while Date() < deadline {
                let status = try await getStatus(host: host, deviceID: deviceID)
                if status == "paired" {
                    phase = .connected
                    statusMessage = "Paired. Starting stream…"
                    await startStream(host: host)
                    return
                }
                if status == "denied" {
                    phase = .failed("Host denied pairing.")
                    return
                }
                statusMessage = "Waiting for approval on the host Mac…"
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            phase = .failed("Timed out waiting for host to approve pairing.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func joinRemote() async {
        guard let parsed = Self.parseInviteLine(inviteLine) else {
            phase = .failed("Paste the full invite line from the host.")
            remoteStatusMessage = "Paste the full invite line from the host. It starts with GBEAR1."
            return
        }
        phase = .pairing
        remoteStatusMessage = "Connecting through the relay…"
        wantsRelay = true
        reconnectAttempts = 0
        beginStayAwake()
        relayEpoch = UUID()
        padSender?.stop()
        padSender = nil
        relaySocket?.close()
        relaySocket = nil
        video.stop()
        audio.stop()
        GBearGuestVideoRenderer.shared.clear()
        let coord = GBearSessionCoordinatorClient.shared
        coord.configure(baseURLString: parsed.baseURL.absoluteString)
        let signedIn = await coord.signIn(
            idToken: "dev:guest@gbear.local",
            role: "guest",
            deviceID: deviceID
        )
        guard signedIn else {
            failRelayJoin(coord.lastError ?? "Could not reach the host’s relay.")
            return
        }
        guard let sessionID = await coord.redeemInvite(parsed.code, deviceID: deviceID, deviceName: deviceName) else {
            failRelayJoin(coord.lastError ?? "That invite was not accepted.")
            return
        }
        guard let socketURL = GBearRelayWebSocket.relayURL(
            base: parsed.baseURL,
            deviceID: deviceID,
            sessionID: sessionID
        ) else {
            failRelayJoin("The invite address is not valid.")
            return
        }
        video.onPixelBuffer = { frame in
            GBearGuestVideoRenderer.shared.display(frame)
        }
        video.onEnded = { [weak self] reason in
            Task { @MainActor in
                self?.remoteStatusMessage = "Video ended (\(reason))"
            }
        }
        audio.startPlayback()
        relayURL = socketURL
        openRelaySocket(socketURL)
        remoteStatusMessage = "Waiting for the host…"
    }

    private func openRelaySocket(_ url: URL) {
        let epoch = relayEpoch
        let videoClient = video
        let audioClient = audio
        let socket = GBearRelayWebSocket()
        relaySocket = socket
        socket.setHandlers(
            onBinary: { [weak socket] data in
                guard let (channel, payload) = GBearTunnelFrame.unpack(data) else { return }
                switch channel {
                case .video:
                    videoClient.ingest(payload)
                case .audio:
                    audioClient.ingest(payload)
                case .control:
                    // Answer right here, not after a main-actor hop, so the host's round trip
                    // measures the network queue rather than this Mac's UI work.
                    if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                       json["type"] as? String == "ping",
                       let sent = json["t"] {
                        if let pong = try? JSONSerialization.data(withJSONObject: ["type": "pong", "t": sent]) {
                            socket?.send(GBearTunnelFrame.pack(channel: .control, payload: pong))
                        }
                        return
                    }
                    Task { @MainActor in
                        GBearStreamGuestManager.shared.handleRelayControl(payload)
                    }
                case .input:
                    break
                }
            },
            onText: { text in
                Task { @MainActor in
                    GBearStreamGuestManager.shared.handleRelayText(text)
                }
            },
            onClose: { reason in
                Task { @MainActor in
                    GBearStreamGuestManager.shared.handleRelayClosed(reason, epoch: epoch)
                }
            }
        )
        socket.connect(url)
    }

    private func handleRelayClosed(_ reason: String, epoch: UUID) {
        guard wantsRelay, relayEpoch == epoch else { return }
        guard phase == .streaming || phase == .pairing || phase == .connected else { return }
        scheduleRelayReconnect(reason)
    }

    private func failRelayJoin(_ message: String) {
        wantsRelay = false
        endStayAwake()
        phase = .failed(message)
        remoteStatusMessage = message
    }

    private func scheduleRelayReconnect(_ reason: String) {
        guard reconnectTask == nil else { return }
        reconnectAttempts += 1
        if reconnectAttempts > 5 {
            let message = "Lost the host (\(reason)). Paste the invite and join again."
            wantsRelay = false
            phase = .failed(message)
            remoteStatusMessage = message
            return
        }
        remoteStatusMessage = "Connection dropped. Reconnecting…"
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            reconnectTask = nil
            guard !Task.isCancelled, wantsRelay, let relayURL else { return }
            openRelaySocket(relayURL)
        }
    }

    func stop() async {
        wantsRelay = false
        reconnectTask?.cancel()
        reconnectTask = nil
        relayURL = nil
        endStayAwake()
        relayEpoch = UUID()
        padSender?.stop()
        padSender = nil
        GBearHostLocalGamepad.shared.reclaimFromGuestSender()
        relaySocket?.close()
        relaySocket = nil
        video.stop()
        audio.stop()
        GBearGuestVideoRenderer.shared.clear()
        let host = hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty {
            _ = try? await post(host: host, path: "/gbear/v1/stream/stop", body: ["deviceId": deviceID])
        }
        if phase == .streaming || phase == .connected || phase == .pairing {
            phase = .idle
            statusMessage = "Disconnected."
            remoteStatusMessage = "Disconnected."
        }
        GBearGuestVideoWindow.shared.close()
    }

    private func syncVideoWindow() {
        switch phase {
        case .streaming:
            GBearGuestVideoWindow.shared.show(title: statusMessage) { [weak self] in
                Task { await self?.stop() }
            }
        case .idle, .failed:
            GBearGuestVideoWindow.shared.close()
        case .pairing, .connected:
            break
        }
    }

    fileprivate func handleRelayText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        if type == "relay_ready" {
            sendRelayHello()
            remoteStatusMessage = "Connected. Waiting for the host to start the picture…"
        } else         if type == "peer_left" {
            guard wantsRelay else { return }
            remoteStatusMessage = "The host connection blipped. Reconnecting…"
            scheduleRelayReconnect("host left")
        }
    }

    fileprivate func handleRelayControl(_ payload: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = json["type"] as? String else { return }
        if type == "welcome" {
            reconnectAttempts = 0
            let seat = json["seat"] as? Int ?? 2
            assignedSeat = seat
            startRelayPad(seat: seat)
            phase = .streaming
            remoteStatusMessage = "Playing as Player \(seat). The host sets up your controller in the game while you press each button."
            statusMessage = remoteStatusMessage
        } else if type == "error" {
            let message = json["error"] as? String ?? "The host rejected the join."
            phase = .failed(message)
            remoteStatusMessage = message
        }
    }

    private func sendRelayHello() {
        let body: [String: Any] = [
            "type": "hello",
            "deviceId": deviceID,
            "deviceName": deviceName,
            "preferredSeat": preferredSeat,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        relaySocket?.send(GBearTunnelFrame.pack(channel: .control, payload: data))
    }

    private func startRelayPad(seat: Int) {
        padSender?.stop()
        let socket = relaySocket
        let sender = GBearGuestGamepadSender(joinSeat: seat) { packet in
            let frame = GBearTunnelFrame.pack(channel: .input, payload: packet)
            socket?.send(frame)
        }
        GBearHostLocalGamepad.shared.yieldToGuestSender()
        sender.start()
        padSender = sender
    }

    /// Messaging apps wrap the long address at hyphens, so a pasted line can arrive split across
    /// lines. The address never contains spaces, so everything after the code is joined back together.
    private static func parseInviteLine(_ raw: String) -> (code: String, baseURL: URL)? {
        let invisible: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00AD}"]
        let parts = String(raw.filter { !invisible.contains($0) })
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let code: String
        let urlText: String
        if parts.count >= 3, parts[0].caseInsensitiveCompare("GBEAR1") == .orderedSame {
            code = parts[1]
            urlText = parts[2...].joined()
        } else if parts.count >= 2, parts[1].contains("://") {
            code = parts[0]
            urlText = parts[1...].joined()
        } else {
            return nil
        }
        var trimmed = urlText
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), url.host != nil else { return nil }
        return (code.uppercased(), url)
    }

    private func startStream(host: String) async {
        do {
            var body: [String: Any] = [
                "deviceId": deviceID,
                "deviceName": deviceName,
                "clientKind": GBearCoopClientKind.computerGuest.rawValue,
                "width": 1920,
                "height": 1080,
                "fps": 60,
            ]
            if preferredSeat >= 1 {
                body["preferredSeat"] = preferredSeat
            }
            let json = try await post(host: host, path: "/gbear/v1/stream/start", body: body)
            guard json["ok"] as? Bool == true else {
                phase = .failed(json["error"] as? String ?? "Stream start failed.")
                return
            }
            let seat = json["seat"] as? Int ?? 1
            assignedSeat = seat
            let videoPort = UInt16(json["videoPort"] as? Int ?? Int(GBearStreamPorts.videoTCP))
            let audioPort = UInt16(json["audioTcpPort"] as? Int ?? Int(GBearStreamPorts.audioTCP))
            let inputPort = UInt16(json["inputPort"] as? Int ?? Int(GBearStreamPorts.inputUDP))
            video.onPixelBuffer = { frame in
                GBearGuestVideoRenderer.shared.display(frame)
            }
            video.onEnded = { [weak self] reason in
                Task { @MainActor in
                    self?.statusMessage = "Video ended (\(reason))"
                }
            }
            video.start(host: host, port: videoPort)
            audio.start(host: host, port: audioPort)
            let sender = GBearGuestGamepadSender(host: host, port: inputPort, joinSeat: seat)
            GBearHostLocalGamepad.shared.yieldToGuestSender()
            beginStayAwake()
            sender.start()
            padSender = sender
            phase = .streaming
            statusMessage = "Playing as Player \(seat) on \(host)"
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func getStatus(host: String, deviceID: String) async throws -> String {
        let url = URL(string: "http://\(host):\(GBearStreamPorts.controlHTTP)/gbear/v1/pair/status?deviceId=\(deviceID)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["status"] as? String ?? "unknown"
    }

    @discardableResult
    private func post(host: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = URL(string: "http://\(host):\(GBearStreamPorts.controlHTTP)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status == 409 {
            throw NSError(
                domain: "GBearGuest",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: json["error"] as? String ?? "Session full"]
            )
        }
        if status == 403 {
            throw NSError(domain: "GBearGuest", code: status, userInfo: [NSLocalizedDescriptionKey: "Not paired with host."])
        }
        return json
    }

    private func beginStayAwake() {
        guard stayAwake == nil else { return }
        stayAwake = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "GBear is in a remote co-op session"
        )
    }

    private func endStayAwake() {
        guard let stayAwake else { return }
        ProcessInfo.processInfo.endActivity(stayAwake)
        self.stayAwake = nil
    }
}

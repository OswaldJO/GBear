import Foundation
import Network

/// HTTP control server for Playnite streaming (pairing + session).
actor PlayniteStreamControlServer {
    struct PendingPairRequest: Sendable, Codable, Equatable, Identifiable {
        let deviceID: String
        let deviceName: String
        let createdAt: Date

        var id: String { deviceID }
    }

    struct PairedDevice: Sendable, Codable {
        let deviceID: String
        let name: String
        let pairedAt: Date
    }

    private var listener: NWListener?
    private var pendingByDeviceID: [String: PendingPairRequest] = [:]
    private var deniedDeviceIDs: Set<String> = []
    private var pairedDevices: [PairedDevice] = []
    private var captureReady = false
    private var videoStreaming = false
    private var coopSession: PlayniteCoopSessionState?
    private let storeURL: URL

    var onStreamStartRequested: (@Sendable (String, Int, Int, Int) async -> Void)?
    var onStreamStopRequested: (@Sendable () async -> Void)?
    var onPairingQueueChanged: (@Sendable () async -> Void)?
    var onSessionChanged: (@Sendable () async -> Void)?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storeURL = base
            .appending(path: "GBear", directoryHint: .isDirectory)
            .appending(path: "playnite-stream", directoryHint: .isDirectory)
            .appending(path: "paired-devices.json")
        pairedDevices = (try? Self.loadPaired(from: storeURL)) ?? []
    }

    var isListening: Bool { listener != nil }

    func setCaptureReady(_ ready: Bool) {
        captureReady = ready
    }

    func setVideoStreaming(_ active: Bool) {
        videoStreaming = active
    }

    func start(port: UInt16 = PlayniteStreamPorts.controlHTTP) async throws {
        if listener != nil { return }

        let nwPort = NWEndpoint.Port(rawValue: port)!
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handle(connection: connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        DebugLog.log("Playnite control server listening on port \(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func pendingRequests() -> [PendingPairRequest] {
        pendingByDeviceID.values.sorted { $0.createdAt < $1.createdAt }
    }

    func approve(deviceID: String) -> Bool {
        guard let pending = pendingByDeviceID.removeValue(forKey: deviceID) else { return false }
        deniedDeviceIDs.remove(deviceID)
        let device = PairedDevice(deviceID: pending.deviceID, name: pending.deviceName, pairedAt: Date())
        pairedDevices.removeAll { $0.deviceID == device.deviceID }
        pairedDevices.append(device)
        try? Self.savePaired(pairedDevices, to: storeURL)
        notifyPairingQueueChanged()
        DebugLog.log("Playnite pairing approved for \(pending.deviceName)")
        return true
    }

    func deny(deviceID: String) -> Bool {
        guard let pending = pendingByDeviceID.removeValue(forKey: deviceID) else { return false }
        deniedDeviceIDs.insert(deviceID)
        notifyPairingQueueChanged()
        DebugLog.log("Playnite pairing denied for \(pending.deviceName)")
        return true
    }

    /// Companion withdrew a pending request (not a Mac deny).
    func cancelPending(deviceID: String) -> Bool {
        guard let pending = pendingByDeviceID.removeValue(forKey: deviceID) else { return false }
        deniedDeviceIDs.remove(deviceID)
        notifyPairingQueueChanged()
        DebugLog.log("Playnite pairing cancelled by companion: \(pending.deviceName)")
        return true
    }

    func pairStatus(deviceID: String) -> String {
        // Pending wins over stored pairing so companion "Pair again" waits for Mac approval.
        if pendingByDeviceID[deviceID] != nil {
            return "pending"
        }
        if pairedDevices.contains(where: { $0.deviceID == deviceID }) {
            return "paired"
        }
        if deniedDeviceIDs.contains(deviceID) {
            return "denied"
        }
        return "unknown"
    }

    func isPaired(deviceID: String) -> Bool {
        pairedDevices.contains { $0.deviceID == deviceID }
    }

    func pairedNames() -> [String] {
        pairedDevices.map(\.name)
    }

    func pairedDeviceName(deviceID: String) -> String? {
        pairedDevices.first { $0.deviceID == deviceID }?.name
    }

    func baselineDeviceIDs() -> [String] {
        pairedDevices.map(\.deviceID)
    }

    func setStreamHandlers(
        onStart: @escaping @Sendable (String, Int, Int, Int) async -> Void,
        onStop: @escaping @Sendable () async -> Void
    ) {
        onStreamStartRequested = onStart
        onStreamStopRequested = onStop
    }

    func setPairingQueueHandler(_ handler: @escaping @Sendable () async -> Void) {
        onPairingQueueChanged = handler
    }

    func setSessionChangedHandler(_ handler: @escaping @Sendable () async -> Void) {
        onSessionChanged = handler
    }

    func currentSession() -> PlayniteCoopSessionState? {
        coopSession
    }

    @discardableResult
    func ensureSession() -> PlayniteCoopSessionState {
        if let coopSession { return coopSession }
        let created = PlayniteCoopSessionState(
            sessionID: UUID().uuidString,
            createdAt: Date(),
            seats: [],
            cursorOwnerDeviceID: nil
        )
        coopSession = created
        notifySessionChanged()
        return created
    }

    func endSession() {
        coopSession = nil
        notifySessionChanged()
    }

    func reassignSeat(deviceID: String, seat: Int) -> Bool {
        guard var session = coopSession else { return false }
        switch session.reassign(deviceID: deviceID, toSeat: seat) {
        case .success:
            coopSession = session
            notifySessionChanged()
            return true
        case .failure:
            return false
        }
    }

    func setCursorOwner(deviceID: String) -> Bool {
        guard var session = coopSession, session.seat(for: deviceID) != nil else { return false }
        session.cursorOwnerDeviceID = deviceID
        coopSession = session
        notifySessionChanged()
        return true
    }

    private func notifyPairingQueueChanged() {
        guard let onPairingQueueChanged else { return }
        Task { await onPairingQueueChanged() }
    }

    private func notifySessionChanged() {
        guard let onSessionChanged else { return }
        Task { await onSessionChanged() }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        readHTTPRequest(on: connection, buffer: Data())
    }

    private func readHTTPRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            if let complete = Self.firstCompleteHTTPRequest(in: accumulated) {
                Task {
                    let response = await self.route(complete)
                    connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
                return
            }

            if error != nil || isComplete {
                connection.cancel()
                return
            }

            Task { await self.readHTTPRequest(on: connection, buffer: accumulated) }
        }
    }

    private struct ParsedHTTPRequest {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data
    }

    private static func firstCompleteHTTPRequest(in data: Data) -> ParsedHTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }

        let headerLines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = headerLines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        var path = String(parts[1])
        var query: [String: String] = [:]
        if let queryIndex = path.firstIndex(of: "?") {
            let queryString = String(path[path.index(after: queryIndex)...])
            path = String(path[..<queryIndex])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        }

        var contentLength = 0
        for line in headerLines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = lower.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces)
                contentLength = Int(value ?? "") ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        let available = data.count - bodyStart
        guard available >= contentLength else { return nil }

        let body = data.subdata(in: bodyStart ..< (bodyStart + contentLength))
        return ParsedHTTPRequest(method: method, path: path, query: query, body: body)
    }

    private func route(_ request: ParsedHTTPRequest) async -> String {
        let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]

        switch (request.method, request.path) {
        case ("GET", "/playnite/v1/status"), ("GET", "/playnite/v1/serverinfo"):
            var body: [String: Any] = [
                "protocol": PlayniteStreamPorts.protocolVersion,
                "hostname": ProcessInfo.processInfo.hostName,
                "captureReady": captureReady,
                "videoStreaming": videoStreaming,
                "pairedCount": pairedDevices.count,
                "pendingCount": pendingByDeviceID.count,
                "videoPort": PlayniteStreamPorts.videoTCP,
                "audioPort": PlayniteStreamPorts.audioUDP,
                "audioTcpPort": PlayniteStreamPorts.audioTCP,
                "inputPort": PlayniteStreamPorts.inputUDP,
                "maxViewers": PlayniteStreamPorts.maxCoopViewers,
            ]
            if let coopSession {
                body["session"] = coopSession.json
            } else {
                body["session"] = NSNull()
            }
            return httpResponse(status: 200, body: body)
        case ("POST", "/playnite/v1/session/create"):
            let created = ensureSession()
            DebugLog.log("Playnite co-op session created \(created.sessionID)")
            return httpResponse(status: 200, body: ["ok": true, "session": created.json])
        case ("GET", "/playnite/v1/session"):
            guard let coopSession else {
                return httpResponse(status: 404, body: ["ok": false, "error": "no session"])
            }
            return httpResponse(status: 200, body: ["ok": true, "session": coopSession.json])
        case ("POST", "/playnite/v1/session/join"):
            guard let deviceID = json?["deviceId"] as? String, !deviceID.isEmpty else {
                return httpResponse(status: 400, body: ["ok": false, "error": "deviceId required"])
            }
            guard isPaired(deviceID: deviceID) else {
                return httpResponse(status: 403, body: ["ok": false, "error": "not paired"])
            }
            var session = ensureSession()
            let name = pairedDeviceName(deviceID: deviceID)
                ?? (json?["deviceName"] as? String)
                ?? "Companion"
            let preferred = json?["preferredSeat"] as? Int
            switch session.join(deviceID: deviceID, deviceName: name, preferredSeat: preferred) {
            case .success(let seat):
                coopSession = session
                notifySessionChanged()
                DebugLog.log("Playnite session join \(name) seat=\(seat.seat)")
                return httpResponse(status: 200, body: [
                    "ok": true,
                    "seat": seat.seat,
                    "session": session.json,
                ])
            case .failure(.full):
                return httpResponse(status: 409, body: ["ok": false, "error": "session full"])
            case .failure:
                return httpResponse(status: 400, body: ["ok": false, "error": "join failed"])
            }
        case ("POST", "/playnite/v1/session/leave"):
            guard let deviceID = json?["deviceId"] as? String, !deviceID.isEmpty else {
                return httpResponse(status: 400, body: ["ok": false, "error": "deviceId required"])
            }
            guard var session = coopSession else {
                return httpResponse(status: 200, body: ["ok": true])
            }
            _ = session.leave(deviceID: deviceID)
            if session.seats.isEmpty {
                coopSession = nil
            } else {
                coopSession = session
            }
            notifySessionChanged()
            return httpResponse(status: 200, body: ["ok": true, "session": coopSession?.json as Any])
        case ("POST", "/playnite/v1/session/reassign"):
            guard let deviceID = json?["deviceId"] as? String,
                  let seat = json?["seat"] as? Int
            else {
                return httpResponse(status: 400, body: ["ok": false, "error": "deviceId and seat required"])
            }
            guard var session = coopSession else {
                return httpResponse(status: 404, body: ["ok": false, "error": "no session"])
            }
            switch session.reassign(deviceID: deviceID, toSeat: seat) {
            case .success:
                coopSession = session
                notifySessionChanged()
                return httpResponse(status: 200, body: ["ok": true, "session": session.json])
            case .failure:
                return httpResponse(status: 400, body: ["ok": false, "error": "reassign failed"])
            }
        case ("POST", "/playnite/v1/session/cursor-owner"):
            guard let deviceID = json?["deviceId"] as? String else {
                return httpResponse(status: 400, body: ["ok": false, "error": "deviceId required"])
            }
            guard var session = coopSession, session.seat(for: deviceID) != nil else {
                return httpResponse(status: 404, body: ["ok": false, "error": "not in session"])
            }
            session.cursorOwnerDeviceID = deviceID
            coopSession = session
            notifySessionChanged()
            return httpResponse(status: 200, body: ["ok": true, "session": session.json])
        case ("POST", "/playnite/v1/session/end"):
            endSession()
            return httpResponse(status: 200, body: ["ok": true])
        case ("POST", "/playnite/v1/pair/request"), ("POST", "/playnite/v1/pair/begin"):
            guard let deviceID = json?["deviceId"] as? String, !deviceID.isEmpty else {
                DebugLog.log("Playnite pair/request rejected: missing deviceId")
                return httpResponse(status: 400, body: ["ok": false, "error": "deviceId required"])
            }
            let deviceName = (json?["deviceName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = deviceName?.isEmpty == false ? deviceName! : "Companion"
            deniedDeviceIDs.remove(deviceID)
            pendingByDeviceID[deviceID] = PendingPairRequest(deviceID: deviceID, deviceName: name, createdAt: Date())
            notifyPairingQueueChanged()
            DebugLog.log("Playnite pair/request queued: \(name) (\(deviceID))")
            return httpResponse(status: 200, body: ["ok": true, "status": "pending"])
        case ("GET", "/playnite/v1/pair/pending"):
            let requests = pendingRequests().map {
                [
                    "deviceId": $0.deviceID,
                    "deviceName": $0.deviceName,
                    "createdAt": ISO8601DateFormatter().string(from: $0.createdAt),
                ] as [String: Any]
            }
            return httpResponse(status: 200, body: ["requests": requests])
        case ("POST", "/playnite/v1/pair/approve"), ("POST", "/playnite/v1/pair/confirm"):
            guard let deviceID = (json?["deviceId"] as? String) else {
                return httpResponse(status: 400, body: ["ok": false])
            }
            let ok = approve(deviceID: deviceID)
            return httpResponse(status: ok ? 200 : 404, body: ["ok": ok])
        case ("POST", "/playnite/v1/pair/deny"):
            guard let deviceID = json?["deviceId"] as? String else {
                return httpResponse(status: 400, body: ["ok": false])
            }
            let ok = deny(deviceID: deviceID)
            return httpResponse(status: ok ? 200 : 404, body: ["ok": ok])
        case ("POST", "/playnite/v1/pair/cancel"):
            guard let deviceID = json?["deviceId"] as? String, !deviceID.isEmpty else {
                return httpResponse(status: 400, body: ["ok": false, "error": "deviceId required"])
            }
            let ok = cancelPending(deviceID: deviceID)
            return httpResponse(status: ok ? 200 : 404, body: ["ok": ok])
        case ("GET", "/playnite/v1/pair/status"):
            guard let deviceID = request.query["deviceId"], !deviceID.isEmpty else {
                return httpResponse(status: 400, body: ["error": "deviceId required"])
            }
            return httpResponse(status: 200, body: ["status": pairStatus(deviceID: deviceID)])
        case ("GET", "/playnite/v1/pair/clients"):
            return httpResponse(status: 200, body: [
                "devices": pairedDevices.map { ["id": $0.deviceID, "name": $0.name] },
            ])
        case ("POST", "/playnite/v1/stream/start"):
            guard let deviceID = json?["deviceId"] as? String, isPaired(deviceID: deviceID) else {
                return httpResponse(status: 403, body: ["ok": false, "error": "not paired"])
            }
            let width = json?["width"] as? Int ?? 1920
            let height = json?["height"] as? Int ?? 1080
            let fps = json?["fps"] as? Int ?? 60
            var session = ensureSession()
            let name = pairedDeviceName(deviceID: deviceID) ?? "Companion"
            switch session.join(deviceID: deviceID, deviceName: name, preferredSeat: json?["preferredSeat"] as? Int) {
            case .success(let seatInfo):
                coopSession = session
                notifySessionChanged()
                PlayniteStreamSessionLog.i(
                    "Companion POST stream/start deviceId=\(deviceID) seat=\(seatInfo.seat) " +
                        "\(width)x\(height) @ \(fps)fps alreadyStreaming=\(videoStreaming)"
                )
                if let onStreamStartRequested {
                    Task { await onStreamStartRequested(deviceID, width, height, fps) }
                }
                let lanHost = LocalNetworkAddress.primaryIPv4() ?? "127.0.0.1"
                return httpResponse(status: 200, body: [
                    "ok": true,
                    "seat": seatInfo.seat,
                    "videoPort": PlayniteStreamPorts.videoTCP,
                    "audioPort": PlayniteStreamPorts.audioUDP,
                    "audioTcpPort": PlayniteStreamPorts.audioTCP,
                    "inputPort": PlayniteStreamPorts.inputUDP,
                    "host": lanHost,
                    "loopbackHost": "127.0.0.1",
                    "session": session.json,
                    "attached": videoStreaming,
                ])
            case .failure(.full):
                return httpResponse(status: 409, body: ["ok": false, "error": "session full (max 2 viewers)"])
            case .failure:
                return httpResponse(status: 400, body: ["ok": false, "error": "could not join session"])
            }
        case ("POST", "/playnite/v1/stream/stop"):
            PlayniteStreamSessionLog.i("Companion POST stream/stop")
            if let deviceID = json?["deviceId"] as? String, var session = coopSession {
                _ = session.leave(deviceID: deviceID)
                if session.seats.isEmpty {
                    coopSession = nil
                    if let onStreamStopRequested {
                        Task { await onStreamStopRequested() }
                    } else {
                        setVideoStreaming(false)
                    }
                } else {
                    coopSession = session
                    // Other viewer still connected — do not tear down capture.
                    notifySessionChanged()
                    return httpResponse(status: 200, body: ["ok": true, "captureStopped": false, "session": session.json])
                }
                notifySessionChanged()
            } else if let onStreamStopRequested {
                Task { await onStreamStopRequested() }
            } else {
                setVideoStreaming(false)
            }
            return httpResponse(status: 200, body: ["ok": true, "captureStopped": true])
        default:
            return httpResponse(status: 404, body: ["error": "not found"])
        }
    }

    private func httpResponse(status: Int, body: [String: Any]) -> String {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        let json = String(data: payload, encoding: .utf8) ?? "{}"
        return "HTTP/1.1 \(status) \(statusText(status))\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
    }

    private func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        default: return "Error"
        }
    }

    private static func loadPaired(from url: URL) throws -> [PairedDevice] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([PairedDevice].self, from: data)
    }

    private static func savePaired(_ devices: [PairedDevice], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(devices)
        try data.write(to: url, options: .atomic)
    }
}

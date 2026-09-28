import CryptoKit
import Foundation
import Network

/// Localhost session relay. The host and one guest connect outbound (the guest via a tunnel)
/// and this process copies `GBTL` bytes between them. Nothing here needs an open router port.
final class GBearLocalRelayServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "GBearRelay.server", qos: .userInitiated)
    private var listener: NWListener?
    private var sessions: [String: Session] = [:]
    private var invites: [String: Invite] = [:]
    private var rooms: [String: Room] = [:]
    private let inviteAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    private struct Session {
        var id: String
        var hostDeviceID: String
    }

    private struct Invite {
        var code: String
        var sessionID: String
        var expires: Date
    }

    private final class Room {
        var a: Client?
        var b: Client?
    }

    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        let sessionID: String
        var buffer = Data()
        var fragmentOpcode: UInt8 = 0
        var fragments = Data()
        var outboundBuffered = 0
        weak var server: GBearLocalRelayServer?

        init(connection: NWConnection, sessionID: String, server: GBearLocalRelayServer) {
            self.connection = connection
            self.sessionID = sessionID
            self.server = server
        }

        func send(opcode: UInt8, payload: Data) {
            // Shed a backed-up picture. Never drop controller or control frames (BJ-097).
            if opcode == 2, outboundBuffered > 2_000_000, GBearLocalRelayServer.isShedableMedia(payload) { return }
            let frame = GBearLocalRelayServer.frame(opcode: opcode, payload: payload)
            outboundBuffered += frame.count
            connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.server?.queue.async {
                    self.outboundBuffered = max(0, self.outboundBuffered - frame.count)
                }
            })
        }

        func sendText(_ text: String) {
            send(opcode: 1, payload: Data(text.utf8))
        }
    }

    func start(port: UInt16 = 8787) async throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!
        )
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
        try await GBearNWListenerAwait.waitUntilReady(listener)
        print("[GBearRelay] listening on 127.0.0.1:\(port)")
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for room in rooms.values {
                room.a?.connection.cancel()
                room.b?.connection.cancel()
            }
            rooms.removeAll()
            sessions.removeAll()
            invites.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHTTP(connection, buffer: Data())
    }

    private func readHTTP(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data, !data.isEmpty { accumulated.append(data) }
            if let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)),
               let headerText = String(data: accumulated[..<headerEnd.lowerBound], encoding: .utf8) {
                let headerLines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
                let contentLength = Self.contentLength(headerLines)
                let bodyStart = headerEnd.upperBound
                let available = accumulated.count - bodyStart
                if available < contentLength {
                    if error != nil || isComplete { connection.cancel(); return }
                    self.readHTTP(connection, buffer: accumulated)
                    return
                }
                let body = accumulated.subdata(in: bodyStart ..< (bodyStart + contentLength))
                let leftover = accumulated.subdata(in: (bodyStart + contentLength) ..< accumulated.count)
                if Self.isWebSocketUpgrade(headerLines), let key = Self.webSocketKey(headerLines) {
                    self.acceptWebSocket(
                        connection: connection,
                        headerLines: headerLines,
                        key: key,
                        leftover: leftover
                    )
                    return
                }
                let response = self.routeHTTP(headerLines: headerLines, body: body)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            if error != nil || isComplete || accumulated.count > 1024 * 1024 {
                connection.cancel()
                return
            }
            self.readHTTP(connection, buffer: accumulated)
        }
    }

    private func acceptWebSocket(
        connection: NWConnection,
        headerLines: [Substring],
        key: String,
        leftover: Data
    ) {
        let request = headerLines.first.map(String.init) ?? ""
        let parts = request.split(separator: " ")
        let target = parts.count >= 2 ? String(parts[1]) : ""
        let query = Self.query(from: target)
        let sessionID = query["sessionId"] ?? ""
        let deviceID = query["deviceId"] ?? ""
        guard !sessionID.isEmpty, !deviceID.isEmpty, sessions[sessionID] != nil else {
            connection.cancel()
            return
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        let response =
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        let client = Client(connection: connection, sessionID: sessionID, server: self)
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            self.queue.async {
                self.attach(client)
                if !leftover.isEmpty {
                    self.consume(client, data: leftover)
                }
                self.readWebSocket(client)
            }
        })
    }

    private func attach(_ client: Client) {
        let room = rooms[client.sessionID] ?? Room()
        if room.a == nil {
            room.a = client
        } else if room.b == nil {
            room.b = client
        } else {
            client.connection.cancel()
            return
        }
        rooms[client.sessionID] = room
        if room.a != nil, room.b != nil {
            let ready = #"{"type":"relay_ready"}"#
            room.a?.sendText(ready)
            room.b?.sendText(ready)
            print("[GBearRelay] both peers connected for \(client.sessionID.prefix(8))")
        }
    }

    private func detach(_ client: Client) {
        guard let room = rooms[client.sessionID] else { return }
        let notice = #"{"type":"peer_left"}"#
        if room.a === client {
            room.a = nil
            room.b?.sendText(notice)
        } else if room.b === client {
            room.b = nil
            room.a?.sendText(notice)
        }
        if room.a == nil, room.b == nil {
            rooms[client.sessionID] = nil
        }
    }

    private func peer(of client: Client) -> Client? {
        guard let room = rooms[client.sessionID] else { return nil }
        if room.a === client { return room.b }
        if room.b === client { return room.a }
        return nil
    }

    private func readWebSocket(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.consume(client, data: data)
            }
            if error != nil || isComplete {
                self.detach(client)
                client.connection.cancel()
                return
            }
            self.readWebSocket(client)
        }
    }

    private func consume(_ client: Client, data: Data) {
        client.buffer.append(data)
        while let parsed = Self.nextFrame(in: client.buffer) {
            client.buffer = client.buffer.count == parsed.consumed
                ? Data()
                : Data(client.buffer.dropFirst(parsed.consumed))
            let opcode = parsed.opcode
            let fin = parsed.fin
            let payload = parsed.payload
            if opcode == 0x8 {
                detach(client)
                client.connection.cancel()
                return
            }
            if opcode == 0x9 {
                client.send(opcode: 0xA, payload: payload)
                continue
            }
            if opcode == 0xA { continue }
            if opcode == 0 {
                client.fragments.append(payload)
                if fin {
                    forward(client, opcode: client.fragmentOpcode, payload: client.fragments)
                    client.fragments.removeAll(keepingCapacity: true)
                }
                continue
            }
            if !fin {
                client.fragmentOpcode = opcode
                client.fragments = payload
                continue
            }
            forward(client, opcode: opcode, payload: payload)
        }
    }

    private func forward(_ client: Client, opcode: UInt8, payload: Data) {
        guard opcode == 2 || opcode == 1 else { return }
        peer(of: client)?.send(opcode: opcode, payload: payload)
    }

    private func routeHTTP(headerLines: [Substring], body: Data) -> Data {
        guard let request = headerLines.first else {
            return Self.http(status: 400, json: ["ok": false, "error": "bad request"])
        }
        let parts = request.split(separator: " ")
        guard parts.count >= 2 else {
            return Self.http(status: 400, json: ["ok": false, "error": "bad request"])
        }
        let method = String(parts[0])
        var path = String(parts[1])
        if let query = path.firstIndex(of: "?") {
            path = String(path[..<query])
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        if method == "GET", path == "/health" {
            return Self.http(status: 200, json: ["ok": true, "service": "gbear-session"])
        }
        guard Self.bearer(headerLines) != nil else {
            return Self.http(status: 401, json: ["ok": false, "error": "missing bearer token"])
        }
        switch (method, path) {
        case ("POST", "/v1/auth/register-device"):
            let token = Self.bearer(headerLines) ?? ""
            let email = token.hasPrefix("dev:") ? String(token.dropFirst(4)) : token
            return Self.http(status: 200, json: ["ok": true, "email": email])
        case ("POST", "/v1/session/create"):
            let id = UUID().uuidString
            let hostDevice = json["hostDeviceId"] as? String ?? UUID().uuidString
            sessions[id] = Session(id: id, hostDeviceID: hostDevice)
            return Self.http(status: 200, json: [
                "ok": true,
                "session": ["sessionId": id],
            ])
        case ("POST", "/v1/session/invite"):
            guard let sessionID = json["sessionId"] as? String, sessions[sessionID] != nil else {
                return Self.http(status: 404, json: ["ok": false, "error": "session not found"])
            }
            let code = inviteCode()
            invites[code] = Invite(code: code, sessionID: sessionID, expires: Date().addingTimeInterval(30 * 60))
            return Self.http(status: 200, json: ["ok": true, "inviteCode": code])
        case ("POST", "/v1/session/redeem-invite"):
            let code = (json["inviteCode"] as? String ?? "").uppercased()
            guard let invite = invites[code], invite.expires > Date(), sessions[invite.sessionID] != nil else {
                return Self.http(status: 404, json: ["ok": false, "error": "invalid or expired invite"])
            }
            return Self.http(status: 200, json: [
                "ok": true,
                "session": ["sessionId": invite.sessionID],
            ])
        case ("POST", "/v1/session/end"):
            if let sessionID = json["sessionId"] as? String {
                sessions[sessionID] = nil
                invites = invites.filter { $0.value.sessionID != sessionID }
                if let room = rooms[sessionID] {
                    room.a?.connection.cancel()
                    room.b?.connection.cancel()
                    rooms[sessionID] = nil
                }
            }
            return Self.http(status: 200, json: ["ok": true])
        default:
            return Self.http(status: 404, json: ["ok": false, "error": "not found"])
        }
    }

    private func inviteCode() -> String {
        var code = ""
        repeat {
            code = String((0 ..< 6).map { _ in inviteAlphabet.randomElement()! })
        } while invites[code] != nil
        return code
    }

    private static func bearer(_ headerLines: [Substring]) -> String? {
        for line in headerLines.dropFirst() {
            let lower = line.lowercased()
            guard lower.hasPrefix("authorization:") else { continue }
            let value = line.split(separator: ":", maxSplits: 1).last
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            guard value.lowercased().hasPrefix("bearer ") else { return nil }
            let token = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            return token.isEmpty ? nil : token
        }
        return nil
    }

    private static func contentLength(_ headerLines: [Substring]) -> Int {
        for line in headerLines.dropFirst() {
            let lower = line.lowercased()
            guard lower.hasPrefix("content-length:") else { continue }
            let value = lower.split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return Int(value) ?? 0
        }
        return 0
    }

    private static func isWebSocketUpgrade(_ headerLines: [Substring]) -> Bool {
        headerLines.dropFirst().contains { $0.lowercased().contains("upgrade:") && $0.lowercased().contains("websocket") }
            || headerLines.dropFirst().contains { line in
                let lower = line.lowercased()
                return lower.hasPrefix("upgrade:") && lower.contains("websocket")
            }
    }

    private static func webSocketKey(_ headerLines: [Substring]) -> String? {
        for line in headerLines.dropFirst() {
            guard line.lowercased().hasPrefix("sec-websocket-key:") else { continue }
            return line.split(separator: ":", maxSplits: 1).last
                .map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    private static func query(from target: String) -> [String: String] {
        guard let index = target.firstIndex(of: "?") else { return [:] }
        var query: [String: String] = [:]
        let raw = target[target.index(after: index)...]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            query[key] = value
        }
        return query
    }

    private struct ParsedFrame {
        var fin: Bool
        var opcode: UInt8
        var payload: Data
        var consumed: Int
    }

    private static func nextFrame(in input: Data) -> ParsedFrame? {
        guard input.count >= 2 else { return nil }
        let buffer = input.startIndex == 0 ? input : Data(input)
        let fin = (buffer[0] & 0x80) != 0
        let opcode = buffer[0] & 0x0F
        let masked = (buffer[1] & 0x80) != 0
        var length = Int(buffer[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer[2]) << 8 | Int(buffer[3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            var value: UInt64 = 0
            for index in 0 ..< 8 {
                value = (value << 8) | UInt64(buffer[2 + index])
            }
            guard value <= 8 * 1024 * 1024 else { return nil }
            length = Int(value)
            offset = 10
        }
        let maskLength = masked ? 4 : 0
        let total = offset + maskLength + length
        guard buffer.count >= total else { return nil }
        var payload = Data(buffer.subdata(in: (offset + maskLength) ..< total))
        if masked {
            let mask = buffer.subdata(in: offset ..< (offset + 4))
            for index in payload.indices {
                payload[index] ^= mask[(index - payload.startIndex) % 4]
            }
        }
        return ParsedFrame(fin: fin, opcode: opcode, payload: payload, consumed: total)
    }

    /// Video and audio can be dropped when a peer falls behind. Controller input cannot.
    private static func isShedableMedia(_ payload: Data) -> Bool {
        guard payload.count >= 5 else { return true }
        let magic = payload.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard magic == GBearTunnelFrame.magic else { return true }
        return payload[4] == GBearTunnelFrame.Channel.video.rawValue
            || payload[4] == GBearTunnelFrame.Channel.audio.rawValue
    }

    private static func frame(opcode: UInt8, payload: Data) -> Data {
        var header = Data()
        header.append(0x80 | opcode)
        let count = payload.count
        if count < 126 {
            header.append(UInt8(count))
        } else if count < 65_536 {
            header.append(126)
            header.append(UInt8((count >> 8) & 0xFF))
            header.append(UInt8(count & 0xFF))
        } else {
            header.append(127)
            var length = UInt64(count).bigEndian
            withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        }
        header.append(payload)
        return header
    }

    private static func http(status: Int, json: [String: Any]) -> Data {
        let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(payload.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(payload)
        return data
    }
}

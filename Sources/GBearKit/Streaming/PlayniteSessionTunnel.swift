import Foundation
import Network

/// Multiplexed session tunnel over a single TCP connection (LAN fallback or coordinator relay).
/// Framing: magic `GBTL` (4) + channel (1) + length (4 LE) + payload.
actor PlayniteSessionTunnel {
    enum Channel: UInt8 {
        case control = 1
        case video = 2
        case audio = 3
        case input = 4
    }

    static let magic: UInt32 = 0x4C_54_42_47 // "GBTL" little-endian

    private var connection: NWConnection?
    private var onChannel: (@Sendable (Channel, Data) -> Void)?

    var isConnected: Bool { connection != nil }

    func setHandler(_ handler: @escaping @Sendable (Channel, Data) -> Void) {
        onChannel = handler
    }

    func connect(host: String, port: UInt16) async throws {
        await disconnect()
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                Task { await self.disconnect() }
            }
            if case .cancelled = state {
                Task { await self.disconnect() }
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        try await waitReady(connection)
        receiveLoop()
        print("[SessionTunnel] connected to \(host):\(port)")
    }

    /// Connect outbound to coordinator WS-bridged TCP is done by clients; this helper
    /// accepts an already-open NWConnection (e.g. after ICE or local relay).
    func attach(connection: NWConnection) async {
        await disconnect()
        self.connection = connection
        receiveLoop()
    }

    func send(channel: Channel, payload: Data) {
        guard let connection else { return }
        var frame = Data()
        var magic = Self.magic.littleEndian
        frame.append(Data(bytes: &magic, count: 4))
        frame.append(channel.rawValue)
        var length = UInt32(payload.count).littleEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { error in
            if let error {
                print("[SessionTunnel] send failed: \(error.localizedDescription)")
            }
        })
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    private func waitReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume()
                case .failed(let error):
                    cont.resume(throwing: error)
                case .cancelled:
                    cont.resume(throwing: CancellationError())
                default:
                    break
                }
            }
        }
    }

    private func receiveLoop() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 9, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                if let data, !data.isEmpty {
                    await self.handleIncoming(data)
                }
                if error != nil || isComplete {
                    await self.disconnect()
                    return
                }
                await self.receiveLoop()
            }
        }
    }

    private var buffer = Data()

    private func handleIncoming(_ data: Data) {
        buffer.append(data)
        while buffer.count >= 9 {
            let magic = buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
            guard magic == Self.magic else {
                buffer.removeFirst()
                continue
            }
            let channelRaw = buffer[4]
            let length = buffer.subdata(in: 5 ..< 9).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
            let total = 9 + Int(length)
            guard buffer.count >= total else { return }
            let payload = buffer.subdata(in: 9 ..< total)
            buffer.removeSubrange(0 ..< total)
            if let channel = Channel(rawValue: channelRaw) {
                onChannel?(channel, payload)
            }
        }
    }
}

/// Host-side helper: when WAN tunnel is active, fan video/audio into the mux and accept input.
@MainActor
final class PlayniteSessionTunnelHost {
    static let shared = PlayniteSessionTunnelHost()

    private let tunnel = PlayniteSessionTunnel()
    private(set) var active = false

    func startListeningForRelay(coordinatorBaseURL: URL, sessionID: String, deviceID: String) async {
        // Companion and Mac both open WS relay to coordinator; Mac uses TCP mux locally when
        // a reverse proxy maps WS→TCP. For v1, document WS relay in Node and keep LAN primary.
        // Direct TCP connect to optional relay port:
        let host = coordinatorBaseURL.host ?? "127.0.0.1"
        let port = UInt16(coordinatorBaseURL.port ?? 8788)
        do {
            try await tunnel.connect(host: host, port: port)
            await tunnel.setHandler { channel, data in
                Task { @MainActor in
                    PlayniteSessionTunnelHost.shared.handle(channel: channel, data: data)
                }
            }
            active = true
        } catch {
            print("[SessionTunnelHost] relay connect failed: \(error.localizedDescription)")
            active = false
        }
    }

    func sendVideo(_ packet: Data) {
        guard active else { return }
        Task { await tunnel.send(channel: .video, payload: packet) }
    }

    func sendAudio(_ packet: Data) {
        guard active else { return }
        Task { await tunnel.send(channel: .audio, payload: packet) }
    }

    private func handle(channel: PlayniteSessionTunnel.Channel, data: Data) {
        switch channel {
        case .input:
            if let gamepad = PlayniteGamepadEventFormat.parse(data) {
                Task { await PlayniteVirtualGamepadManager.shared.apply(gamepad) }
            } else if let keyboard = PlayniteKeyboardEventFormat.parse(data) {
                PlayniteKeyboardPlayback.handle(keyboard)
            } else if let touch = PlayniteInputEventFormat.parse(data) {
                PlayniteRemoteInputPlayback.handle(touch)
            }
        case .control, .video, .audio:
            break
        }
    }

    func stop() {
        active = false
        Task { await tunnel.disconnect() }
    }
}

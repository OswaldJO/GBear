import Foundation
import Network

/// Broadcasts `PNV1` H.264 frames to up to two connected phone clients.
actor PlayniteVideoStreamServer {
    static let maxClients = 2

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: ClientSlot] = [:]
    private var capture: PlayniteDisplayCapture?

    private struct ClientSlot {
        let connection: NWConnection
        var waitingForKeyframe: Bool
        var sendInFlight: Bool
        var pendingPackets: [PendingPacket]
        var framesSent: Int
    }

    var isStreaming: Bool { capture != nil }

    var hasActiveListener: Bool { listener != nil }

    var connectedClientCount: Int { clients.count }

    func startListener(port: UInt16 = PlayniteStreamPorts.videoTCP) async throws {
        if listener != nil { return }
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.accept(connection: connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        try await PlayniteNWListenerAwait.waitUntilReady(listener)
        self.listener = listener
    }

    /// Screen capture + encode only (call after [startListener]).
    func startCapture(
        width: Int,
        height: Int,
        fps: Int,
        audioHandler: PlayniteDisplayCapture.AudioHandler? = nil
    ) async throws {
        if capture != nil { return }

        let capture = PlayniteDisplayCapture(
            encodedHandler: { [weak self] data, isKeyframe, w, h in
                guard let self else { return }
                Task { await self.sendFrame(data: data, isKeyframe: isKeyframe, width: w, height: h) }
            },
            audioHandler: audioHandler
        )
        try await capture.start(width: width, height: height, fps: fps)
        self.capture = capture
    }

    func startStream(
        width: Int,
        height: Int,
        fps: Int,
        audioHandler: PlayniteDisplayCapture.AudioHandler? = nil
    ) async throws {
        try await startListener()
        try await startCapture(width: width, height: height, fps: fps, audioHandler: audioHandler)
    }

    func stopStream() async {
        if let capture {
            await capture.stop()
        }
        capture = nil
        for (_, slot) in clients {
            slot.connection.cancel()
        }
        clients.removeAll()
    }

    func stopListener() async {
        guard let listener else { return }
        listener.cancel()
        await PlayniteNWListenerAwait.waitUntilCancelled(listener, timeoutSeconds: 3)
        self.listener = nil
    }

    func stop() async {
        await stopStream()
        await stopListener()
    }

    private struct PendingPacket {
        let data: Data
        let isKeyframe: Bool
        let width: UInt16
        let height: UInt16
        let payloadBytes: Int
    }

    private let maxQueuedPackets = 45

    private func accept(connection: NWConnection) {
        if clients.count >= Self.maxClients {
            // Drop oldest so a third connect can take a seat for co-op rejoin.
            if let oldest = clients.keys.first {
                clients[oldest]?.connection.cancel()
                clients.removeValue(forKey: oldest)
                print("[PlayniteVideo] dropped oldest client to accept new viewer (max \(Self.maxClients))")
            }
        }

        let id = ObjectIdentifier(connection)
        clients[id] = ClientSlot(
            connection: connection,
            waitingForKeyframe: true,
            sendInFlight: false,
            pendingPackets: [],
            framesSent: 0
        )

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleConnectionState(id: id, state: state) }
        }

        connection.start(queue: .global(qos: .userInitiated))
        PlayniteStreamSessionLog.i(
            "Phone connected to TCP video (viewers=\(clients.count)/\(Self.maxClients)); requesting keyframe"
        )
        print("[PlayniteVideo] phone connected; viewers=\(clients.count)/\(Self.maxClients)")
        capture?.requestKeyframe()
    }

    private func handleConnectionState(id: ObjectIdentifier, state: NWConnection.State) {
        switch state {
        case .ready:
            break
        case .failed(let error):
            print("[PlayniteVideo] client connection failed: \(error.localizedDescription)")
            dropClient(id: id)
        case .cancelled:
            PlayniteStreamSessionLog.i("Phone disconnected from TCP video")
            print("[PlayniteVideo] client disconnected; viewers=\(max(0, clients.count - 1))")
            dropClient(id: id)
        default:
            break
        }
    }

    private func dropClient(id: ObjectIdentifier) {
        clients.removeValue(forKey: id)
    }

    private func sendFrame(data: Data, isKeyframe: Bool, width: UInt16, height: UInt16) {
        guard !clients.isEmpty else { return }
        let packet = PlayniteVideoFrameFormat.pack(payload: data, width: width, height: height, isKeyframe: isKeyframe)
        let pending = PendingPacket(
            data: packet,
            isKeyframe: isKeyframe,
            width: width,
            height: height,
            payloadBytes: data.count
        )
        for id in Array(clients.keys) {
            guard var slot = clients[id] else { continue }
            if slot.waitingForKeyframe {
                guard isKeyframe else {
                    clients[id] = slot
                    continue
                }
                slot.waitingForKeyframe = false
            }
            slot.pendingPackets.append(pending)
            if slot.pendingPackets.count > maxQueuedPackets {
                let dropped = slot.pendingPackets.count - maxQueuedPackets
                slot.pendingPackets.removeFirst(dropped)
            }
            clients[id] = slot
            flushPendingSends(id: id)
        }
    }

    private func flushPendingSends(id: ObjectIdentifier) {
        guard var slot = clients[id], !slot.sendInFlight, !slot.pendingPackets.isEmpty else { return }
        let packet = slot.pendingPackets.removeFirst()
        slot.sendInFlight = true
        clients[id] = slot
        let connection = slot.connection
        connection.send(content: packet.data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            Task { await self.completeSend(id: id, sent: packet, error: error) }
        })
    }

    private func completeSend(id: ObjectIdentifier, sent: PendingPacket, error: NWError?) {
        guard var slot = clients[id] else { return }
        slot.sendInFlight = false
        if let error {
            print("[PlayniteVideo] send failed: \(error.localizedDescription)")
            clients[id] = slot
            dropClient(id: id)
            return
        }
        slot.framesSent += 1
        if slot.framesSent == 1 || slot.framesSent % 60 == 0 {
            let line =
                "Video sent frame #\(slot.framesSent) keyframe=\(sent.isKeyframe) " +
                "bytes=\(sent.payloadBytes) \(sent.width)x\(sent.height) queued=\(slot.pendingPackets.count) viewers=\(clients.count)"
            PlayniteStreamSessionLog.i(line)
            print("[PlayniteVideo] \(line)")
        }
        clients[id] = slot
        flushPendingSends(id: id)
    }
}

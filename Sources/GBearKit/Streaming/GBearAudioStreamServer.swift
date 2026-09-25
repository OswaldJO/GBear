import Darwin
import Foundation
import Network

/// Sends `GBA1` PCM to viewers (TCP downlink + optional UDP after `GBAS` subscribe).
actor GBearAudioStreamServer {
    static let maxClients = GBearStreamPorts.maxCoopViewers

    private var udp: GBearUDPSocket?
    private var udpSubscribers: [String: UDPSubscriber] = [:]
    private var packetsSent = 0
    private var loggedWaitingForSubscribe = false
    private var datagramsReceived = 0
    /// ~10 ms of stereo PCM at 48 kHz (must be a multiple of 4 bytes for s16le stereo).
    private static let maxPCMBytesPerDatagram = 1_920

    private struct UDPSubscriber {
        var address: sockaddr_storage
        var addressLen: socklen_t
    }

    private var tcpListener: NWListener?
    private var tcpClients: [ObjectIdentifier: TCPClient] = [:]

    private struct TCPClient {
        let connection: NWConnection
        var sendInFlight: Bool
        var pending: [Data]
        var framesSent: Int
    }

    func startListener(port: UInt16 = GBearStreamPorts.audioUDP) async throws {
        if udp != nil { return }
        let socket = GBearUDPSocket()
        socket.onDatagram = { [weak self] data, address, addressLen in
            guard let self else { return }
            Task { await self.handleDatagram(data: data, from: address, addressLen: addressLen) }
        }
        try socket.start(port: port)
        udp = socket
    }

    func startTCPListener(port: UInt16 = GBearStreamPorts.audioTCP) async throws {
        if tcpListener != nil { return }
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.acceptTCP(connection: connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        try await GBearNWListenerAwait.waitUntilReady(listener)
        tcpListener = listener
        print("[GBearAudio] TCP listener on \(port)")
    }

    func stop() async {
        for (_, client) in tcpClients {
            client.connection.cancel()
        }
        tcpClients.removeAll()
        if let tcpListener {
            tcpListener.cancel()
            await GBearNWListenerAwait.waitUntilCancelled(tcpListener)
        }
        tcpListener = nil

        udp?.stop()
        udp = nil
        udpSubscribers.removeAll()
        packetsSent = 0
        datagramsReceived = 0
    }

    func sendPCM(_ pcm: Data, sampleRate: UInt16, channels: UInt8) {
        guard !pcm.isEmpty else { return }
        broadcastPCM(pcm, sampleRate: sampleRate, channels: channels)
    }

    private func broadcastPCM(_ pcm: Data, sampleRate: UInt16, channels: UInt8) {
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + Self.maxPCMBytesPerDatagram, pcm.count)
            let chunk = pcm.subdata(in: offset ..< end)
            let packet = GBearAudioFrameFormat.pack(payload: chunk, sampleRate: sampleRate, channels: channels)
            sendPacket(packet, pcmBytes: chunk.count, sampleRate: sampleRate, channels: channels)
            offset = end
        }
    }

    private func sendPacket(_ packet: Data, pcmBytes: Int, sampleRate: UInt16, channels: UInt8) {
        for id in Array(tcpClients.keys) {
            enqueueTCP(id: id, packet: packet)
        }

        guard let udp else { return }
        if udpSubscribers.isEmpty {
            if !loggedWaitingForSubscribe {
                loggedWaitingForSubscribe = true
                print("[GBearAudio] capture active — waiting for phone GBAS subscribe on UDP \(GBearStreamPorts.audioUDP)")
            }
            return
        }
        loggedWaitingForSubscribe = false
        for (_, sub) in udpSubscribers {
            udp.send(packet, to: sub.address, addressLen: sub.addressLen)
        }
        packetsSent += 1
        if packetsSent == 1 || packetsSent % 200 == 0 {
            print(
                "[GBearAudio] sent UDP packet #\(packetsSent) pcmBytes=\(pcmBytes) " +
                    "\(sampleRate)Hz ch=\(channels) subscribers=\(udpSubscribers.count)"
            )
        }
    }

    private func subscriberKey(for address: sockaddr_storage) -> String {
        var addr = address
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                var serv = [CChar](repeating: 0, count: Int(NI_MAXSERV))
                let len = socklen_t(address.ss_len > 0 ? address.ss_len : UInt8(MemoryLayout<sockaddr_storage>.size))
                getnameinfo(sa, len, &host, socklen_t(host.count), &serv, socklen_t(serv.count), NI_NUMERICHOST | NI_NUMERICSERV)
                return "\(String(cString: host)):\(String(cString: serv))"
            }
        }
    }

    private func handleDatagram(data: Data, from address: sockaddr_storage, addressLen: socklen_t) {
        datagramsReceived += 1
        if datagramsReceived == 1 {
            print("[GBearAudio] first UDP datagram on port \(GBearStreamPorts.audioUDP) bytes=\(data.count)")
        }
        guard data.count >= 4 else { return }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        guard magic == GBearStreamPorts.audioSubscribeMagic else {
            if datagramsReceived <= 3 {
                print("[GBearAudio] ignored datagram magic=0x\(String(magic, radix: 16))")
            }
            return
        }
        let key = subscriberKey(for: address)
        if udpSubscribers.count >= Self.maxClients, udpSubscribers[key] == nil {
            if let oldest = udpSubscribers.keys.first {
                udpSubscribers.removeValue(forKey: oldest)
            }
        }
        udpSubscribers[key] = UDPSubscriber(address: address, addressLen: addressLen)
        packetsSent = 0
        loggedWaitingForSubscribe = false
        GBearStreamSessionLog.i(
            "Phone subscribed for audio (UDP \(GBearStreamPorts.audioUDP)); subscribers=\(udpSubscribers.count)"
        )
        print("[GBearAudio] phone subscribed for audio (UDP) — subscribers=\(udpSubscribers.count)")
        sendSubscribeAck(to: address, addressLen: addressLen)
    }

    private func sendSubscribeAck(to address: sockaddr_storage? = nil, addressLen: socklen_t = 0) {
        let silent = Data(count: 960)
        for i in 0 ..< 5 {
            let packet = GBearAudioFrameFormat.pack(payload: silent, sampleRate: 48_000, channels: 2)
            if i == 0 {
                print("[GBearAudio] sent subscribe ack (silent GBA1)")
            }
            for id in Array(tcpClients.keys) {
                enqueueTCP(id: id, packet: packet)
            }
            if let udp {
                if let address, addressLen > 0 {
                    udp.send(packet, to: address, addressLen: addressLen)
                } else {
                    for (_, sub) in udpSubscribers {
                        udp.send(packet, to: sub.address, addressLen: sub.addressLen)
                    }
                }
            }
        }
    }

    // MARK: - TCP downlink

    private func acceptTCP(connection: NWConnection) {
        if tcpClients.count >= Self.maxClients {
            if let oldest = tcpClients.keys.first {
                tcpClients[oldest]?.connection.cancel()
                tcpClients.removeValue(forKey: oldest)
                print("[GBearAudio] dropped oldest TCP client (max \(Self.maxClients))")
            }
        }
        let id = ObjectIdentifier(connection)
        tcpClients[id] = TCPClient(connection: connection, sendInFlight: false, pending: [], framesSent: 0)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                Task { await self.dropTCP(id: id) }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        GBearStreamSessionLog.i(
            "Phone connected (TCP audio \(GBearStreamPorts.audioTCP)); clients=\(tcpClients.count)"
        )
        print("[GBearAudio] phone connected (TCP audio); clients=\(tcpClients.count)")
        sendSubscribeAck()
    }

    private func dropTCP(id: ObjectIdentifier) {
        tcpClients.removeValue(forKey: id)
        print("[GBearAudio] TCP audio client disconnected; remaining=\(tcpClients.count)")
    }

    private func enqueueTCP(id: ObjectIdentifier, packet: Data) {
        guard var client = tcpClients[id] else { return }
        var length = UInt32(packet.count).littleEndian
        var framed = Data(capacity: 4 + packet.count)
        framed.append(Data(bytes: &length, count: 4))
        framed.append(packet)
        client.pending.append(framed)
        tcpClients[id] = client
        flushTCP(id: id)
    }

    private func flushTCP(id: ObjectIdentifier) {
        guard var client = tcpClients[id], !client.sendInFlight, !client.pending.isEmpty else { return }
        let chunk = client.pending.removeFirst()
        client.sendInFlight = true
        tcpClients[id] = client
        let connection = client.connection
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            Task { await self.completeTCPSend(id: id, error: error) }
        })
    }

    private func completeTCPSend(id: ObjectIdentifier, error: NWError?) {
        guard var client = tcpClients[id] else { return }
        client.sendInFlight = false
        if let error {
            print("[GBearAudio] TCP send failed: \(error.localizedDescription)")
            tcpClients[id] = client
            dropTCP(id: id)
            return
        }
        client.framesSent += 1
        if client.framesSent == 1 || client.framesSent % 200 == 0 {
            print("[GBearAudio] sent TCP audio frame #\(client.framesSent) clients=\(tcpClients.count)")
        }
        tcpClients[id] = client
        flushTCP(id: id)
    }
}

// MARK: - UDP transport

final class GBearUDPSocket: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.gbear.udp", qos: .userInitiated)
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var connected = false
    var onDatagram: (@Sendable (Data, sockaddr_storage, socklen_t) -> Void)?

    func start(port: UInt16) throws {
        try queue.sync {
            guard socketFD < 0 else { return }
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else {
                throw NSError(domain: "GBearUDP", code: Int(errno), userInfo: [
                    NSLocalizedDescriptionKey: "socket() failed: \(String(cString: strerror(errno)))",
                ])
            }
            var reuse: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY.bigEndian
            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                close(fd)
                throw NSError(domain: "GBearUDP", code: Int(errno), userInfo: [
                    NSLocalizedDescriptionKey: "bind(\(port)) failed: \(String(cString: strerror(errno)))",
                ])
            }
            socketFD = fd
            connected = false
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                self?.drainReadable()
            }
            readSource = source
            source.resume()
            print("[GBearUDP] listening on \(port)")
        }
    }

    func connect(to address: sockaddr_storage, addressLen: socklen_t) {
        queue.sync {
            guard socketFD >= 0 else { return }
            var addr = address
            let len = addressLen > 0 ? addressLen : socklen_t(address.ss_len)
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socketFD, $0, len)
                }
            }
            connected = result == 0
            if !connected {
                print("[GBearUDP] connect() failed: \(String(cString: strerror(errno))) — using sendto")
            }
        }
    }

    func stop() {
        queue.sync {
            readSource?.cancel()
            readSource = nil
            if socketFD >= 0 {
                close(socketFD)
                socketFD = -1
            }
            connected = false
        }
    }

    func send(_ data: Data, to address: sockaddr_storage, addressLen: socklen_t) {
        queue.async { [weak self] in
            guard let self, self.socketFD >= 0 else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var addr = address
                let len = addressLen > 0 ? addressLen : socklen_t(address.ss_len)
                let sent = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                        sendto(
                            self.socketFD,
                            base.assumingMemoryBound(to: UInt8.self),
                            raw.count,
                            0,
                            ptr,
                            len
                        )
                    }
                }
                if sent < 0 {
                    print("[GBearUDP] send failed: \(String(cString: strerror(errno)))")
                }
            }
        }
    }

    private func drainReadable() {
        guard socketFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            var addr = sockaddr_storage()
            var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = recvfrom(
                socketFD,
                &buffer,
                buffer.count,
                0,
                withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
                },
                &addrLen
            )
            if count <= 0 { break }
            let data = Data(buffer.prefix(count))
            onDatagram?(data, addr, addrLen)
        }
    }
}

private extension sockaddr_storage {
    var ss_len: UInt8 {
        switch Int32(ss_family) {
        case AF_INET:
            return UInt8(MemoryLayout<sockaddr_in>.size)
        case AF_INET6:
            return UInt8(MemoryLayout<sockaddr_in6>.size)
        default:
            return UInt8(MemoryLayout<sockaddr_storage>.size)
        }
    }
}

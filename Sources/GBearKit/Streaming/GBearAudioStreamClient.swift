import AVFoundation
import Foundation
import Network

/// Outbound TCP client for length-prefixed `GBA1` PCM (computer guest).
final class GBearAudioStreamClient: @unchecked Sendable {
    private var connection: NWConnection?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var started = false
    private var stopping = false
    private let queue = DispatchQueue(label: "GBearGuest.audio", qos: .userInitiated)

    func start(host: String, port: UInt16) {
        stop()
        stopping = false
        if !started {
            engine.attach(player)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            engine.connect(player, to: engine.mainMixerNode, format: format)
            do {
                try engine.start()
                player.play()
                started = true
            } catch {
                print("[GBearGuestAudio] engine start failed: \(error.localizedDescription)")
            }
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.receiveLength()
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        stopping = true
        connection?.cancel()
        connection = nil
        player.stop()
    }

    private func receiveLength() {
        guard let connection, !stopping else { return }
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopping else { return }
            if error != nil || isComplete || data == nil || data!.count < 4 {
                return
            }
            let length = data!.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            guard length > 0, length < 512_000 else {
                self.receiveLength()
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { payload, _, _, _ in
                if let payload {
                    self.handlePacket(payload)
                }
                self.receiveLength()
            }
        }
    }

    private func handlePacket(_ packet: Data) {
        guard packet.count >= GBearAudioFrameFormat.headerSize else { return }
        let magic = packet.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard magic == GBearStreamPorts.audioMagic else { return }
        let payloadLen = packet.withUnsafeBytes { Int($0.load(fromByteOffset: 4, as: UInt32.self).littleEndian) }
        let sampleRate = packet.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt16.self).littleEndian }
        let channels = packet[10]
        guard payloadLen > 0, packet.count >= GBearAudioFrameFormat.headerSize + payloadLen else { return }
        let pcm = packet.subdata(in: GBearAudioFrameFormat.headerSize ..< (GBearAudioFrameFormat.headerSize + payloadLen))
        enqueuePCM(pcm, sampleRate: Double(sampleRate == 0 ? 48_000 : sampleRate), channels: AVAudioChannelCount(max(1, channels)))
    }

    private func enqueuePCM(_ pcm: Data, sampleRate: Double, channels: AVAudioChannelCount) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false) else { return }
        let frames = pcm.count / (2 * Int(channels))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for ch in 0 ..< Int(channels) {
                guard let dst = buffer.floatChannelData?[ch] else { continue }
                for i in 0 ..< frames {
                    dst[i] = Float(src[i * Int(channels) + ch]) / Float(Int16.max)
                }
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }
}

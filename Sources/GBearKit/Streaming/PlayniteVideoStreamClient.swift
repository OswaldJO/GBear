import AVFoundation
import CoreMedia
import Foundation
import Network
import VideoToolbox

/// Outbound TCP client for `PNV1` H.264 (computer guest).
final class PlayniteVideoStreamClient: @unchecked Sendable {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onEnded: ((String) -> Void)?

    private var connection: NWConnection?
    private var formatDescription: CMFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var presentationTicks: Int64 = 0
    private var stopping = false
    private let networkQueue = DispatchQueue(label: "PlayniteGuest.video.network", qos: .userInitiated)
    private let decodeQueue = DispatchQueue(label: "PlayniteGuest.video.decode", qos: .userInitiated)

    func start(host: String, port: UInt16) {
        stop()
        stopping = false
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveHeader()
            case .failed(let error):
                self.finish("video failed: \(error.localizedDescription)")
            case .cancelled:
                self.finish("video cancelled")
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }

    func stop() {
        stopping = true
        connection?.cancel()
        connection = nil
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription = nil
    }

    private func finish(_ reason: String) {
        guard !stopping else { return }
        stopping = true
        onEnded?(reason)
    }

    private func receiveHeader() {
        guard let connection, !stopping else { return }
        connection.receive(minimumIncompleteLength: 13, maximumLength: 13) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopping else { return }
            if error != nil || isComplete {
                self.finish("video tcp closed")
                return
            }
            guard let data, data.count == 13 else {
                self.receiveHeader()
                return
            }
            let magic = data.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            guard magic == PlayniteStreamPorts.videoMagic else {
                self.receiveHeader()
                return
            }
            let length = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }
            let flags = data[8]
            let isKeyframe = (flags & 0x1) != 0
            guard length > 0, length <= 8 * 1024 * 1024 else {
                self.receiveHeader()
                return
            }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] payload, _, isComplete, error in
                guard let self, !self.stopping else { return }
                if error != nil || isComplete || payload == nil {
                    self.finish("video tcp closed mid-frame")
                    return
                }
                let frame = payload!
                self.decodeQueue.async {
                    self.decodeAnnexB(frame, isKeyframe: isKeyframe)
                    self.networkQueue.async { self.receiveHeader() }
                }
            }
        }
    }

    private func decodeAnnexB(_ annexB: Data, isKeyframe: Bool) {
        if isKeyframe || formatDescription == nil {
            if let newFormat = PlayniteH264AnnexB.formatDescription(from: annexB) {
                formatDescription = newFormat
                if let session = decompressionSession {
                    VTDecompressionSessionInvalidate(session)
                }
                var session: VTDecompressionSession?
                let attrs: [NSString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
                VTDecompressionSessionCreate(
                    allocator: kCFAllocatorDefault,
                    formatDescription: newFormat,
                    decoderSpecification: nil,
                    imageBufferAttributes: attrs as CFDictionary,
                    outputCallback: nil,
                    decompressionSessionOut: &session
                )
                decompressionSession = session
            }
        }
        guard let formatDescription,
              let avcc = PlayniteH264AnnexB.annexBToAVCC(annexB) else { return }
        var block: CMBlockBuffer?
        let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: avcc.count)
        avcc.copyBytes(to: raw, count: avcc.count)
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: raw,
            blockLength: avcc.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == noErr, let block else {
            raw.deallocate()
            return
        }
        presentationTicks += 1
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: presentationTicks, timescale: 60),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        var sampleSize = avcc.count
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard let sample else { return }
        if let onSampleBuffer {
            DispatchQueue.main.async { onSampleBuffer(sample) }
        }
    }
}

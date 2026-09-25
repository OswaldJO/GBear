import AppKit
import AudioToolbox
import CoreMedia
import Foundation

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

/// ScreenCaptureKit capture → H.264 encoder callback.
final class GBearDisplayCapture: NSObject, @unchecked Sendable {
    typealias EncodedHandler = @Sendable (Data, Bool, UInt16, UInt16) -> Void
    typealias AudioHandler = @Sendable (Data, UInt16, UInt8) -> Void

    private let encoder: GBearH264Encoder
    private let audioHandler: AudioHandler?
    #if canImport(ScreenCaptureKit)
    private var stream: SCStream?
    #endif
    private let queue = DispatchQueue(label: "com.gbear.display-capture", qos: .userInitiated)

    init(encodedHandler: @escaping EncodedHandler, audioHandler: AudioHandler? = nil) {
        encoder = GBearH264Encoder(handler: encodedHandler)
        self.audioHandler = audioHandler
        super.init()
    }

    func start(width: Int, height: Int, fps: Int) async throws {
        #if canImport(ScreenCaptureKit)
        try encoder.prepare(width: Int32(width), height: Int32(height), fps: Int32(fps))

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "GBearDisplayCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to capture"])
        }
        GBearStreamDisplayContext.update(for: display.displayID)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        if audioHandler != nil {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = false
            Self.audioBuffersSeen = 0
            Self.audioExtractFailures = 0
            Self.loggedAudioFormatFailure = false
            Self.loggedAudioFormat = false
            print("[GBearAudio] ScreenCaptureKit audio enabled 48kHz stereo")
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audioHandler != nil {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        self.stream = stream
        #else
        throw NSError(domain: "GBearDisplayCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "ScreenCaptureKit unavailable"])
        #endif
    }

    func requestKeyframe() {
        encoder.requestKeyframe()
    }

    func stop() async {
        #if canImport(ScreenCaptureKit)
        if let activeStream = stream {
            stream = nil
            let stopBox = SCStreamStopBox(stream: activeStream)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await stopBox.stopCapture()
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                }
                _ = await group.next()
                group.cancelAll()
            }
        }
        #endif
        encoder.invalidate()
    }
}

#if canImport(ScreenCaptureKit)
/// `SCStream` is not `Sendable`; this box isolates stop for Swift 6 task-group timeouts.
private final class SCStreamStopBox: @unchecked Sendable {
    private let stream: SCStream

    init(stream: SCStream) {
        self.stream = stream
    }

    func stopCapture() async {
        try? await stream.stopCapture()
    }
}
#endif

#if canImport(ScreenCaptureKit)
extension GBearDisplayCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        switch outputType {
        case .screen:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            encoder.encode(pixelBuffer: pixelBuffer, presentationTime: pts)
        case .audio:
            guard let audioHandler else { return }
            guard let pcm = Self.extractPCM16(from: sampleBuffer) else {
                Self.audioExtractFailures += 1
                if Self.audioExtractFailures == 1 || Self.audioExtractFailures % 120 == 0 {
                    print("[GBearAudio] extractPCM16 failed (#\(Self.audioExtractFailures))")
                }
                return
            }
            Self.audioBuffersSeen += 1
            if Self.audioBuffersSeen == 1 {
                print("[GBearAudio] first capture buffer bytes=\(pcm.data.count) \(pcm.sampleRate)Hz ch=\(pcm.channels)")
            }
            audioHandler(pcm.data, pcm.sampleRate, pcm.channels)
        default:
            break
        }
    }

    private struct PCM16 {
        let data: Data
        let sampleRate: UInt16
        let channels: UInt8
    }

    private nonisolated(unsafe) static var audioBuffersSeen = 0
    private nonisolated(unsafe) static var audioExtractFailures = 0
    private nonisolated(unsafe) static var loggedAudioFormatFailure = false
    private nonisolated(unsafe) static var loggedAudioFormat = false

    private static func extractPCM16(from sampleBuffer: CMSampleBuffer) -> PCM16? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return nil }
        let asbd = asbdPtr.pointee
        let channels = UInt8(max(1, min(Int(asbd.mChannelsPerFrame), 2)))
        let sampleRate = UInt16(min(max(asbd.mSampleRate.rounded(), 8_000), 96_000))

        if !loggedAudioFormat {
            loggedAudioFormat = true
            let planar = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            print(
                "[GBearAudio] capture format \(sampleRate)Hz ch=\(channels) " +
                    "bits=\(asbd.mBitsPerChannel) bytesPerFrame=\(asbd.mBytesPerFrame) " +
                    "float=\((asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0) planar=\(planar)"
            )
        }

        if let pcm = extractPCM16FromAudioBufferList(sampleBuffer, asbd: asbd, sampleRate: sampleRate, channels: channels) {
            return pcm
        }
        if let pcm = extractPCM16FromBlockBuffer(sampleBuffer, asbd: asbd, sampleRate: sampleRate, channels: channels) {
            return pcm
        }

        if !loggedAudioFormatFailure {
            loggedAudioFormatFailure = true
            print(
                "[GBearAudio] unsupported sample layout flags=\(asbd.mFormatFlags) " +
                    "bits=\(asbd.mBitsPerChannel) bytesPerFrame=\(asbd.mBytesPerFrame)"
            )
        }
        return nil
    }

    private static func extractPCM16FromBlockBuffer(
        _ sampleBuffer: CMSampleBuffer,
        asbd: AudioStreamBasicDescription,
        sampleRate: UInt16,
        channels: UInt8
    ) -> PCM16? {
        guard (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0 else { return nil }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        ) == noErr, let dataPointer, length > 0 else { return nil }
        return pcm16(fromRawBytes: dataPointer, byteCount: length, asbd: asbd, sampleRate: sampleRate, channels: channels)
    }

    private static func extractPCM16FromAudioBufferList(
        _ sampleBuffer: CMSampleBuffer,
        asbd: AudioStreamBasicDescription,
        sampleRate: UInt16,
        channels: UInt8
    ) -> PCM16? {
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return nil }

        var bufferListSizeNeeded = 0
        let probeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard probeStatus == noErr, bufferListSizeNeeded > 0 else { return nil }

        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: rawList.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(rawList.assumingMemoryBound(to: AudioBufferList.self))
        guard !buffers.isEmpty else { return nil }

        var planes = [AudioBuffer]()
        for buffer in buffers {
            guard buffer.mData != nil, buffer.mDataByteSize > 0 else { continue }
            planes.append(buffer)
        }

        if planes.count >= 2, channels >= 2,
           let interleaved = interleavePlanarStereo(left: planes[0], right: planes[1], asbd: asbd) {
            return PCM16(data: interleaved, sampleRate: sampleRate, channels: channels)
        }

        guard let plane = planes.first ?? buffers.first,
              let data = plane.mData else { return nil }
        let byteCount = Int(plane.mDataByteSize)
        guard byteCount > 0 else { return nil }
        return pcm16(
            fromRawBytes: data.assumingMemoryBound(to: Int8.self),
            byteCount: byteCount,
            asbd: asbd,
            sampleRate: sampleRate,
            channels: channels
        )
    }

    private static func interleavePlanarStereo(
        left: AudioBuffer,
        right: AudioBuffer,
        asbd: AudioStreamBasicDescription
    ) -> Data? {
        guard let leftData = left.mData, let rightData = right.mData else { return nil }
        let leftBytes = Int(left.mDataByteSize)
        let rightBytes = Int(right.mDataByteSize)
        guard leftBytes > 0, leftBytes == rightBytes else { return nil }
        let left = leftData
        let right = rightData

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        if isFloat {
            let sampleCount = leftBytes / MemoryLayout<Float>.size
            var out = Data(count: sampleCount * 2 * MemoryLayout<Int16>.size)
            out.withUnsafeMutableBytes { dest in
                guard let destBase = dest.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                let l = left.assumingMemoryBound(to: Float.self)
                let r = right.assumingMemoryBound(to: Float.self)
                for i in 0 ..< sampleCount {
                    let lv = max(-1.0, min(1.0, l[i]))
                    let rv = max(-1.0, min(1.0, r[i]))
                    destBase[i * 2] = Int16(clamping: Int32((lv * 32767.0).rounded()))
                    destBase[i * 2 + 1] = Int16(clamping: Int32((rv * 32767.0).rounded()))
                }
            }
            return out
        }

        if asbd.mBitsPerChannel == 16 {
            let sampleCount = leftBytes / MemoryLayout<Int16>.size
            var out = Data(count: sampleCount * 2 * MemoryLayout<Int16>.size)
            out.withUnsafeMutableBytes { dest in
                guard let destBase = dest.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                let l = left.assumingMemoryBound(to: Int16.self)
                let r = right.assumingMemoryBound(to: Int16.self)
                for i in 0 ..< sampleCount {
                    destBase[i * 2] = l[i]
                    destBase[i * 2 + 1] = r[i]
                }
            }
            return out
        }
        return nil
    }

    private static func pcm16(
        fromRawBytes dataPointer: UnsafePointer<Int8>,
        byteCount: Int,
        asbd: AudioStreamBasicDescription,
        sampleRate: UInt16,
        channels: UInt8
    ) -> PCM16? {
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInt16 = asbd.mBitsPerChannel == 16 && !isFloat

        if isInt16 {
            return PCM16(data: Data(bytes: dataPointer, count: byteCount), sampleRate: sampleRate, channels: channels)
        }

        if isFloat {
            let floatCount = byteCount / MemoryLayout<Float>.size
            guard floatCount > 0 else { return nil }
            var out = Data(count: floatCount * MemoryLayout<Int16>.size)
            out.withUnsafeMutableBytes { dest in
                guard let destBase = dest.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                let src = dataPointer.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }
                for i in 0 ..< floatCount {
                    let clamped = max(-1.0, min(1.0, src[i]))
                    destBase[i] = Int16(clamping: Int32((clamped * 32767.0).rounded()))
                }
            }
            return PCM16(data: out, sampleRate: sampleRate, channels: channels)
        }

        if asbd.mBitsPerChannel == 32, !isFloat {
            let sampleCount = byteCount / MemoryLayout<Int32>.size
            var out = Data(count: sampleCount * MemoryLayout<Int16>.size)
            out.withUnsafeMutableBytes { dest in
                guard let destBase = dest.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                let src = dataPointer.withMemoryRebound(to: Int32.self, capacity: sampleCount) { $0 }
                for i in 0 ..< sampleCount {
                    let scaled = max(-32_768, min(32_767, src[i] >> 16))
                    destBase[i] = Int16(truncatingIfNeeded: scaled)
                }
            }
            return PCM16(data: out, sampleRate: sampleRate, channels: channels)
        }

        return nil
    }
}
#endif

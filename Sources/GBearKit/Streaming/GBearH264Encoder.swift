import CoreMedia
import Foundation
import VideoToolbox

final class GBearH264Encoder: @unchecked Sendable {
    typealias EncodedHandler = @Sendable (Data, Bool, UInt16, UInt16) -> Void

    private var session: VTCompressionSession?
    private let handler: EncodedHandler
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var forceNextKeyframe = true
    private var cachedSPS: Data?
    private var cachedPPS: Data?

    init(handler: @escaping EncodedHandler) {
        self.handler = handler
    }

    func prepare(width: Int32, height: Int32, fps: Int32) throws {
        self.width = width
        self.height = height
        if session != nil {
            VTCompressionSessionInvalidate(session!)
            session = nil
        }

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.compressionOutput,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            throw NSError(domain: "GBearH264Encoder", code: Int(status))
        }

        session = newSession
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // Baseline improves compatibility with Android OMX / C2 software decoders.
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 8_000_000))
        // Frequent IDRs help the phone recover after decoder reconfiguration (~1s at 60 fps).
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps))
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTCompressionSessionPrepareToEncodeFrames(newSession)
        forceNextKeyframe = true
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session else { return }
        var flags: VTEncodeInfoFlags = []
        var frameProperties: CFDictionary?
        if forceNextKeyframe {
            forceNextKeyframe = false
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
    }

    func requestKeyframe() {
        forceNextKeyframe = true
    }

    func invalidate() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    private static let compressionOutput: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard status == noErr,
              let refcon,
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let encoder = Unmanaged<GBearH264Encoder>.fromOpaque(refcon).takeUnretainedValue()
        encoder.emit(sampleBuffer: sampleBuffer)
    }

    private func emit(sampleBuffer: CMSampleBuffer) {
        cacheParameterSets(from: sampleBuffer)

        guard var annexB = Self.annexB(from: sampleBuffer), !annexB.isEmpty else { return }

        var isKeyframe = Self.containsIDR(annexB)
        if !isKeyframe,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [NSDictionary],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            isKeyframe = !notSync
        }

        if isKeyframe, let sps = cachedSPS, let pps = cachedPPS {
            annexB = Self.prependParameterSetsIfNeeded(sps: sps, pps: pps, to: annexB)
        }

        // VideoToolbox sometimes emits standalone SPS/PPS buffers with no slice data.
        guard Self.containsSlice(annexB) else { return }

        handler(annexB, isKeyframe, UInt16(width), UInt16(height))
    }

    private func cacheParameterSets(from sampleBuffer: CMSampleBuffer) {
        for nal in Self.extractNALUs(Self.annexB(from: sampleBuffer) ?? Data()) {
            guard !nal.isEmpty else { continue }
            switch nal[0] & 0x1F {
            case 7: cachedSPS = nal
            case 8: cachedPPS = nal
            default: break
            }
        }

        guard cachedSPS == nil || cachedPPS == nil,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        var parameterSetCount = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: nil
        ) == noErr, parameterSetCount >= 2 else { return }

        if cachedSPS == nil {
            var size = 0
            var pointer: UnsafePointer<UInt8>?
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer, size > 0 {
                cachedSPS = Data(bytes: pointer, count: size)
            }
        }

        if cachedPPS == nil {
            var size = 0
            var pointer: UnsafePointer<UInt8>?
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: 1,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer, size > 0 {
                cachedPPS = Data(bytes: pointer, count: size)
            }
        }
    }

    /// Phone decoders need in-band SPS/PPS on the first keyframe they receive; later IDR-only keyframes are not enough.
    private static func prependParameterSetsIfNeeded(sps: Data, pps: Data, to annexB: Data) -> Data {
        let nals = extractNALUs(annexB)
        let hasSPS = nals.contains { !$0.isEmpty && ($0[0] & 0x1F) == 7 }
        let hasPPS = nals.contains { !$0.isEmpty && ($0[0] & 0x1F) == 8 }
        if hasSPS && hasPPS { return annexB }

        var result = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]
        if !hasSPS {
            result.append(contentsOf: startCode)
            result.append(sps)
        }
        if !hasPPS {
            result.append(contentsOf: startCode)
            result.append(pps)
        }
        result.append(annexB)
        return result
    }

    /// VideoToolbox emits length-prefixed NALs (AVCC). Phones expect Annex-B start codes.
    private static func annexB(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: &totalLength,
            dataPointerOut: &pointer
        ) == noErr, let pointer, totalLength > 0 else { return nil }

        // Require two start codes so length-prefixed AVCC (e.g. 00 00 05 xx) is not mistaken for Annex-B.
        if Self.hasAnnexBStartCodes(pointer: pointer, length: totalLength, minimum: 2) {
            return Data(bytes: pointer, count: totalLength)
        }

        var nalLengthSize = 4
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] {
            let atomsKey = "SampleDescriptionExtensionAtoms"
            let atoms = extensions[atomsKey] as? [String: Data]
            if let avcC = atoms?["avcC"], avcC.count >= 5 {
                let lengthSizeMinusOne = Int(avcC[4] & 0x03)
                nalLengthSize = lengthSizeMinusOne + 1
                if nalLengthSize < 1 || nalLengthSize > 4 { nalLengthSize = 4 }
            }
        }

        var annexB = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]
        var offset = 0
        while offset + nalLengthSize <= totalLength {
            var nalSize = 0
            for i in 0..<nalLengthSize {
                nalSize = (nalSize << 8) | Int(UInt8(bitPattern: pointer[offset + i]))
            }
            offset += nalLengthSize
            guard nalSize > 0, offset + nalSize <= totalLength else { break }
            annexB.append(contentsOf: startCode)
            annexB.append(Data(bytes: pointer.advanced(by: offset), count: nalSize))
            offset += nalSize
        }
        return annexB.isEmpty ? nil : annexB
    }

    private static func hasAnnexBStartCodes(pointer: UnsafePointer<Int8>, length: Int, minimum: Int) -> Bool {
        guard length >= 5 else { return false }
        var found = 0
        var i = 0
        while i + 3 < length, found < minimum {
            let b0 = UInt8(bitPattern: pointer[i])
            let b1 = UInt8(bitPattern: pointer[i + 1])
            let b2 = UInt8(bitPattern: pointer[i + 2])
            let b3 = i + 3 < length ? UInt8(bitPattern: pointer[i + 3]) : 0
            let is4 = b0 == 0 && b1 == 0 && b2 == 0 && b3 == 1
            let is3 = b0 == 0 && b1 == 0 && b2 == 1
            if is4 || is3 {
                found += 1
                i += is4 ? 4 : 3
            } else {
                i += 1
            }
        }
        return found >= minimum
    }

    private static func containsIDR(_ annexB: Data) -> Bool {
        for nal in extractNALUs(annexB) {
            if !nal.isEmpty, (nal[0] & 0x1F) == 5 { return true }
        }
        return false
    }

    /// True when the payload includes a decodable VCL NAL (slice or IDR).
    private static func containsSlice(_ annexB: Data) -> Bool {
        for nal in extractNALUs(annexB) {
            guard !nal.isEmpty else { continue }
            switch nal[0] & 0x1F {
            case 1, 2, 3, 4, 5: return true
            default: break
            }
        }
        return false
    }

    private static func extractNALUs(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var i = 0

        func nalStart(_ from: Int) -> Int? {
            var j = from
            while j + 3 < bytes.count {
                if bytes[j] == 0, bytes[j + 1] == 0, bytes[j + 2] == 1 { return j + 3 }
                if j + 4 < bytes.count, bytes[j] == 0, bytes[j + 1] == 0, bytes[j + 2] == 0, bytes[j + 3] == 1 {
                    return j + 4
                }
                j += 1
            }
            return nil
        }

        while let start = nalStart(i) {
            var end = start
            while end < bytes.count {
                if end + 3 < bytes.count, bytes[end] == 0, bytes[end + 1] == 0, bytes[end + 2] == 1 { break }
                if end + 4 < bytes.count, bytes[end] == 0, bytes[end + 1] == 0, bytes[end + 2] == 0, bytes[end + 3] == 1 {
                    break
                }
                end += 1
            }
            units.append(Data(bytes[start..<end]))
            i = end
        }
        return units
    }
}

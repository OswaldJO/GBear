import CoreMedia
import Foundation
import VideoToolbox

enum GBearH264AnnexB {
    static func formatDescription(from annexB: Data) -> CMFormatDescription? {
        let nalUnits = extractNALUnits(annexB)
        guard let sps = nalUnits.first(where: { ($0.first ?? 0) & 0x1F == 7 }),
              let pps = nalUnits.first(where: { ($0.first ?? 0) & 0x1F == 8 }) else { return nil }
        var description: CMFormatDescription?
        sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsBase = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let pointers = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                pointers.withUnsafeBufferPointer { ptr in
                    sizes.withUnsafeBufferPointer { sizePtr in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptr.baseAddress!,
                            parameterSetSizes: sizePtr.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }
        return description
    }

    static func annexBToAVCC(_ annexB: Data) -> Data? {
        let nals = extractNALUnits(annexB)
        guard !nals.isEmpty else { return nil }
        var avcc = Data()
        for nal in nals {
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        return avcc
    }

    static func extractNALUnits(_ data: Data) -> [Data] {
        var units: [Data] = []
        var i = 0
        let bytes = [UInt8](data)
        func startIndex(_ from: Int) -> Int? {
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
        while let start = startIndex(i) {
            var end = start
            while end < bytes.count {
                if end + 3 < bytes.count, bytes[end] == 0, bytes[end + 1] == 0, bytes[end + 2] == 1 { break }
                if end + 4 < bytes.count, bytes[end] == 0, bytes[end + 1] == 0, bytes[end + 2] == 0, bytes[end + 3] == 1 {
                    break
                }
                end += 1
            }
            if end > start {
                units.append(Data(bytes[start ..< end]))
            }
            i = max(end, start + 1)
        }
        return units
    }
}

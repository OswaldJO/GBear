import Foundation

/// `GBV1` length-prefixed H.264 access units for the phone decoder.
enum GBearVideoFrameFormat {
    static let headerSize = 13

    static func pack(payload: Data, width: UInt16, height: UInt16, isKeyframe: Bool) -> Data {
        var packet = Data(capacity: headerSize + payload.count)
        var magic = GBearStreamPorts.videoMagic.littleEndian
        var length = UInt32(payload.count).littleEndian
        var flags: UInt8 = isKeyframe ? 1 : 0
        var w = width.littleEndian
        var h = height.littleEndian
        withUnsafeBytes(of: &magic) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &flags) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &w) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { packet.append(contentsOf: $0) }
        packet.append(payload)
        return packet
    }
}

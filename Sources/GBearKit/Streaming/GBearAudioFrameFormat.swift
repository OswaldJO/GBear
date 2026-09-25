import Foundation

/// `GBA1` length-prefixed PCM for the phone speaker (s16le interleaved).
enum GBearAudioFrameFormat {
    /// magic(4) + length(4) + sampleRate(2) + channels(1)
    static let headerSize = 11

    static func pack(payload: Data, sampleRate: UInt16, channels: UInt8) -> Data {
        var packet = Data(capacity: headerSize + payload.count)
        var magic = GBearStreamPorts.audioMagic.littleEndian
        var length = UInt32(payload.count).littleEndian
        var rate = sampleRate.littleEndian
        var ch = channels
        withUnsafeBytes(of: &magic) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &rate) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &ch) { packet.append(contentsOf: $0) }
        packet.append(payload)
        return packet
    }
}

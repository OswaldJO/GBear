import Foundation

/// One `GBTL` message: magic + channel + length + payload.
/// Remote co-op sends each frame as a single WebSocket binary message.
enum GBearTunnelFrame {
    enum Channel: UInt8, Sendable {
        case control = 1
        case video = 2
        case audio = 3
        case input = 4
    }

    static let magic: UInt32 = 0x4C_54_42_47 // "GBTL"

    static func pack(channel: Channel, payload: Data) -> Data {
        var frame = Data(capacity: 9 + payload.count)
        var magic = Self.magic.littleEndian
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &magic) { frame.append(contentsOf: $0) }
        frame.append(channel.rawValue)
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    static func unpack(_ data: Data) -> (channel: Channel, payload: Data)? {
        guard data.count >= 9 else { return nil }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        guard magic == Self.magic else { return nil }
        guard let channel = Channel(rawValue: data[4]) else { return nil }
        let length = data.subdata(in: 5 ..< 9).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        let total = 9 + Int(length)
        guard length <= 8 * 1024 * 1024, data.count >= total else { return nil }
        return (channel, data.subdata(in: 9 ..< total))
    }
}

/// `GBTP`: one `GBTL` frame addressed to or from a single remote co-op guest.
/// Only the host's own link to the local relay uses it; guests always see plain `GBTL`.
enum GBearTunnelPeerFrame {
    static let magic: UInt32 = 0x50_54_42_47 // "GBTP"

    static func wrap(peer: UInt8, frame: Data) -> Data {
        var data = Data(capacity: 5 + frame.count)
        var magic = Self.magic.littleEndian
        withUnsafeBytes(of: &magic) { data.append(contentsOf: $0) }
        data.append(peer)
        data.append(frame)
        return data
    }

    static func unwrap(_ data: Data) -> (peer: UInt8, frame: Data)? {
        guard data.count >= 5 else { return nil }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard magic == Self.magic else { return nil }
        let start = data.startIndex
        return (data[start + 4], data.subdata(in: (start + 5) ..< data.endIndex))
    }
}

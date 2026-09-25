import Foundation

/// `GBK1` keyboard events from the companion (Windows virtual-key codes in Moonlight short form).
enum GBearKeyboardEventFormat {
    static let magic: UInt32 = 0x314B_4247 // "GBK1"
    static let packetSize = 8

    struct Event: Sendable {
        let down: Bool
        let moonlightKeyCode: UInt16
    }

    static func parse(_ data: Data) -> Event? {
        guard data.count >= packetSize else { return nil }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        guard magic == Self.magic else { return nil }
        let down = data[4] != 0
        let code = data.subdata(in: 6 ..< 8).withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
        return Event(down: down, moonlightKeyCode: code)
    }
}

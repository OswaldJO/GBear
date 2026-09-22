import Foundation

/// `PNG1` structured gamepad state from a companion co-op seat.
enum PlayniteGamepadEventFormat {
    static let magic: UInt32 = PlayniteStreamPorts.gamepadMagic
    /// Fixed packet size: magic(4) + seat(1) + buttons(4) + lx ly rx ry lt rt(6×Float32) = 33
    static let packetSize = 33

    struct Event: Sendable {
        let seat: UInt8
        let buttons: UInt32
        let leftX: Float
        let leftY: Float
        let rightX: Float
        let rightY: Float
        let leftTrigger: Float
        let rightTrigger: Float
    }

    /// Standard button bits (Xbox-style).
    enum Button {
        static let a: UInt32 = 1 << 0
        static let b: UInt32 = 1 << 1
        static let x: UInt32 = 1 << 2
        static let y: UInt32 = 1 << 3
        static let l1: UInt32 = 1 << 4
        static let r1: UInt32 = 1 << 5
        static let l3: UInt32 = 1 << 6
        static let r3: UInt32 = 1 << 7
        static let start: UInt32 = 1 << 8
        static let select: UInt32 = 1 << 9
        static let dpadUp: UInt32 = 1 << 10
        static let dpadDown: UInt32 = 1 << 11
        static let dpadLeft: UInt32 = 1 << 12
        static let dpadRight: UInt32 = 1 << 13
        static let guide: UInt32 = 1 << 14
    }

    static func parse(_ data: Data) -> Event? {
        guard data.count >= packetSize else { return nil }
        return data.withUnsafeBytes { raw -> Event? in
            guard let base = raw.baseAddress else { return nil }
            let magic = base.load(as: UInt32.self).littleEndian
            guard magic == Self.magic else { return nil }
            let seat = base.load(fromByteOffset: 4, as: UInt8.self)
            let buttons = base.load(fromByteOffset: 5, as: UInt32.self).littleEndian
            let leftX = base.load(fromByteOffset: 9, as: Float.self)
            let leftY = base.load(fromByteOffset: 13, as: Float.self)
            let rightX = base.load(fromByteOffset: 17, as: Float.self)
            let rightY = base.load(fromByteOffset: 21, as: Float.self)
            let leftTrigger = base.load(fromByteOffset: 25, as: Float.self)
            let rightTrigger = base.load(fromByteOffset: 29, as: Float.self)
            return Event(
                seat: seat,
                buttons: buttons,
                leftX: leftX,
                leftY: leftY,
                rightX: rightX,
                rightY: rightY,
                leftTrigger: leftTrigger,
                rightTrigger: rightTrigger
            )
        }
    }

    static func pack(
        seat: UInt8,
        buttons: UInt32,
        leftX: Float,
        leftY: Float,
        rightX: Float,
        rightY: Float,
        leftTrigger: Float,
        rightTrigger: Float
    ) -> Data {
        var data = Data(capacity: packetSize)
        var magicLE = magic.littleEndian
        data.append(Data(bytes: &magicLE, count: 4))
        data.append(seat)
        var buttonsLE = buttons.littleEndian
        data.append(Data(bytes: &buttonsLE, count: 4))
        func appendFloat(_ value: Float) {
            var v = value
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        appendFloat(leftX)
        appendFloat(leftY)
        appendFloat(rightX)
        appendFloat(rightY)
        appendFloat(leftTrigger)
        appendFloat(rightTrigger)
        return data
    }
}

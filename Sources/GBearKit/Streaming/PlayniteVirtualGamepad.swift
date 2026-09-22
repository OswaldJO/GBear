import Foundation
import PlayniteHID

/// Two virtual HID gamepads for co-op seats (emulators see pad 1 / pad 2).
actor PlayniteVirtualGamepadManager {
    static let shared = PlayniteVirtualGamepadManager()

    private var pad1: PlayniteVirtualGamepad?
    private var pad2: PlayniteVirtualGamepad?
    private var ready = false

    func ensurePads() {
        if ready { return }
        pad1 = PlayniteVirtualGamepad(seat: 1)
        pad2 = PlayniteVirtualGamepad(seat: 2)
        ready = true
        print("[PlayniteVirtualPad] seats 1 and 2 ready")
    }

    func apply(_ event: PlayniteGamepadEventFormat.Event) {
        ensurePads()
        switch event.seat {
        case 1:
            pad1?.update(event)
        case 2:
            pad2?.update(event)
        default:
            break
        }
    }

    func resetAll() {
        pad1?.reset()
        pad2?.reset()
    }
}

/// Userspace HID gamepad via IOHIDUserDevice (C shim).
final class PlayniteVirtualGamepad: @unchecked Sendable {
    let seat: Int
    private var device: PlayniteHIDDeviceRef?
    private let queue = DispatchQueue(label: "com.gbear.virtualpad.\(UUID().uuidString)")

    init(seat: Int) {
        self.seat = seat
        createDevice()
    }

    deinit {
        if let device {
            PlayniteHIDDeviceDestroy(device)
        }
    }

    func update(_ event: PlayniteGamepadEventFormat.Event) {
        queue.async { [weak self] in
            self?.sendReport(event)
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            let empty = PlayniteGamepadEventFormat.Event(
                seat: UInt8(self.seat),
                buttons: 0,
                leftX: 0,
                leftY: 0,
                rightX: 0,
                rightY: 0,
                leftTrigger: 0,
                rightTrigger: 0
            )
            self.sendReport(empty)
        }
    }

    private func createDevice() {
        let descriptor = Self.hidDescriptor
        device = descriptor.withUnsafeBytes { raw -> PlayniteHIDDeviceRef? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return PlayniteHIDDeviceCreate(Int32(seat), base, descriptor.count)
        }
        if device == nil {
            print("[PlayniteVirtualPad] seat \(seat) create failed")
        } else {
            print("[PlayniteVirtualPad] seat \(seat) HID device created")
        }
    }

    private func sendReport(_ event: PlayniteGamepadEventFormat.Event) {
        guard let device else { return }
        var report = [UInt8](repeating: 0, count: 15)
        report[0] = 0x01
        report[1] = UInt8(event.buttons & 0xFF)
        report[2] = UInt8((event.buttons >> 8) & 0xFF)
        report[3] = Self.axisByte(event.leftX)
        report[4] = Self.axisByte(event.leftY)
        report[5] = Self.axisByte(event.rightX)
        report[6] = Self.axisByte(event.rightY)
        report[7] = Self.triggerByte(event.leftTrigger)
        report[8] = Self.triggerByte(event.rightTrigger)
        report[9] = Self.hatFromButtons(event.buttons)
        _ = report.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return PlayniteHIDDeviceSendReport(device, base, report.count)
        }
    }

    private static func axisByte(_ value: Float) -> UInt8 {
        let clamped = max(-1, min(1, value))
        let scaled = Int(((clamped + 1) / 2) * 255)
        return UInt8(max(0, min(255, scaled)))
    }

    private static func triggerByte(_ value: Float) -> UInt8 {
        let clamped = max(0, min(1, value))
        return UInt8(clamped * 255)
    }

    private static func hatFromButtons(_ buttons: UInt32) -> UInt8 {
        let up = buttons & PlayniteGamepadEventFormat.Button.dpadUp != 0
        let down = buttons & PlayniteGamepadEventFormat.Button.dpadDown != 0
        let left = buttons & PlayniteGamepadEventFormat.Button.dpadLeft != 0
        let right = buttons & PlayniteGamepadEventFormat.Button.dpadRight != 0
        switch (up, down, left, right) {
        case (true, false, false, false): return 0
        case (true, false, false, true): return 1
        case (false, false, false, true): return 2
        case (false, true, false, true): return 3
        case (false, true, false, false): return 4
        case (false, true, true, false): return 5
        case (false, false, true, false): return 6
        case (true, false, true, false): return 7
        default: return 8
        }
    }

    private static let hidDescriptor: Data = Data([
        0x05, 0x01,
        0x09, 0x05,
        0xA1, 0x01,
        0x85, 0x01,
        0x05, 0x09,
        0x19, 0x01,
        0x29, 0x10,
        0x15, 0x00,
        0x25, 0x01,
        0x75, 0x01,
        0x95, 0x10,
        0x81, 0x02,
        0x05, 0x01,
        0x09, 0x30,
        0x09, 0x31,
        0x09, 0x32,
        0x09, 0x35,
        0x15, 0x00,
        0x26, 0xFF, 0x00,
        0x75, 0x08,
        0x95, 0x04,
        0x81, 0x02,
        0x09, 0x33,
        0x09, 0x34,
        0x95, 0x02,
        0x81, 0x02,
        0x09, 0x39,
        0x15, 0x00,
        0x25, 0x07,
        0x35, 0x00,
        0x46, 0x3B, 0x01,
        0x65, 0x14,
        0x75, 0x04,
        0x95, 0x01,
        0x81, 0x02,
        0x75, 0x04,
        0x95, 0x01,
        0x81, 0x03,
        0xC0,
    ])
}

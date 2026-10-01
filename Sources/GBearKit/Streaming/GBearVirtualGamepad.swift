import Foundation
import GBearHID

/// Virtual HID gamepads for co-op seats (emulators see `GBear Virtual Pad N`).
actor GBearVirtualGamepadManager {
    static let shared = GBearVirtualGamepadManager()

    private var pads: [Int: GBearVirtualGamepad] = [:]
    /// GBG1 `joinSeat` → current assigned virtual pad.
    private var translation: [UInt8: UInt8] = [:]

    func setJoinSeatTranslation(_ map: [UInt8: UInt8]) {
        translation = map
    }

    /// Create pads for occupied seats; tear down unused ones.
    func syncPads(occupiedSeats: Set<Int>) {
        let valid = occupiedSeats.filter { GBearCoopSessionState.isValidSeat($0) }
        for seat in pads.keys where !valid.contains(seat) {
            if pads[seat]?.isAvailable == false {
                GBearKeyboardPadStandIn.shared.release(seat: seat)
            }
            pads[seat]?.reset()
            pads.removeValue(forKey: seat)
            Task { @MainActor in GBearPadInputMonitor.shared.clear(seat: seat) }
        }
        for seat in valid where pads[seat] == nil {
            pads[seat] = GBearVirtualGamepad(seat: seat)
        }
    }

    func apply(_ event: GBearGamepadEventFormat.Event) {
        let incoming = event.seat
        let mapped = translation[incoming] ?? incoming
        let seat = Int(mapped)
        guard GBearCoopSessionState.isValidSeat(seat) else { return }
        if pads[seat] == nil {
            pads[seat] = GBearVirtualGamepad(seat: seat)
        }
        var routed = event
        routed = GBearGamepadEventFormat.Event(
            seat: UInt8(seat),
            buttons: event.buttons,
            leftX: event.leftX,
            leftY: event.leftY,
            rightX: event.rightX,
            rightY: event.rightY,
            leftTrigger: event.leftTrigger,
            rightTrigger: event.rightTrigger
        )
        guard let pad = pads[seat] else { return }
        let route: GBearPadInputMonitor.Route
        if pad.isAvailable {
            pad.update(routed)
            route = .virtualPad
        } else if GBearPadControl.seatsWithKeys.contains(seat) {
            GBearKeyboardPadStandIn.shared.update(routed)
            route = .keyboard
        } else {
            route = .unrouted
        }
        Task { @MainActor in
            GBearPadInputMonitor.shared.record(seat: seat, event: routed, route: route)
        }
    }

    func applyToSeat(_ seat: Int, event: GBearGamepadEventFormat.Event) {
        guard GBearCoopSessionState.isValidSeat(seat) else { return }
        if pads[seat] == nil {
            pads[seat] = GBearVirtualGamepad(seat: seat)
        }
        let routed = GBearGamepadEventFormat.Event(
            seat: UInt8(seat),
            buttons: event.buttons,
            leftX: event.leftX,
            leftY: event.leftY,
            rightX: event.rightX,
            rightY: event.rightY,
            leftTrigger: event.leftTrigger,
            rightTrigger: event.rightTrigger
        )
        let route: GBearPadInputMonitor.Route = pads[seat]?.isAvailable == true ? .virtualPad : .hostController
        pads[seat]?.update(routed)
        Task { @MainActor in
            GBearPadInputMonitor.shared.record(seat: seat, event: routed, route: route)
        }
    }

    func resetAll() {
        for pad in pads.values {
            pad.reset()
        }
        GBearKeyboardPadStandIn.shared.releaseAll()
    }

    func removeAll() {
        resetAll()
        pads.removeAll()
        Task { @MainActor in GBearPadInputMonitor.shared.clearAll() }
    }
}

/// One `GBear Virtual Pad N`: a userspace HID device (C shim) that presents as a wired DualShock 4,
/// so SDL, RPCS3, RetroArch and GameController-based emulators map it on their own.
final class GBearVirtualGamepad: @unchecked Sendable {
    /// False until Apple grants `com.apple.developer.hid.virtual.device` and GBear ships with a
    /// provisioning profile containing it (BJ-095, BJ-116).
    static let isEntitled = GBearHIDHasVirtualDeviceEntitlement() != 0

    let seat: Int
    private var device: GBearHIDDeviceRef?
    private let queue = DispatchQueue(label: "com.gbear.virtualpad.\(UUID().uuidString)")
    private var reportCounter: UInt8 = 0
    private var timestamp: UInt16 = 0

    var isAvailable: Bool { device != nil }

    init(seat: Int) {
        self.seat = seat
        device = GBearHIDDeviceCreate(Int32(seat))
        if device == nil {
            print("[GBearVirtualPad] seat \(seat) create failed (Virtual HID entitlement: \(Self.isEntitled ? "present" : "missing"))")
        } else {
            print("[GBearVirtualPad] seat \(seat) created as DualShock 4")
            // Until the first report the pad reads as sticks up-left and D-pad up.
            reset()
        }
    }

    deinit {
        if let device {
            GBearHIDDeviceDestroy(device)
        }
    }

    func update(_ event: GBearGamepadEventFormat.Event) {
        queue.async { [weak self] in
            self?.sendReport(event)
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            let empty = GBearGamepadEventFormat.Event(
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

    /// DS4 USB input report 0x01 (64 bytes).
    private func sendReport(_ event: GBearGamepadEventFormat.Event) {
        guard let device else { return }
        typealias Button = GBearGamepadEventFormat.Button
        func has(_ bit: UInt32) -> Bool { event.buttons & bit != 0 }

        var report = [UInt8](repeating: 0, count: 64)
        report[0] = 0x01
        // DS4 sticks: 0…255, 128 centered, Y grows downward (GBG1 Y grows upward).
        report[1] = Self.axisByte(event.leftX)
        report[2] = Self.axisByte(-event.leftY)
        report[3] = Self.axisByte(event.rightX)
        report[4] = Self.axisByte(-event.rightY)
        // Face buttons by position: Xbox A/B/X/Y = Cross/Circle/Square/Triangle.
        var faceAndHat = Self.hatFromButtons(event.buttons)
        if has(Button.x) { faceAndHat |= 0x10 }
        if has(Button.a) { faceAndHat |= 0x20 }
        if has(Button.b) { faceAndHat |= 0x40 }
        if has(Button.y) { faceAndHat |= 0x80 }
        report[5] = faceAndHat
        var shoulders: UInt8 = 0
        if has(Button.l1) { shoulders |= 0x01 }
        if has(Button.r1) { shoulders |= 0x02 }
        if event.leftTrigger > GBearPadControl.pressThreshold { shoulders |= 0x04 }
        if event.rightTrigger > GBearPadControl.pressThreshold { shoulders |= 0x08 }
        if has(Button.select) { shoulders |= 0x10 }
        if has(Button.start) { shoulders |= 0x20 }
        if has(Button.l3) { shoulders |= 0x40 }
        if has(Button.r3) { shoulders |= 0x80 }
        report[6] = shoulders
        reportCounter = (reportCounter &+ 1) & 0x3F
        report[7] = (reportCounter << 2) | (has(Button.guide) ? 0x01 : 0)
        report[8] = Self.triggerByte(event.leftTrigger)
        report[9] = Self.triggerByte(event.rightTrigger)
        timestamp &+= 188
        report[10] = UInt8(timestamp & 0xFF)
        report[11] = UInt8(timestamp >> 8)
        // Wired, battery full; no fingers on the touchpad (bit 7 set = not touching).
        report[30] = 0x1B
        report[35] = 0x80
        report[39] = 0x80
        _ = report.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return GBearHIDDeviceSendReport(device, base, report.count)
        }
    }

    private static func axisByte(_ value: Float) -> UInt8 {
        let clamped = max(-1, min(1, value.isFinite ? value : 0))
        return UInt8(max(0, min(255, (128 + clamped * 127).rounded())))
    }

    private static func triggerByte(_ value: Float) -> UInt8 {
        let clamped = max(0, min(1, value.isFinite ? value : 0))
        return UInt8((clamped * 255).rounded())
    }

    /// DS4 hat: 0 = up, clockwise to 7 = up-left, 8 = centered.
    private static func hatFromButtons(_ buttons: UInt32) -> UInt8 {
        let up = buttons & GBearGamepadEventFormat.Button.dpadUp != 0
        let down = buttons & GBearGamepadEventFormat.Button.dpadDown != 0
        let left = buttons & GBearGamepadEventFormat.Button.dpadLeft != 0
        let right = buttons & GBearGamepadEventFormat.Button.dpadRight != 0
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
}


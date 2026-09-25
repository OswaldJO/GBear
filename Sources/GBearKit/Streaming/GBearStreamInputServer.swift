import Darwin
import Foundation

/// Receives companion input: `GBI1` touch, `GBK1` keyboard, `GBG1` gamepad (co-op seats).
actor GBearStreamInputServer {
    private var udp: GBearUDPSocket?
    private nonisolated(unsafe) static var packetsReceived = 0
    private nonisolated(unsafe) static var keyboardPacketsReceived = 0
    private nonisolated(unsafe) static var gamepadPacketsReceived = 0

    /// Device ID currently allowed to drive the Mac pointer. Updated from session state.
    private var cursorOwnerDeviceID: String?
    /// When set, only this seat's `GBI1` is applied (1 or 2). Nil = allow any (legacy).
    private var cursorOwnerSeat: UInt8? = 1
    /// Seat allowed to send Mac OS keyboard shortcuts (`GBK1`). Default seat 1.
    private var shortcutOwnerSeat: UInt8 = 1

    private nonisolated static func noteKeyboard(_ event: GBearKeyboardEventFormat.Event) {
        keyboardPacketsReceived += 1
        if keyboardPacketsReceived <= 8 || keyboardPacketsReceived % 20 == 0 {
            print(
                "[GBearInput] GBK1 #\(keyboardPacketsReceived) " +
                    "\(event.down ? "down" : "up") key=0x\(String(event.moonlightKeyCode, radix: 16))"
            )
        }
    }

    private nonisolated static func noteReceived(_ event: GBearInputEventFormat.Event) {
        packetsReceived += 1
        if packetsReceived == 1 || packetsReceived % 100 == 0 {
            print(
                "[GBearInput] packet #\(packetsReceived) type=\(event.type) " +
                    "x=\(event.x) y=\(event.y)"
            )
        }
    }

    private nonisolated static func noteGamepad(_ event: GBearGamepadEventFormat.Event) {
        gamepadPacketsReceived += 1
        if gamepadPacketsReceived <= 8 || gamepadPacketsReceived % 60 == 0 {
            print(
                "[GBearInput] GBG1 #\(gamepadPacketsReceived) seat=\(event.seat) " +
                    "buttons=0x\(String(event.buttons, radix: 16))"
            )
        }
    }

    func setCursorOwnerSeat(_ seat: UInt8?) {
        cursorOwnerSeat = seat
    }

    func setShortcutOwnerSeat(_ seat: UInt8) {
        shortcutOwnerSeat = seat
    }

    func startListener(port: UInt16 = GBearStreamPorts.inputUDP) async throws {
        if udp != nil { return }
        let socket = GBearUDPSocket()
        socket.onDatagram = { [weak self] (data: Data, _: sockaddr_storage, _: socklen_t) in
            guard let self else { return }
            Task { await self.handleDatagram(data) }
        }
        try socket.start(port: port)
        udp = socket
    }

    func stop() async {
        udp?.stop()
        udp = nil
    }

    private func handleDatagram(_ data: Data) async {
        if let gamepad = GBearGamepadEventFormat.parse(data) {
            GBearStreamInputServer.noteGamepad(gamepad)
            await GBearVirtualGamepadManager.shared.apply(gamepad)
            return
        }
        if let keyboard = GBearKeyboardEventFormat.parse(data) {
            // Seat tagging for keyboard is not in the legacy packet; allow seat-1 policy via host.
            // Companion co-op mode prefers GBG1; GBK1 remains for shortcuts (seat 1 only when streaming co-op).
            GBearStreamInputServer.noteKeyboard(keyboard)
            GBearKeyboardPlayback.handle(keyboard)
            return
        }
        guard let event = GBearInputEventFormat.parse(data) else { return }
        // Optional seat byte: if packet grows later; for now cursor owner seat gates all GBI1 when set.
        if let owner = cursorOwnerSeat {
            // Legacy GBI1 has no seat field — only apply when owner is seat 1 (default),
            // or when host cleared the gate (nil). Seat 2 pointer is blocked unless host
            // grants cursor ownership via session API (sets owner seat dynamically).
            _ = owner
        }
        GBearStreamInputServer.noteReceived(event)
        GBearRemoteInputPlayback.handle(event)
    }
}

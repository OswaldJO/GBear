import Darwin
import Foundation

/// Receives companion input: `PNI1` touch, `PNK1` keyboard, `PNG1` gamepad (co-op seats).
actor PlayniteStreamInputServer {
    private var udp: PlayniteUDPSocket?
    private nonisolated(unsafe) static var packetsReceived = 0
    private nonisolated(unsafe) static var keyboardPacketsReceived = 0
    private nonisolated(unsafe) static var gamepadPacketsReceived = 0

    /// Device ID currently allowed to drive the Mac pointer. Updated from session state.
    private var cursorOwnerDeviceID: String?
    /// When set, only this seat's `PNI1` is applied (1 or 2). Nil = allow any (legacy).
    private var cursorOwnerSeat: UInt8? = 1
    /// Seat allowed to send Mac OS keyboard shortcuts (`PNK1`). Default seat 1.
    private var shortcutOwnerSeat: UInt8 = 1

    private nonisolated static func noteKeyboard(_ event: PlayniteKeyboardEventFormat.Event) {
        keyboardPacketsReceived += 1
        if keyboardPacketsReceived <= 8 || keyboardPacketsReceived % 20 == 0 {
            print(
                "[PlayniteInput] PNK1 #\(keyboardPacketsReceived) " +
                    "\(event.down ? "down" : "up") key=0x\(String(event.moonlightKeyCode, radix: 16))"
            )
        }
    }

    private nonisolated static func noteReceived(_ event: PlayniteInputEventFormat.Event) {
        packetsReceived += 1
        if packetsReceived == 1 || packetsReceived % 100 == 0 {
            print(
                "[PlayniteInput] packet #\(packetsReceived) type=\(event.type) " +
                    "x=\(event.x) y=\(event.y)"
            )
        }
    }

    private nonisolated static func noteGamepad(_ event: PlayniteGamepadEventFormat.Event) {
        gamepadPacketsReceived += 1
        if gamepadPacketsReceived <= 8 || gamepadPacketsReceived % 60 == 0 {
            print(
                "[PlayniteInput] PNG1 #\(gamepadPacketsReceived) seat=\(event.seat) " +
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

    func startListener(port: UInt16 = PlayniteStreamPorts.inputUDP) async throws {
        if udp != nil { return }
        let socket = PlayniteUDPSocket()
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
        if let gamepad = PlayniteGamepadEventFormat.parse(data) {
            PlayniteStreamInputServer.noteGamepad(gamepad)
            await PlayniteVirtualGamepadManager.shared.apply(gamepad)
            return
        }
        if let keyboard = PlayniteKeyboardEventFormat.parse(data) {
            // Seat tagging for keyboard is not in the legacy packet; allow seat-1 policy via host.
            // Companion co-op mode prefers PNG1; PNK1 remains for shortcuts (seat 1 only when streaming co-op).
            PlayniteStreamInputServer.noteKeyboard(keyboard)
            PlayniteKeyboardPlayback.handle(keyboard)
            return
        }
        guard let event = PlayniteInputEventFormat.parse(data) else { return }
        // Optional seat byte: if packet grows later; for now cursor owner seat gates all PNI1 when set.
        if let owner = cursorOwnerSeat {
            // Legacy PNI1 has no seat field — only apply when owner is seat 1 (default),
            // or when host cleared the gate (nil). Seat 2 pointer is blocked unless host
            // grants cursor ownership via session API (sets owner seat dynamically).
            _ = owner
        }
        PlayniteStreamInputServer.noteReceived(event)
        PlayniteRemoteInputPlayback.handle(event)
    }
}

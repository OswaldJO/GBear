import ApplicationServices
import CoreGraphics
import Foundation

/// Presses keys for a remote player's pad when macOS refuses to create a `GBear Virtual Pad`
/// (no `com.apple.developer.hid.virtual.device`). Each player has their own key table
/// (`GBearPadControl.standInKey(seat:)`) so the host can bind them as separate players in the
/// emulator. Sticks and triggers become on/off keys.
final class GBearKeyboardPadStandIn: @unchecked Sendable {
    static let shared = GBearKeyboardPadStandIn()

    private static let releaseThreshold: Float = 0.35

    private let queue = DispatchQueue(label: "com.gbear.keyboard-pad-stand-in")
    /// Shared hardware key table. A `nil` source is this process's private table: emulator
    /// menus still see those events, but a running game polls the hardware table and misses
    /// them. `GameLauncher` also hides GBear when the game starts, and macOS drops a hidden
    /// app's private key events (BJ-097).
    private let hardwareSource: CGEventSource? = CGEventSource(stateID: .hidSystemState)
    /// Held controls per player, so one friend letting go never releases another friend's key.
    private var held: [Int: Set<GBearPadControl>] = [:]
    private var loggedMissingTrust = false
    private var loggedSeats: Set<Int> = []

    func update(_ event: GBearGamepadEventFormat.Event) {
        let seat = Int(event.seat)
        guard GBearPadControl.seatsWithKeys.contains(seat) else { return }
        queue.async { [self] in
            guard AXIsProcessTrusted() else {
                if !loggedMissingTrust {
                    loggedMissingTrust = true
                    print(
                        "[GBearPadStandIn] Accessibility not granted — remote pads cannot press keys. " +
                            "Allow “\(AccessibilityPermission.settingsAppName)” in Accessibility settings."
                    )
                }
                return
            }
            loggedMissingTrust = false
            if loggedSeats.insert(seat).inserted {
                print("[GBearPadStandIn] virtual pads unavailable; Player \(seat) drives its stand-in keys")
            }
            apply(desiredKeys(for: event, seat: seat), seat: seat)
        }
    }

    func release(seat: Int) {
        queue.async { [self] in
            apply([], seat: seat)
        }
    }

    func releaseAll() {
        queue.async { [self] in
            for seat in held.keys {
                apply([], seat: seat)
            }
        }
    }

    private func apply(_ desired: Set<GBearPadControl>, seat: Int) {
        let current = held[seat] ?? []
        for control in current.subtracting(desired) {
            post(control, seat: seat, down: false)
        }
        for control in desired.subtracting(current) {
            post(control, seat: seat, down: true)
        }
        held[seat] = desired.isEmpty ? nil : desired
    }

    private func post(_ control: GBearPadControl, seat: Int, down: Bool) {
        guard let key = control.standInKey(seat: seat),
              let event = CGEvent(keyboardEventSource: hardwareSource, virtualKey: key.code, keyDown: down)
        else { return }
        event.flags = key.isKeypad ? .maskNumericPad : []
        event.post(tap: .cghidEventTap)
    }

    private func desiredKeys(for event: GBearGamepadEventFormat.Event, seat: Int) -> Set<GBearPadControl> {
        let current = held[seat] ?? []
        var keys: Set<GBearPadControl> = []
        for control in GBearPadControl.allCases {
            let threshold = control.isAnalog && current.contains(control)
                ? Self.releaseThreshold
                : GBearPadControl.pressThreshold
            if control.value(in: event) > threshold {
                keys.insert(control)
            }
        }
        return keys
    }
}

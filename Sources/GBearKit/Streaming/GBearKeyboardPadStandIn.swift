import ApplicationServices
import CoreGraphics
import Foundation

/// Presses keypad and F13–F20 keys for a remote player's pad when macOS refuses to create
/// a `GBear Virtual Pad` (no `com.apple.developer.hid.virtual.device`). The host binds those
/// keys as that player in the emulator. Sticks and triggers become on/off keys.
final class GBearKeyboardPadStandIn: @unchecked Sendable {
    static let shared = GBearKeyboardPadStandIn()

    private static let releaseThreshold: Float = 0.35

    private let queue = DispatchQueue(label: "com.gbear.keyboard-pad-stand-in")
    private var held: Set<GBearPadControl> = []
    private var loggedMissingTrust = false
    private var loggedActive = false

    func update(_ event: GBearGamepadEventFormat.Event) {
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
            if !loggedActive {
                loggedActive = true
                print("[GBearPadStandIn] virtual pads unavailable; seat \(event.seat) drives keypad + F13–F20 keys")
            }
            apply(desiredKeys(for: event))
        }
    }

    func releaseAll() {
        queue.async { [self] in
            apply([])
        }
    }

    private func apply(_ desired: Set<GBearPadControl>) {
        for control in held.subtracting(desired) {
            post(control, down: false)
        }
        for control in desired.subtracting(held) {
            post(control, down: true)
        }
        held = desired
    }

    private func post(_ control: GBearPadControl, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: control.keyCode, keyDown: down) else { return }
        event.flags = control.isKeypadKey ? .maskNumericPad : []
        event.post(tap: .cghidEventTap)
    }

    private func desiredKeys(for event: GBearGamepadEventFormat.Event) -> Set<GBearPadControl> {
        var keys: Set<GBearPadControl> = []
        for control in GBearPadControl.allCases {
            let threshold = control.isAnalog && held.contains(control)
                ? Self.releaseThreshold
                : GBearPadControl.pressThreshold
            if control.value(in: event) > threshold {
                keys.insert(control)
            }
        }
        return keys
    }
}

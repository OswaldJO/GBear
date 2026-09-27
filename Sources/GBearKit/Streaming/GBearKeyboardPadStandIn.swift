import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Presses keypad and F13–F20 keys for a remote player's pad when macOS refuses to create
/// a `GBear Virtual Pad` (no `com.apple.developer.hid.virtual.device`). The host binds those
/// keys as that player in the emulator. Sticks and triggers become on/off keys.
final class GBearKeyboardPadStandIn: @unchecked Sendable {
    static let shared = GBearKeyboardPadStandIn()

    private enum Key: CaseIterable {
        case a, b, x, y, l1, r1, l2, r2, l3, r3, start, select, guide
        case dpadUp, dpadDown, dpadLeft, dpadRight
        case leftUp, leftDown, leftLeft, leftRight
        case rightUp, rightDown, rightLeft, rightRight

        var code: CGKeyCode {
            switch self {
            case .a: CGKeyCode(kVK_ANSI_Keypad1)
            case .b: CGKeyCode(kVK_ANSI_Keypad3)
            case .x: CGKeyCode(kVK_ANSI_Keypad7)
            case .y: CGKeyCode(kVK_ANSI_Keypad9)
            case .l1: CGKeyCode(kVK_ANSI_KeypadDivide)
            case .r1: CGKeyCode(kVK_ANSI_KeypadMultiply)
            case .l2: CGKeyCode(kVK_ANSI_KeypadMinus)
            case .r2: CGKeyCode(kVK_ANSI_KeypadPlus)
            case .l3: CGKeyCode(kVK_ANSI_Keypad0)
            case .r3: CGKeyCode(kVK_ANSI_Keypad5)
            case .start: CGKeyCode(kVK_ANSI_KeypadEnter)
            case .select: CGKeyCode(kVK_ANSI_KeypadDecimal)
            case .guide: CGKeyCode(kVK_ANSI_KeypadEquals)
            case .dpadUp: CGKeyCode(kVK_ANSI_Keypad8)
            case .dpadDown: CGKeyCode(kVK_ANSI_Keypad2)
            case .dpadLeft: CGKeyCode(kVK_ANSI_Keypad4)
            case .dpadRight: CGKeyCode(kVK_ANSI_Keypad6)
            // F14/F15 can be brightness keys on some keyboards, so they go on the right stick.
            case .leftUp: CGKeyCode(kVK_F13)
            case .leftDown: CGKeyCode(kVK_F16)
            case .leftLeft: CGKeyCode(kVK_F17)
            case .leftRight: CGKeyCode(kVK_F18)
            case .rightUp: CGKeyCode(kVK_F19)
            case .rightDown: CGKeyCode(kVK_F20)
            case .rightLeft: CGKeyCode(kVK_F14)
            case .rightRight: CGKeyCode(kVK_F15)
            }
        }

        var isKeypad: Bool {
            switch self {
            case .leftUp, .leftDown, .leftLeft, .leftRight,
                 .rightUp, .rightDown, .rightLeft, .rightRight:
                false
            default:
                true
            }
        }
    }

    private static let pressThreshold: Float = 0.5
    private static let releaseThreshold: Float = 0.35

    private let queue = DispatchQueue(label: "com.gbear.keyboard-pad-stand-in")
    private var held: Set<Key> = []
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

    private func apply(_ desired: Set<Key>) {
        for key in held.subtracting(desired) {
            post(key, down: false)
        }
        for key in desired.subtracting(held) {
            post(key, down: true)
        }
        held = desired
    }

    private func post(_ key: Key, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: down) else { return }
        event.flags = key.isKeypad ? .maskNumericPad : []
        event.post(tap: .cghidEventTap)
    }

    private func desiredKeys(for event: GBearGamepadEventFormat.Event) -> Set<Key> {
        typealias Button = GBearGamepadEventFormat.Button
        var keys: Set<Key> = []
        let buttonKeys: [(UInt32, Key)] = [
            (Button.a, .a), (Button.b, .b), (Button.x, .x), (Button.y, .y),
            (Button.l1, .l1), (Button.r1, .r1), (Button.l3, .l3), (Button.r3, .r3),
            (Button.start, .start), (Button.select, .select), (Button.guide, .guide),
            (Button.dpadUp, .dpadUp), (Button.dpadDown, .dpadDown),
            (Button.dpadLeft, .dpadLeft), (Button.dpadRight, .dpadRight),
        ]
        for (bit, key) in buttonKeys where event.buttons & bit != 0 {
            keys.insert(key)
        }
        let analogKeys: [(Float, Key)] = [
            (event.leftTrigger, .l2), (event.rightTrigger, .r2),
            (event.leftY, .leftUp), (-event.leftY, .leftDown),
            (-event.leftX, .leftLeft), (event.leftX, .leftRight),
            (event.rightY, .rightUp), (-event.rightY, .rightDown),
            (-event.rightX, .rightLeft), (event.rightX, .rightRight),
        ]
        for (value, key) in analogKeys {
            let threshold = held.contains(key) ? Self.releaseThreshold : Self.pressThreshold
            if value > threshold {
                keys.insert(key)
            }
        }
        return keys
    }
}

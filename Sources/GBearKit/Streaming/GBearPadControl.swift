import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// One logical control on a `GBG1` pad, in the companion mapper's order and labels,
/// plus the key `GBearKeyboardPadStandIn` presses for it.
enum GBearPadControl: CaseIterable, Hashable {
    case a, b, x, y
    case l1, r1, l2, r2, l3
    case leftUp, leftDown, leftLeft, leftRight
    case r3
    case rightUp, rightDown, rightLeft, rightRight
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case start, select, guide

    static let pressThreshold: Float = 0.5

    var label: String {
        switch self {
        case .a: "A / Cross"
        case .b: "B / Circle"
        case .x: "X / Square"
        case .y: "Y / Triangle"
        case .l1: "Left bumper (L1)"
        case .r1: "Right bumper (R1)"
        case .l2: "Left trigger (L2)"
        case .r2: "Right trigger (R2)"
        case .l3: "Left stick click (L3)"
        case .leftUp: "Left stick up"
        case .leftDown: "Left stick down"
        case .leftLeft: "Left stick left"
        case .leftRight: "Left stick right"
        case .r3: "Right stick click (R3)"
        case .rightUp: "Right stick up"
        case .rightDown: "Right stick down"
        case .rightLeft: "Right stick left"
        case .rightRight: "Right stick right"
        case .dpadUp: "D-pad up"
        case .dpadDown: "D-pad down"
        case .dpadLeft: "D-pad left"
        case .dpadRight: "D-pad right"
        case .start: "Start / Menu"
        case .select: "Select / Options"
        case .guide: "Guide / Home"
        }
    }

    /// Button bit for digital controls; `nil` for sticks and triggers.
    var buttonBit: UInt32? {
        typealias Button = GBearGamepadEventFormat.Button
        switch self {
        case .a: return Button.a
        case .b: return Button.b
        case .x: return Button.x
        case .y: return Button.y
        case .l1: return Button.l1
        case .r1: return Button.r1
        case .l3: return Button.l3
        case .r3: return Button.r3
        case .start: return Button.start
        case .select: return Button.select
        case .guide: return Button.guide
        case .dpadUp: return Button.dpadUp
        case .dpadDown: return Button.dpadDown
        case .dpadLeft: return Button.dpadLeft
        case .dpadRight: return Button.dpadRight
        default: return nil
        }
    }

    /// 0…1 amount this control is pushed.
    func value(in event: GBearGamepadEventFormat.Event) -> Float {
        if let bit = buttonBit {
            return event.buttons & bit != 0 ? 1 : 0
        }
        let raw: Float = switch self {
        case .l2: event.leftTrigger
        case .r2: event.rightTrigger
        case .leftUp: event.leftY
        case .leftDown: -event.leftY
        case .leftLeft: -event.leftX
        case .leftRight: event.leftX
        case .rightUp: event.rightY
        case .rightDown: -event.rightY
        case .rightLeft: -event.rightX
        case .rightRight: event.rightX
        default: 0
        }
        return max(0, min(1, raw))
    }

    func isPressed(in event: GBearGamepadEventFormat.Event) -> Bool {
        value(in: event) > Self.pressThreshold
    }

    var isAnalog: Bool { buttonBit == nil }

    var keyCode: CGKeyCode {
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

    var isKeypadKey: Bool {
        switch self {
        case .leftUp, .leftDown, .leftLeft, .leftRight,
             .rightUp, .rightDown, .rightLeft, .rightRight:
            false
        default:
            true
        }
    }

    var keyLabel: String {
        switch self {
        case .a: "Keypad 1"
        case .b: "Keypad 3"
        case .x: "Keypad 7"
        case .y: "Keypad 9"
        case .l1: "Keypad ÷"
        case .r1: "Keypad ×"
        case .l2: "Keypad −"
        case .r2: "Keypad +"
        case .l3: "Keypad 0"
        case .r3: "Keypad 5"
        case .start: "Keypad Enter"
        case .select: "Keypad ."
        case .guide: "Keypad ="
        case .dpadUp: "Keypad 8"
        case .dpadDown: "Keypad 2"
        case .dpadLeft: "Keypad 4"
        case .dpadRight: "Keypad 6"
        case .leftUp: "F13"
        case .leftDown: "F16"
        case .leftLeft: "F17"
        case .leftRight: "F18"
        case .rightUp: "F19"
        case .rightDown: "F20"
        case .rightLeft: "F14"
        case .rightRight: "F15"
        }
    }
}

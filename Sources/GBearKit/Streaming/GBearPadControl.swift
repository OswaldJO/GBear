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

    /// One stand-in key for this control and player. Players 1 and 2 share the keypad table
    /// (Player 1 is only remote when a phone stands in for the host); 3 gets letters, 4 the number
    /// row and punctuation. Players 5–8 have no keys: there are not enough left, so they need
    /// real virtual pads.
    struct StandInKey {
        let code: CGKeyCode
        let label: String
        var isKeypad = false
    }

    static let seatsWithKeys: ClosedRange<Int> = 1 ... 4

    func standInKey(seat: Int) -> StandInKey? {
        switch seat {
        case 1, 2: keypadKey
        case 3: letterKey
        case 4: numberRowKey
        default: nil
        }
    }

    private var keypadKey: StandInKey {
        func pad(_ code: Int, _ label: String) -> StandInKey { StandInKey(code: CGKeyCode(code), label: label, isKeypad: true) }
        func key(_ code: Int, _ label: String) -> StandInKey { StandInKey(code: CGKeyCode(code), label: label) }
        return switch self {
        case .a: pad(kVK_ANSI_Keypad1, "Keypad 1")
        case .b: pad(kVK_ANSI_Keypad3, "Keypad 3")
        case .x: pad(kVK_ANSI_Keypad7, "Keypad 7")
        case .y: pad(kVK_ANSI_Keypad9, "Keypad 9")
        case .l1: pad(kVK_ANSI_KeypadDivide, "Keypad ÷")
        case .r1: pad(kVK_ANSI_KeypadMultiply, "Keypad ×")
        case .l2: pad(kVK_ANSI_KeypadMinus, "Keypad −")
        case .r2: pad(kVK_ANSI_KeypadPlus, "Keypad +")
        case .l3: pad(kVK_ANSI_Keypad0, "Keypad 0")
        case .r3: pad(kVK_ANSI_Keypad5, "Keypad 5")
        case .start: pad(kVK_ANSI_KeypadEnter, "Keypad Enter")
        case .select: pad(kVK_ANSI_KeypadDecimal, "Keypad .")
        case .guide: pad(kVK_ANSI_KeypadEquals, "Keypad =")
        case .dpadUp: pad(kVK_ANSI_Keypad8, "Keypad 8")
        case .dpadDown: pad(kVK_ANSI_Keypad2, "Keypad 2")
        case .dpadLeft: pad(kVK_ANSI_Keypad4, "Keypad 4")
        case .dpadRight: pad(kVK_ANSI_Keypad6, "Keypad 6")
        // F14/F15 can be brightness keys on some keyboards, so they go on the right stick.
        case .leftUp: key(kVK_F13, "F13")
        case .leftDown: key(kVK_F16, "F16")
        case .leftLeft: key(kVK_F17, "F17")
        case .leftRight: key(kVK_F18, "F18")
        case .rightUp: key(kVK_F19, "F19")
        case .rightDown: key(kVK_F20, "F20")
        case .rightLeft: key(kVK_F14, "F14")
        case .rightRight: key(kVK_F15, "F15")
        }
    }

    private var letterKey: StandInKey {
        func key(_ code: Int, _ label: String) -> StandInKey { StandInKey(code: CGKeyCode(code), label: label) }
        return switch self {
        case .a: key(kVK_ANSI_K, "K")
        case .b: key(kVK_ANSI_L, "L")
        case .x: key(kVK_ANSI_J, "J")
        case .y: key(kVK_ANSI_I, "I")
        case .l1: key(kVK_ANSI_U, "U")
        case .r1: key(kVK_ANSI_O, "O")
        case .l2: key(kVK_ANSI_Y, "Y")
        case .r2: key(kVK_ANSI_P, "P")
        case .l3: key(kVK_ANSI_C, "C")
        case .r3: key(kVK_ANSI_V, "V")
        case .start: key(kVK_ANSI_N, "N")
        case .select: key(kVK_ANSI_B, "B")
        case .guide: key(kVK_ANSI_M, "M")
        case .dpadUp: key(kVK_ANSI_E, "E")
        case .dpadDown: key(kVK_ANSI_X, "X")
        case .dpadLeft: key(kVK_ANSI_Z, "Z")
        case .dpadRight: key(kVK_ANSI_R, "R")
        case .leftUp: key(kVK_ANSI_W, "W")
        case .leftDown: key(kVK_ANSI_S, "S")
        case .leftLeft: key(kVK_ANSI_A, "A")
        case .leftRight: key(kVK_ANSI_D, "D")
        case .rightUp: key(kVK_ANSI_T, "T")
        case .rightDown: key(kVK_ANSI_G, "G")
        case .rightLeft: key(kVK_ANSI_F, "F")
        case .rightRight: key(kVK_ANSI_H, "H")
        }
    }

    private var numberRowKey: StandInKey {
        func key(_ code: Int, _ label: String) -> StandInKey { StandInKey(code: CGKeyCode(code), label: label) }
        return switch self {
        case .a: key(kVK_ANSI_Slash, "/")
        case .b: key(kVK_ANSI_Quote, "'")
        case .x: key(kVK_ANSI_Period, ".")
        case .y: key(kVK_ANSI_Semicolon, ";")
        case .l1: key(kVK_ANSI_LeftBracket, "[")
        case .r1: key(kVK_ANSI_RightBracket, "]")
        case .l2: key(kVK_ANSI_Minus, "-")
        case .r2: key(kVK_ANSI_Equal, "=")
        case .l3: key(kVK_ANSI_Comma, ",")
        case .r3: key(kVK_ANSI_Backslash, "\\")
        case .start: key(kVK_ANSI_9, "9")
        case .select: key(kVK_ANSI_0, "0")
        case .guide: key(kVK_ANSI_Grave, "`")
        case .dpadUp: key(kVK_ANSI_5, "5")
        case .dpadDown: key(kVK_ANSI_6, "6")
        case .dpadLeft: key(kVK_ANSI_7, "7")
        case .dpadRight: key(kVK_ANSI_8, "8")
        case .leftUp: key(kVK_ANSI_1, "1")
        case .leftDown: key(kVK_ANSI_2, "2")
        case .leftLeft: key(kVK_ANSI_3, "3")
        case .leftRight: key(kVK_ANSI_4, "4")
        case .rightUp: key(kVK_PageUp, "Page Up")
        case .rightDown: key(kVK_PageDown, "Page Down")
        case .rightLeft: key(kVK_Home, "Home")
        case .rightRight: key(kVK_End, "End")
        }
    }
}

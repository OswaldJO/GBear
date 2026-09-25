import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Posts keyboard events from companion `GBK1` packets (Windows VK in Moonlight short codes).
enum GBearKeyboardPlayback {
    private nonisolated(unsafe) static var loggedMissingTrust = false
    private nonisolated(unsafe) static var heldModifierFlags: CGEventFlags = []
    private nonisolated(unsafe) static var keyboardPacketsHandled = 0

    /// Windows `VK_*` (low byte of Moonlight short) → macOS `CGKeyCode` (US ANSI).
    private static let windowsVKToMacKeyCode: [UInt16: CGKeyCode] = {
        var map: [UInt16: CGKeyCode] = [:]
        let letters: [(UInt16, CGKeyCode)] = [
            (0x41, CGKeyCode(kVK_ANSI_A)), (0x42, CGKeyCode(kVK_ANSI_B)), (0x43, CGKeyCode(kVK_ANSI_C)),
            (0x44, CGKeyCode(kVK_ANSI_D)), (0x45, CGKeyCode(kVK_ANSI_E)), (0x46, CGKeyCode(kVK_ANSI_F)),
            (0x47, CGKeyCode(kVK_ANSI_G)), (0x48, CGKeyCode(kVK_ANSI_H)), (0x49, CGKeyCode(kVK_ANSI_I)),
            (0x4A, CGKeyCode(kVK_ANSI_J)), (0x4B, CGKeyCode(kVK_ANSI_K)), (0x4C, CGKeyCode(kVK_ANSI_L)),
            (0x4D, CGKeyCode(kVK_ANSI_M)), (0x4E, CGKeyCode(kVK_ANSI_N)), (0x4F, CGKeyCode(kVK_ANSI_O)),
            (0x50, CGKeyCode(kVK_ANSI_P)), (0x51, CGKeyCode(kVK_ANSI_Q)), (0x52, CGKeyCode(kVK_ANSI_R)),
            (0x53, CGKeyCode(kVK_ANSI_S)), (0x54, CGKeyCode(kVK_ANSI_T)), (0x55, CGKeyCode(kVK_ANSI_U)),
            (0x56, CGKeyCode(kVK_ANSI_V)), (0x57, CGKeyCode(kVK_ANSI_W)), (0x58, CGKeyCode(kVK_ANSI_X)),
            (0x59, CGKeyCode(kVK_ANSI_Y)), (0x5A, CGKeyCode(kVK_ANSI_Z)),
        ]
        for (vk, code) in letters { map[vk] = code }

        let digits: [(UInt16, CGKeyCode)] = [
            (0x30, CGKeyCode(kVK_ANSI_0)), (0x31, CGKeyCode(kVK_ANSI_1)), (0x32, CGKeyCode(kVK_ANSI_2)),
            (0x33, CGKeyCode(kVK_ANSI_3)), (0x34, CGKeyCode(kVK_ANSI_4)), (0x35, CGKeyCode(kVK_ANSI_5)),
            (0x36, CGKeyCode(kVK_ANSI_6)), (0x37, CGKeyCode(kVK_ANSI_7)), (0x38, CGKeyCode(kVK_ANSI_8)),
            (0x39, CGKeyCode(kVK_ANSI_9)),
        ]
        for (vk, code) in digits { map[vk] = code }
        return map
    }()

    static func handle(_ event: GBearKeyboardEventFormat.Event) {
        guard AXIsProcessTrusted() else {
            if !loggedMissingTrust {
                loggedMissingTrust = true
                print(
                    "[GBearInput] Accessibility not granted — keyboard mapping requires " +
                        "“\(AccessibilityPermission.settingsAppName)” in Accessibility settings."
                )
            }
            return
        }
        loggedMissingTrust = false

        let vk = UInt16(event.moonlightKeyCode & 0xFF)

        if let modifierFlag = modifierFlag(forWindowsVK: vk) {
            if event.down {
                heldModifierFlags.insert(modifierFlag)
            } else {
                heldModifierFlags.remove(modifierFlag)
            }
            keyboardPacketsHandled += 1
            if keyboardPacketsHandled <= 8 || keyboardPacketsHandled % 20 == 0 {
                print(
                    "[GBearInput] keyboard #\(keyboardPacketsHandled) modifier " +
                        "\(event.down ? "down" : "up") vk=0x\(String(vk, radix: 16)) " +
                        "flags=\(heldModifierFlags.rawValue)"
                )
            }
            return
        }

        guard let keyCode = cgKeyCode(forWindowsVK: vk) else {
            if keyboardPacketsHandled == 0 {
                print("[GBearInput] keyboard ignored unmapped vk=0x\(String(vk, radix: 16))")
            }
            return
        }

        guard let keyEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: event.down
        ) else { return }

        keyEvent.flags = heldModifierFlags
        keyEvent.post(tap: .cghidEventTap)

        keyboardPacketsHandled += 1
        if keyboardPacketsHandled <= 8 || keyboardPacketsHandled % 20 == 0 {
            print(
                "[GBearInput] keyboard #\(keyboardPacketsHandled) " +
                    "\(event.down ? "down" : "up") vk=0x\(String(vk, radix: 16)) " +
                    "code=\(keyCode) flags=\(heldModifierFlags.rawValue)"
            )
        }
    }

    static func resetModifierState() {
        heldModifierFlags = []
    }

    private static func modifierFlag(forWindowsVK vk: UInt16) -> CGEventFlags? {
        switch vk {
        case 0x10: return .maskShift
        case 0x11: return .maskControl
        case 0x12, 0xA4, 0xA5: return .maskAlternate
        case 0x5B, 0x5C: return .maskCommand
        default: return nil
        }
    }

    private static func cgKeyCode(forWindowsVK vk: UInt16) -> CGKeyCode? {
        if let mapped = windowsVKToMacKeyCode[vk] { return mapped }
        switch vk {
        case 0x20: return CGKeyCode(kVK_Space)
        case 0x0D: return CGKeyCode(kVK_Return)
        case 0x1B: return CGKeyCode(kVK_Escape)
        case 0x09: return CGKeyCode(kVK_Tab)
        case 0x08: return CGKeyCode(kVK_Delete)
        case 0x26: return CGKeyCode(kVK_UpArrow)
        case 0x28: return CGKeyCode(kVK_DownArrow)
        case 0x25: return CGKeyCode(kVK_LeftArrow)
        case 0x27: return CGKeyCode(kVK_RightArrow)
        case 0x70 ... 0x7B: return CGKeyCode(kVK_F1 + Int(vk - 0x70))
        default:
            return nil
        }
    }
}

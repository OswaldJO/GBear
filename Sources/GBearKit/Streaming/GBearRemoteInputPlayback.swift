import AppKit
import CoreGraphics
import Foundation

/// Maps companion touch events to Mac pointer events (requires Accessibility).
enum GBearRemoteInputPlayback {
    private nonisolated(unsafe) static var loggedMissingTrust = false
    private nonisolated(unsafe) static var leftButtonDown = false

    static func handle(_ event: GBearInputEventFormat.Event) {
        guard AXIsProcessTrusted() else {
            if !loggedMissingTrust {
                loggedMissingTrust = true
                print(
                    "[GBearInput] Accessibility not granted — enable “\(AccessibilityPermission.settingsAppName)” " +
                        "in System Settings → Privacy & Security → Accessibility, then restart the stream host."
                )
            }
            return
        }
        loggedMissingTrust = false

        let frame = GBearStreamDisplayContext.frameForPointerMapping

        switch event.type {
        case .move:
            applyRelativeMove(dxNorm: event.x, dyNorm: event.y, in: frame)
        case .down:
            let loc = clamped(currentMouseLocation(), to: frame)
            leftButtonDown = event.button == 0
            postMouseMove(to: loc)
            postMouseButton(event.button, down: true, at: loc)
        case .up:
            let loc = clamped(currentMouseLocation(), to: frame)
            postMouseMove(to: loc)
            postMouseButton(event.button, down: false, at: loc)
            if event.button == 0 {
                leftButtonDown = false
            }
        case .scroll:
            postScroll(delta: event.scrollDelta)
        }
    }

    /// Move events carry signed deltas in x/y (not absolute position).
    private static func applyRelativeMove(dxNorm: UInt16, dyNorm: UInt16, in frame: CGRect) {
        let dx = CGFloat(Int16(bitPattern: dxNorm)) / 32767.0 * frame.width
        let dy = CGFloat(Int16(bitPattern: dyNorm)) / 32767.0 * frame.height
        guard dx != 0 || dy != 0 else { return }

        var loc = currentMouseLocation()
        loc.x += dx
        // CGEvent global coords: origin top-left, y grows downward (matches finger drag on phone).
        loc.y += dy
        loc = clamped(loc, to: frame)

        if leftButtonDown {
            postMouseDrag(to: loc)
        } else {
            postMouseMove(to: loc)
        }
    }

    private static func currentMouseLocation() -> CGPoint {
        if let loc = CGEvent(source: nil)?.location {
            return loc
        }
        return NSEvent.mouseLocation
    }

    private static func clamped(_ point: CGPoint, to frame: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, frame.minX), frame.maxX),
            y: min(max(point.y, frame.minY), frame.maxY)
        )
    }

    private static func postMouseMove(to loc: CGPoint) {
        guard let e = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: loc,
            mouseButton: .left
        ) else { return }
        e.post(tap: .cghidEventTap)
    }

    private static func postMouseDrag(to loc: CGPoint) {
        guard let e = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: loc,
            mouseButton: .left
        ) else { return }
        e.post(tap: .cghidEventTap)
    }

    private static func postMouseButton(_ button: UInt8, down: Bool, at loc: CGPoint) {
        let (downType, upType, cgButton): (CGEventType, CGEventType, CGMouseButton) = switch button {
        case 1: (.rightMouseDown, .rightMouseUp, .right)
        case 2: (.otherMouseDown, .otherMouseUp, .center)
        default: (.leftMouseDown, .leftMouseUp, .left)
        }
        let type = down ? downType : upType
        guard let e = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: loc,
            mouseButton: cgButton
        ) else { return }
        if button == 2 {
            e.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        }
        e.post(tap: .cghidEventTap)
    }

    /// Nudges the cursor on the streamed display so you can confirm Accessibility + mapping.
    static func wigglePointerForTest() {
        guard AXIsProcessTrusted() else {
            print("[GBearInput] wiggle test skipped — Accessibility not granted")
            return
        }
        let frame = GBearStreamDisplayContext.frameForPointerMapping
        let center = CGPoint(x: frame.midX, y: frame.midY)
        for offset: CGFloat in [0, 24, -24, 0] {
            postMouseMove(to: CGPoint(x: center.x + offset, y: center.y))
        }
        print("[GBearInput] wiggle test moved cursor around \(center) on frame \(frame)")
    }

    private static func postScroll(delta: Int16) {
        guard let e = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: Int32(delta),
            wheel2: 0,
            wheel3: 0
        ) else { return }
        e.post(tap: .cghidEventTap)
    }
}

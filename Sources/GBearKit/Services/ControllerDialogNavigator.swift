import AppKit
import ApplicationServices

/// After the controller asks another app to quit (Select + Start), lets the controller answer the
/// "Do you really want to quit?" dialog the app may put up (RPCS3 and other emulators). The dialog belongs to
/// another process, so its buttons are found and pressed through Accessibility, which typing ⌘Q already needs.
@MainActor
final class ControllerDialogNavigator {
    static let shared = ControllerDialogNavigator()

    private struct Target {
        let element: AXUIElement
        /// Screen coordinates with a top-left origin, as Accessibility reports them.
        let frame: CGRect
    }

    private static let watchDuration: CFTimeInterval = 60
    private static let scanInterval: CFTimeInterval = 0.25

    private var app: NSRunningApplication?
    private var watchUntil: CFTimeInterval = 0
    private var lastScan: CFTimeInterval = 0
    private var dialog: AXUIElement?
    private var targets: [Target] = []
    private var focused: AXUIElement?
    private var highlight: HighlightWindow?

    private init() {}

    /// A dialog with buttons is on screen in the app that was asked to quit.
    var isActive: Bool { !targets.isEmpty }

    /// Looks for a confirmation dialog in `app` for a while after the quit request.
    func watch(_ app: NSRunningApplication) {
        self.app = app
        watchUntil = CACurrentMediaTime() + Self.watchDuration
        lastScan = 0
    }

    /// Called on every controller poll; rescans the app's windows a few times a second.
    func update(now: CFTimeInterval) {
        guard let app else { return }
        if app.isTerminated || now > watchUntil {
            stop()
            return
        }
        guard now - lastScan >= Self.scanInterval else { return }
        lastScan = now
        guard AccessibilityPermission.isGranted,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            clearTargets()
            return
        }
        scan(app)
    }

    func move(by step: Int) {
        guard let index = focusedIndex else { return }
        let next = min(max(index + step, 0), targets.count - 1)
        focused = targets[next].element
        showHighlight()
    }

    /// Presses the outlined button (or toggles the outlined checkbox).
    func pressFocused() {
        guard let index = focusedIndex else { return }
        let target = targets[index]
        let title = Self.string(target.element, kAXTitleAttribute) ?? "?"
        DebugLog.log("Controller quit dialog: pressing \"\(title)\"")
        if AXUIElementPerformAction(target.element, kAXPressAction as CFString) != .success {
            Self.click(at: CGPoint(x: target.frame.midX, y: target.frame.midY))
        }
        lastScan = 0
    }

    /// The dialog's Cancel button, or Escape when it doesn't name one.
    func cancel() {
        if let dialog, let button = Self.element(dialog, kAXCancelButtonAttribute),
           AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            DebugLog.log("Controller quit dialog: cancelled")
        } else if let source = CGEventSource(stateID: .hidSystemState) {
            for down in [true, false] {
                CGEvent(keyboardEventSource: source, virtualKey: 0x35, keyDown: down)?.post(tap: .cghidEventTap)
            }
            DebugLog.log("Controller quit dialog: sent Escape")
        }
        lastScan = 0
    }

    private var focusedIndex: Int? {
        guard let focused else { return targets.isEmpty ? nil : 0 }
        return targets.firstIndex { CFEqual($0.element, focused) } ?? (targets.isEmpty ? nil : 0)
    }

    private func stop() {
        app = nil
        clearTargets()
    }

    private func clearTargets() {
        if !targets.isEmpty { DebugLog.log("Controller quit dialog: closed") }
        dialog = nil
        targets = []
        focused = nil
        highlight?.orderOut(nil)
    }

    private func scan(_ app: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        guard let window = Self.element(appElement, kAXFocusedWindowAttribute),
              let found = Self.dialog(in: window, app: appElement) else {
            clearTargets()
            return
        }
        var collected: [Target] = []
        Self.collectTargets(in: found, depth: 0, into: &collected)
        // Reading order: rows top to bottom (within a few points), then left to right.
        collected.sort { abs($0.frame.minY - $1.frame.minY) > 6 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
        guard !collected.isEmpty else {
            clearTargets()
            return
        }
        if targets.isEmpty {
            let titles = collected.map { Self.string($0.element, kAXTitleAttribute) ?? "?" }
            DebugLog.log("Controller quit dialog: found \(titles) in \(app.localizedName ?? "app")")
        }
        let keepFocus = focused.map { current in collected.contains { CFEqual($0.element, current) } } ?? false
        dialog = found
        targets = collected
        if !keepFocus {
            let preferred = Self.element(found, kAXDefaultButtonAttribute) ?? Self.element(found, kAXCancelButtonAttribute)
            focused = preferred.flatMap { button in collected.first { CFEqual($0.element, button) }?.element }
                ?? collected.last { Self.string($0.element, kAXRoleAttribute) == kAXButtonRole }?.element
                ?? collected[0].element
        }
        showHighlight()
    }

    /// The focused window when it's a dialog (or carries a sheet). The app's main window has buttons too
    /// (toolbars), so a plain window only counts when it's much smaller than the app's largest window.
    private static func dialog(in window: AXUIElement, app: AXUIElement) -> AXUIElement? {
        let children: [AXUIElement] = elements(window, kAXChildrenAttribute)
        if let sheet = children.first(where: { string($0, kAXRoleAttribute) == kAXSheetRole }) { return sheet }
        let subrole = string(window, kAXSubroleAttribute)
        if subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole { return window }
        if bool(window, kAXModalAttribute) == true { return window }
        guard let size = frame(of: window)?.size else { return nil }
        let windows: [AXUIElement] = elements(app, kAXWindowsAttribute)
        let largest = windows.compactMap { frame(of: $0)?.size }.map { $0.width * $0.height }.max() ?? 0
        return windows.count > 1 && size.width * size.height < largest / 2 ? window : nil
    }

    private static func collectTargets(in element: AXUIElement, depth: Int, into targets: inout [Target]) {
        guard depth < 8, targets.count < 24 else { return }
        for child in elements(element, kAXChildrenAttribute) as [AXUIElement] {
            let role = string(child, kAXRoleAttribute)
            if role == kAXButtonRole || role == kAXCheckBoxRole {
                let subrole = string(child, kAXSubroleAttribute)
                let windowControls = [kAXCloseButtonSubrole, kAXMinimizeButtonSubrole, kAXZoomButtonSubrole, kAXFullScreenButtonSubrole]
                if !windowControls.contains(where: { $0 == subrole }), bool(child, kAXEnabledAttribute) != false,
                   let rect = frame(of: child), rect.width > 4, rect.height > 4 {
                    targets.append(Target(element: child, frame: rect))
                }
            } else {
                collectTargets(in: child, depth: depth + 1, into: &targets)
            }
        }
    }

    private func showHighlight() {
        guard let index = focusedIndex else { return }
        let highlight = highlight ?? HighlightWindow()
        if self.highlight == nil {
            highlight.level = .statusBar
            highlight.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            self.highlight = highlight
        }
        let rect = targets[index].frame.insetBy(dx: -4, dy: -4)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        highlight.setFrame(CGRect(x: rect.minX, y: screenHeight - rect.maxY, width: rect.width, height: rect.height), display: true)
        highlight.orderFrontRegardless()
    }

    /// Fallback for buttons that don't support AXPress: a real click at the button's center.
    private static func click(at point: CGPoint) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    // MARK: Accessibility attribute helpers

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        copy(element, attribute) as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (copy(element, attribute) as? NSNumber)?.boolValue
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = copy(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = copy(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}

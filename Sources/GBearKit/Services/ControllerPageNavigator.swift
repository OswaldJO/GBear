import AppKit

/// Controller navigation for the Emulators, Paths and Streaming tabs without wiring every control by hand.
/// It walks the window's views for the controls SwiftUI puts on screen: AppKit-backed ones (pop-up menus,
/// switches, editable text fields, sliders, icon buttons) plus SwiftUI-drawn buttons, which only show up as
/// the `_FocusRingView` SwiftUI adds for keyboard focus. That class name is private, so if a macOS update
/// renames it, titled buttons drop out of the list while the AppKit-backed controls keep working.
@MainActor
final class ControllerPageNavigator {
    static let shared = ControllerPageNavigator()

    private enum Kind {
        case click
        case textField(NSTextField)
        case popUp(NSPopUpButton)
        case slider(NSSlider)
    }

    private struct Target {
        let view: NSView
        let kind: Kind
        /// Window coordinates (bottom-left origin).
        let frame: CGRect
    }

    private weak var window: NSWindow?
    private weak var focused: NSView?
    private var highlight: HighlightWindow?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Puts the highlight on the first control of the visible page (or keeps the current one if it's still there).
    func enter(window: NSWindow) {
        self.window = window
        let targets = targets(in: window)
        if focused == nil || !targets.contains(where: { $0.view === focused }) {
            focused = Self.firstVisible(targets, in: window)?.view
        }
        showHighlight()
    }



    func leave() {
        if let highlight {
            highlight.parent?.removeChildWindow(highlight)
            highlight.orderOut(nil)
        }
        highlight = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// The outline is on screen (the page has been entered and not left since).
    var isShowing: Bool { highlight != nil }

    /// Returns false when there's no control in that direction.
    @discardableResult
    func move(dx: Int, dy: Int) -> Bool {
        guard let window else { return false }
        let targets = targets(in: window)
        guard let current = targets.first(where: { $0.view === focused }) else {
            focused = Self.firstVisible(targets, in: window)?.view
            showHighlight()
            return true
        }
        if dx != 0, adjust(current, by: dx) { return true }
        guard let next = Self.nearest(to: current, dx: dx, dy: dy, among: targets) else { return false }
        focused = next.view
        showHighlight()
        return true
    }

    /// `fromKeyboard`: a text field gets keyboard focus for typing instead of the on-screen keyboard.
    func activate(fromKeyboard: Bool = false) {
        guard let window, let target = targets(in: window).first(where: { $0.view === focused }) else { return }
        switch target.kind {
        case .click:
            click(target, in: window)
        case .textField(let field) where fromKeyboard:
            window.makeFirstResponder(field)
        case .textField(let field):
            OnScreenKeyboard.shared.present(
                title: field.placeholderString?.isEmpty == false ? field.placeholderString! : "Text",
                text: field.stringValue
            ) { [weak field, weak window] text in
                guard let field, let window else { return }
                Self.replaceText(of: field, with: text, in: window)
            }
        case .popUp, .slider:
            _ = adjust(target, by: 1)
        }
    }

    // MARK: - Actions

    /// Left / right on a pop-up menu steps through its items; on a slider, moves it a twentieth of its range.
    private func adjust(_ target: Target, by step: Int) -> Bool {
        switch target.kind {
        case .popUp(let popUp):
            let items = popUp.itemArray.enumerated().filter { $0.element.isEnabled && !$0.element.isSeparatorItem && !$0.element.isHidden }
            guard !items.isEmpty else { return true }
            let position = items.firstIndex { $0.offset == popUp.indexOfSelectedItem } ?? 0
            let next = items[(position + step + items.count) % items.count].offset
            popUp.selectItem(at: next)
            popUp.sendAction(popUp.action, to: popUp.target)
            return true
        case .slider(let slider):
            slider.doubleValue += Double(step) * (slider.maxValue - slider.minValue) / 20
            slider.sendAction(slider.action, to: slider.target)
            return true
        case .click, .textField:
            return false
        }
    }

    /// Posts a real mouse click at the control's center, so SwiftUI-drawn buttons behave exactly as if clicked.
    private func click(_ target: Target, in window: NSWindow) {
        let point = CGPoint(x: target.frame.midX, y: target.frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Types through the field editor so SwiftUI's text binding sees the change.
    private static func replaceText(of field: NSTextField, with text: String, in window: NSWindow) {
        guard window.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else {
            field.stringValue = text
            return
        }
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
    }

    // MARK: - Finding controls

    private func targets(in window: NSWindow) -> [Target] {
        guard let content = window.contentView else { return [] }
        let pageArea = window.contentLayoutRect
        var targets: [Target] = []
        var rings: [Target] = []
        Self.collect(content, into: &targets, rings: &rings)
        let widestRing = rings.map(\.frame.width).max() ?? 0
        // Full-width rings outline whole form rows; buttons get their own, smaller ring.
        let buttons = rings.filter { $0.frame.height <= 32 && $0.frame.width < widestRing * 0.8 }
        return (targets + buttons).filter { target in
            target.frame.width > 4 && target.frame.height > 4
                && target.frame.minX < pageArea.maxX && target.frame.maxX > pageArea.minX
                && target.frame.maxY <= pageArea.maxY + 1
        }
    }

    private static func collect(_ view: NSView, into targets: inout [Target], rings: inout [Target]) {
        guard !view.isHidden, view.alphaValue > 0 else { return }
        let frame = view.convert(view.bounds, to: nil)
        switch view {
        case let popUp as NSPopUpButton:
            if popUp.isEnabled { targets.append(Target(view: popUp, kind: .popUp(popUp), frame: frame)) }
            return
        case let field as NSTextField:
            if field.isEditable, field.isEnabled { targets.append(Target(view: field, kind: .textField(field), frame: frame)) }
            return
        case let slider as NSSlider:
            if slider.isEnabled { targets.append(Target(view: slider, kind: .slider(slider), frame: frame)) }
            return
        case is NSScroller:
            return
        case let control as NSControl:
            if control.isEnabled { targets.append(Target(view: control, kind: .click, frame: frame)) }
            return
        default:
            if String(describing: type(of: view)) == "_FocusRingView" {
                rings.append(Target(view: view, kind: .click, frame: frame))
            }
        }
        for subview in view.subviews { collect(subview, into: &targets, rings: &rings) }
    }

    private static func firstVisible(_ targets: [Target], in window: NSWindow) -> Target? {
        let page = window.contentLayoutRect
        let visible = targets.filter { page.intersects($0.frame) && isOnScreen($0.view) }
        return (visible.isEmpty ? targets : visible).min { lhs, rhs in
            abs(lhs.frame.maxY - rhs.frame.maxY) > 4 ? lhs.frame.maxY > rhs.frame.maxY : lhs.frame.minX < rhs.frame.minX
        }
    }

    private static func isOnScreen(_ view: NSView) -> Bool {
        guard let clip = view.enclosingScrollView?.contentView else { return true }
        return clip.convert(clip.bounds, to: nil).intersects(view.convert(view.bounds, to: nil))
    }

    /// Closest control in the pressed direction, favoring ones lined up with the current control.
    private static func nearest(to current: Target, dx: Int, dy: Int, among targets: [Target]) -> Target? {
        let from = current.frame
        var best: (target: Target, score: CGFloat)?
        for target in targets where target.view !== current.view {
            let to = target.frame
            let primary: CGFloat
            let offAxis: CGFloat
            if dy != 0 {
                // Window coordinates grow upward; D-pad down (dy = 1) means a smaller y.
                primary = dy > 0 ? from.midY - to.midY : to.midY - from.midY
                offAxis = max(0, max(to.minX - from.maxX, from.minX - to.maxX))
            } else {
                primary = dx > 0 ? to.midX - from.midX : from.midX - to.midX
                offAxis = max(0, max(to.minY - from.maxY, from.minY - to.maxY)) * 3
            }
            guard primary > 2 else { continue }
            let score = primary + offAxis * 2
            if best == nil || score < best!.score { best = (target, score) }
        }
        return best?.target
    }

    // MARK: - Highlight

    private func showHighlight() {
        guard let window, let focused else {
            leave()
            return
        }
        focused.scrollToVisible(focused.bounds.insetBy(dx: 0, dy: -40))
        if highlight == nil {
            highlight = HighlightWindow()
            observers = [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshHighlight() }
                }
            }
        }
        if let highlight, highlight.parent !== window {
            highlight.parent?.removeChildWindow(highlight)
            window.addChildWindow(highlight, ordered: .above)
        }
        refreshHighlight()
    }

    /// Re-aligns the outline with the focused control (after scrolling or layout) and hides it while the
    /// on-screen keyboard covers the page.
    func refreshHighlight() {
        guard let highlight else { return }
        guard let window, let focused, focused.window === window, !OnScreenKeyboard.shared.isPresented else {
            highlight.orderOut(nil)
            return
        }
        var rect = focused.convert(focused.bounds, to: nil).insetBy(dx: -4, dy: -4)
        if let clip = focused.enclosingScrollView?.contentView {
            rect = rect.intersection(clip.convert(clip.bounds, to: nil).insetBy(dx: -4, dy: -4))
        }
        guard !rect.isNull, rect.width > 8, rect.height > 8 else {
            highlight.orderOut(nil)
            return
        }
        highlight.setFrame(window.convertToScreen(rect), display: true)
        if !highlight.isVisible { window.addChildWindow(highlight, ordered: .above) }
    }
}

/// Borderless, click-through outline window around whatever the controller is on: over GBear's main window
/// (views added to the SwiftUI hosting view aren't reliably drawn) or over another app's dialog.
final class HighlightWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        let outline = NSView()
        outline.wantsLayer = true
        outline.layer?.borderWidth = 3
        outline.layer?.cornerRadius = 7
        outline.layer?.borderColor = NSColor.controlAccentColor.cgColor
        contentView = outline
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

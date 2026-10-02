import AppKit
import GameController
import Observation
import QuartzCore

/// Lets a game controller drive the Library while GBear is the frontmost app.
/// Reads controller state on a timer instead of installing handlers, so the streaming code's
/// `valueChangedHandler`s are never replaced.
@MainActor
@Observable
final class LibraryControllerNavigator {
    static let shared = LibraryControllerNavigator()

    enum Command: Equatable {
        case move(dx: Int, dy: Int)
        case confirm
        case back
        case toggleInfo
        case play
        /// Square / Circle: one cover-size slider step smaller (-1) or larger (+1).
        case coverSize(step: Int)
        /// L3: collapses / expands the library sidebar, or shrinks the on-screen keyboard while it's up.
        case leftStickClick
        /// R3: grows the on-screen keyboard while it's up.
        case rightStickClick
        case previousGame
        case nextGame
        case previousArea
        case nextArea
        /// An arrow key pressed against the edge of the current area: move to the area on that side.
        case leaveArea(dx: Int, dy: Int)
    }

    /// The part of the window the D-pad and A button act on. L2 / R2 cycle through them.
    enum Area: Equatable {
        case sidebar
        case covers
        case info
        case toolbar
        /// Emulators / Paths / Streaming tab content, driven by `ControllerPageNavigator`.
        case page
        /// The cover size slider under the grid (reached with the down arrow from the last row).
        case coverSize
    }

    private(set) var command: Command?
    /// Bumped on every command so views can react to repeats of the same command.
    private(set) var commandID = 0
    /// The current command came from the keyboard's arrow / Return keys. Arrows step out of an area at its
    /// edges (`leaveArea`); the controller uses L2 / R2 for that instead, so held D-pad repeats stay put.
    private(set) var commandFromKeyboard = false
    var area: Area = .covers {
        didSet {
            // Let go of the sidebar list's keyboard focus so it doesn't also act on arrow keys.
            if area != .sidebar, let window = NSApp.mainWindow, window.firstResponder is NSTableView {
                window.makeFirstResponder(nil)
            }
        }
    }

    private enum Input: CaseIterable {
        case up, down, left, right, a, b, x, y, select, start, l1, r1, l2, r2, l3, r3

        var repeats: Bool { [.up, .down, .left, .right, .l1, .r1, .x, .b].contains(self) }

        /// Face buttons by position (Xbox letters): A / Cross bottom, B / Circle right, X / Square left, Y / Triangle top.
        var command: Command {
            switch self {
            case .up: return .move(dx: 0, dy: -1)
            case .down: return .move(dx: 0, dy: 1)
            case .left: return .move(dx: -1, dy: 0)
            case .right: return .move(dx: 1, dy: 0)
            case .a: return .confirm
            case .x: return .coverSize(step: -1)
            case .b: return .coverSize(step: 1)
            case .y: return .back
            case .select: return .toggleInfo
            case .start: return .play
            case .l1: return .previousGame
            case .r1: return .nextGame
            case .l2: return .previousArea
            case .r2: return .nextArea
            case .l3: return .leftStickClick
            case .r3: return .rightStickClick
            }
        }
    }

    private static let repeatDelay: CFTimeInterval = 0.4
    private static let repeatInterval: CFTimeInterval = 0.12
    private static let stickThreshold: Float = 0.5
    private static let rightStickDeadZone: Float = 0.15
    /// Points per second with the right stick fully tilted.
    private static let keyboardMoveSpeed: CGFloat = 1100
    private static let quitComboHold: CFTimeInterval = 5
    private static let sleepComboHold: CFTimeInterval = 5

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var heldSince: [Input: CFTimeInterval] = [:]
    @ObservationIgnored private var lastFired: [Input: CFTimeInterval] = [:]
    /// After GBear comes back to the front, wait for every button to be let go, so a press meant for a game
    /// (or the one that switched apps) doesn't also act in GBear.
    @ObservationIgnored private var waitingForRelease = true
    @ObservationIgnored private var lastLoggedState: String?
    @ObservationIgnored private var lastPoll: CFTimeInterval?
    @ObservationIgnored private var quitComboSince: CFTimeInterval?
    @ObservationIgnored private var quitComboFired = false
    @ObservationIgnored private var fullScreenComboDown = false
    @ObservationIgnored private var sleepComboSince: CFTimeInterval?
    @ObservationIgnored private var sleepComboFired = false
    @ObservationIgnored private var systemComboSince: [SystemCombo: CFTimeInterval] = [:]
    @ObservationIgnored private var systemComboLastFired: [SystemCombo: CFTimeInterval] = [:]
    @ObservationIgnored private var loggedMissingAccessibility = false
    /// Select is also the modifier for volume / brightness, so in GBear it opens Info on release, and only if
    /// no shoulder button was pressed with it.
    @ObservationIgnored private var selectDown = false
    @ObservationIgnored private var selectUsedAsModifier = false
    /// Start + R2 is the sleep combo, so in GBear Start plays on release, and only if R2 wasn't pressed with it.
    @ObservationIgnored private var startDown = false
    @ObservationIgnored private var startUsedAsModifier = false
    /// Shoulder buttons pressed with Select; ignored until let go, so they don't also switch games or areas.
    @ObservationIgnored private var suppressedUntilRelease: Set<Input> = []
    @ObservationIgnored private var drivingFilePanel = false
    /// The app Select + Start last asked to quit; holding the combo again while it's still running force quits it.
    @ObservationIgnored private weak var quitRequestedApp: NSRunningApplication?
    @ObservationIgnored private var quitDialogPressed: Set<Input> = []
    @ObservationIgnored private var quitDialogWasActive = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated { LibraryControllerNavigator.shared.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { LibraryControllerNavigator.shared.handleKey(event) } ? nil : event
        }
        // Needed for the Select + Start / Start + R1 combos while a game is in front.
        GCController.shouldMonitorBackgroundEvents = true
        DebugLog.log("Controller navigation started")
    }

    /// Only the frontmost GBear main window with no sheet or modal, and never while this Mac is hosting or
    /// joining a stream. Streaming turns on background controller events for the whole app, so this check
    /// is what keeps a game in another app from also moving around GBear. The host seats this Mac as local
    /// co-op player 1 even when idle, so `GBearHostLocalGamepad.isActive` alone doesn't mean a game is running.
    private var blockedReason: String? {
        if let reason = appBlockedReason { return reason }
        if NSApp.modalWindow != nil { return "a modal window is open" }
        guard let main = NSApp.mainWindow else { return "no main window" }
        if NSApp.keyWindow !== main { return "the main window is not key" }
        // Open / save panels from `begin` aren't modal and can become main.
        if main is NSPanel || NSApp.windows.contains(where: { $0.isVisible && $0 is NSSavePanel }) {
            return "a panel is open"
        }
        if main.attachedSheet != nil { return "a sheet is open" }
        return nil
    }

    /// Reasons to leave GBear alone entirely, including its open / save panels.
    private var appBlockedReason: String? {
        if !NSApp.isActive { return "GBear is not the active app" }
        if GBearStreamHostManager.shared.isVideoStreaming { return "this Mac is streaming a game" }
        switch GBearStreamGuestManager.shared.phase {
        case .connected, .streaming: return "a guest stream owns the controllers"
        default: return nil
        }
    }

    /// An open / save panel (from `begin`, `runModal` or as a sheet) is key: the controller types its
    /// keyboard shortcuts instead of driving the main window (`pressPanelKey`).
    private var drivesFilePanel: Bool {
        appBlockedReason == nil && NSApp.keyWindow is NSSavePanel
    }

    private func poll() {
        checkGameCombos(now: CACurrentMediaTime())
        checkQuitDialog(now: CACurrentMediaTime())
        checkSystemCombos(now: CACurrentMediaTime())
        checkSleepCombo(now: CACurrentMediaTime())
        let filePanel = drivesFilePanel
        let reason = filePanel ? nil : blockedReason
        let state = filePanel ? "active (file panel)"
            : reason.map { "blocked: \($0)" } ?? "active (\(GCController.controllers().count) controller(s))"
        if state != lastLoggedState {
            lastLoggedState = state
            DebugLog.log("Controller navigation \(state)")
        }
        if filePanel != drivingFilePanel {
            drivingFilePanel = filePanel
            waitingForRelease = true
        }
        guard reason == nil else {
            heldSince.removeAll()
            lastFired.removeAll()
            suppressedUntilRelease.removeAll()
            selectDown = false
            startDown = false
            waitingForRelease = true
            return
        }
        let now = CACurrentMediaTime()
        let elapsed = min(now - (lastPoll ?? now), 0.05)
        lastPoll = now
        let pressed = currentlyPressed()
        if waitingForRelease {
            if pressed.isEmpty { waitingForRelease = false }
            return
        }
        if OnScreenKeyboard.shared.isPresented, !filePanel { moveKeyboardWithRightStick(elapsed: elapsed) }
        let selectHeld = pressed.contains(.select)
        if selectHeld {
            if !selectDown { selectUsedAsModifier = false }
            for shoulder in [Input.l1, .r1, .l2, .r2] where pressed.contains(shoulder) {
                suppressedUntilRelease.insert(shoulder)
                selectUsedAsModifier = true
            }
        } else if selectDown, !selectUsedAsModifier {
            fire(Input.select.command)
        }
        selectDown = selectHeld
        let startHeld = pressed.contains(.start)
        if startHeld {
            if !startDown { startUsedAsModifier = false }
            if pressed.contains(.r2) {
                suppressedUntilRelease.insert(.r2)
                startUsedAsModifier = true
            }
        } else if startDown, !startUsedAsModifier {
            fire(Input.start.command)
        }
        startDown = startHeld
        for input in Input.allCases {
            if input == .select || input == .start || suppressedUntilRelease.contains(input) {
                if !pressed.contains(input) { suppressedUntilRelease.remove(input) }
                continue
            }
            guard pressed.contains(input) else {
                heldSince[input] = nil
                lastFired[input] = nil
                continue
            }
            if let since = heldSince[input] {
                guard input.repeats, now - since >= Self.repeatDelay,
                      now - (lastFired[input] ?? since) >= Self.repeatInterval else { continue }
            } else {
                heldSince[input] = now
            }
            lastFired[input] = now
            fire(input.command)
        }
    }

    /// Shortcuts for the game in front (never while GBear is in front, where Start and R1 have their own jobs):
    /// Select + Start held for 5 s quits it with ⌘Q, so a game can be left from the couch (fires once per hold;
    /// GBear itself is never quit this way). Start + R1 toggles full screen with ⌃⌘F, once per press.
    private func checkGameCombos(now: CFTimeInterval) {
        var quitHeld = false
        var fullScreenHeld = false
        if !NSApp.isActive {
            for controller in GCController.controllers() {
                guard let pad = controller.extendedGamepad else { continue }
                let select = pad.buttonOptions
                if let select, select.preferredSystemGestureState != .disabled { select.preferredSystemGestureState = .disabled }
                guard pad.buttonMenu.isPressed else { continue }
                if select?.isPressed == true { quitHeld = true }
                if pad.rightShoulder.isPressed { fullScreenHeld = true }
            }
        }

        if fullScreenHeld, !fullScreenComboDown, let app = Self.otherFrontmostApp {
            DebugLog.log("Controller Start + R1: sending ⌃⌘F to \(Self.name(of: app))")
            if !Self.typeShortcut(key: 0x03, modifiers: [(0x3B, .maskControl), (0x37, .maskCommand)]) {
                DebugLog.log("Controller Start + R1: needs Accessibility permission to type ⌃⌘F")
            }
        }
        fullScreenComboDown = fullScreenHeld

        guard quitHeld else {
            quitComboSince = nil
            quitComboFired = false
            return
        }
        let since = quitComboSince ?? now
        quitComboSince = since
        guard !quitComboFired, now - since >= Self.quitComboHold else { return }
        quitComboFired = true
        quitFrontmostApp()
    }


    /// While the app Select + Start asked to quit shows a confirmation dialog: D-pad moves between its buttons,
    /// Cross presses the outlined one, Circle / Triangle cancel. Buttons held when the dialog appears (the
    /// combo itself) don't count until pressed again.
    private func checkQuitDialog(now: CFTimeInterval) {
        let dialog = ControllerDialogNavigator.shared
        dialog.update(now: now)
        let active = dialog.isActive && !NSApp.isActive
        let pressed = active ? currentlyPressed() : []
        defer {
            quitDialogPressed = pressed
            quitDialogWasActive = active
        }
        guard active, quitDialogWasActive, !pressed.contains(.select), !pressed.contains(.start) else { return }
        for input in pressed.subtracting(quitDialogPressed) {
            switch input {
            case .left, .up: dialog.move(by: -1)
            case .right, .down: dialog.move(by: 1)
            case .a: dialog.pressFocused()
            case .b, .y: dialog.cancel()
            default: break
            }
        }
    }

    private enum SystemCombo: CaseIterable {
        case volumeDown, volumeUp, brightnessDown, brightnessUp

        /// `NX_KEYTYPE_*` media key codes.
        var mediaKey: Int32 {
            switch self {
            case .volumeUp: 0
            case .volumeDown: 1
            case .brightnessUp: 2
            case .brightnessDown: 3
            }
        }
    }

    /// Select + L1 / R1 lower / raise the volume and Select + L2 / R2 the screen brightness, in GBear or in a
    /// game, repeating while held. Sent as the Mac's own media keys, so macOS shows its usual volume /
    /// brightness indicator and uses whatever output is current.
    private func checkSystemCombos(now: CFTimeInterval) {
        var held = Set<SystemCombo>()
        for controller in GCController.controllers() {
            guard let pad = controller.extendedGamepad, pad.buttonOptions?.isPressed == true else { continue }
            if pad.leftShoulder.isPressed { held.insert(.volumeDown) }
            if pad.rightShoulder.isPressed { held.insert(.volumeUp) }
            if pad.leftTrigger.isPressed { held.insert(.brightnessDown) }
            if pad.rightTrigger.isPressed { held.insert(.brightnessUp) }
        }
        for combo in SystemCombo.allCases {
            guard held.contains(combo) else {
                systemComboSince[combo] = nil
                systemComboLastFired[combo] = nil
                continue
            }
            if let since = systemComboSince[combo] {
                guard now - since >= Self.repeatDelay,
                      now - (systemComboLastFired[combo] ?? since) >= Self.repeatInterval else { continue }
            } else {
                systemComboSince[combo] = now
            }
            systemComboLastFired[combo] = now
            if !Self.pressMediaKey(combo.mediaKey), !loggedMissingAccessibility {
                loggedMissingAccessibility = true
                DebugLog.log("Controller volume / brightness: needs Accessibility permission to press media keys")
            }
        }
    }

    /// Start + R2 held for 5 s puts the Mac to sleep, in GBear or in a game (once per hold). `pmset sleepnow`
    /// needs no Accessibility permission or admin rights.
    private func checkSleepCombo(now: CFTimeInterval) {
        let held = GCController.controllers().contains { controller in
            guard let pad = controller.extendedGamepad else { return false }
            return pad.buttonMenu.isPressed && pad.rightTrigger.isPressed
        }
        guard held else {
            sleepComboSince = nil
            sleepComboFired = false
            return
        }
        let since = sleepComboSince ?? now
        sleepComboSince = since
        guard !sleepComboFired, now - since >= Self.sleepComboHold else { return }
        sleepComboFired = true
        DebugLog.log("Controller Start + R2: putting the Mac to sleep")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        do {
            try process.run()
        } catch {
            DebugLog.log("Controller Start + R2: pmset sleepnow failed: \(error.localizedDescription)")
        }
    }

    /// Posts a media key press (the system-defined event the keyboard's volume / brightness keys send).
    private static func pressMediaKey(_ key: Int32) -> Bool {
        guard AccessibilityPermission.isGranted else { return false }
        for down in [true, false] {
            let state = down ? 0xA00 : 0xB00
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int(key) << 16 | state,
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
        return true
    }


    private static var otherFrontmostApp: NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }

    private static func name(of app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
    }

    /// Types a shortcut into the frontmost app as real key presses (modifiers down, key, modifiers up).
    /// Returns false without Accessibility permission, which macOS requires for posting key events.
    private static func typeShortcut(key: CGKeyCode, modifiers: [(key: CGKeyCode, flag: CGEventFlags)]) -> Bool {
        guard AccessibilityPermission.isGranted, let source = CGEventSource(stateID: .hidSystemState) else { return false }
        func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        var flags: CGEventFlags = []
        for modifier in modifiers {
            flags.insert(modifier.flag)
            post(modifier.key, down: true, flags: flags)
        }
        post(key, down: true, flags: flags)
        post(key, down: false, flags: flags)
        for modifier in modifiers.reversed() {
            flags.remove(modifier.flag)
            post(modifier.key, down: false, flags: flags)
        }
        return true
    }

    private func quitFrontmostApp() {
        guard let app = Self.otherFrontmostApp else { return }
        if let asked = quitRequestedApp, asked.processIdentifier == app.processIdentifier, !asked.isTerminated {
            // Second hold on an app that didn't quit (a dialog the controller can't reach, or it ignored ⌘Q).
            DebugLog.log("Controller Select + Start: force quitting \(Self.name(of: app))")
            app.forceTerminate()
        } else if Self.typeShortcut(key: 0x0C, modifiers: [(0x37, .maskCommand)]) {
            DebugLog.log("Controller Select + Start: sent ⌘Q to \(Self.name(of: app))")
            ControllerDialogNavigator.shared.watch(app)
        } else {
            // Without Accessibility GBear can't type ⌘Q; the quit request does the same thing for the app.
            DebugLog.log("Controller Select + Start: asking \(Self.name(of: app)) to quit (no Accessibility permission)")
            app.terminate()
        }
        quitRequestedApp = app
        Task { @MainActor in
            // Long enough to answer an "Are you sure?" dialog before GBear stops waiting to come back.
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(250))
                guard app.isTerminated else { continue }
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }
    }

    /// Buttons by position, for showing the connected controller's own glyphs (△ on PlayStation, Y on Xbox).
    enum ControllerButton {
        case bottom, right, left, top, l1, r1, l2, r2
    }

    func buttonSymbol(_ button: ControllerButton) -> String {
        let pad = (GCController.current ?? GCController.controllers().first)?.extendedGamepad
        let element: GCControllerElement? = switch button {
        case .bottom: pad?.buttonA
        case .right: pad?.buttonB
        case .left: pad?.buttonX
        case .top: pad?.buttonY
        case .l1: pad?.leftShoulder
        case .r1: pad?.rightShoulder
        case .l2: pad?.leftTrigger
        case .r2: pad?.rightTrigger
        }
        if let name = element?.sfSymbolsName { return name }
        switch button {
        case .bottom: return "a.circle"
        case .right: return "b.circle"
        case .left: return "x.circle"
        case .top: return "y.circle"
        case .l1: return "l1.rectangle.roundedbottom"
        case .r1: return "r1.rectangle.roundedbottom"
        case .l2: return "l2.rectangle.roundedtop"
        case .r2: return "r2.rectangle.roundedtop"
        }
    }

    /// Right stick slides the on-screen keyboard; squared response so small tilts allow fine placement.
    private func moveKeyboardWithRightStick(elapsed: CFTimeInterval) {
        var x: Float = 0
        var y: Float = 0
        for controller in GCController.controllers() {
            guard let stick = controller.extendedGamepad?.rightThumbstick else { continue }
            if abs(stick.xAxis.value) > abs(x) { x = stick.xAxis.value }
            if abs(stick.yAxis.value) > abs(y) { y = stick.yAxis.value }
        }
        func curve(_ value: Float) -> CGFloat {
            guard abs(value) > Self.rightStickDeadZone else { return 0 }
            let scaled = (abs(value) - Self.rightStickDeadZone) / (1 - Self.rightStickDeadZone)
            return CGFloat(scaled * scaled) * (value < 0 ? -1 : 1)
        }
        let distance = Self.keyboardMoveSpeed * CGFloat(elapsed)
        let delta = CGSize(width: curve(x) * distance, height: -curve(y) * distance)
        guard delta != .zero else { return }
        OnScreenKeyboard.shared.move(by: delta)
    }




    /// Key codes (`kVK_*`) the file panel understands.
    private enum PanelKey {
        static let left: CGKeyCode = 0x7B, right: CGKeyCode = 0x7C, down: CGKeyCode = 0x7D, up: CGKeyCode = 0x7E
        static let returnKey: CGKeyCode = 0x24, escape: CGKeyCode = 0x35, tab: CGKeyCode = 0x30
        static let leftBracket: CGKeyCode = 0x21, rightBracket: CGKeyCode = 0x1E, h: CGKeyCode = 0x04
    }

    /// Open / save panels: D-pad = arrow keys, A = open the selected folder (⌘↓), Back = enclosing folder
    /// (⌘↑), Start = the panel's Open / Choose button (Return), Circle / B = Cancel (Esc), L1 / R1 = back /
    /// forward (⌘[ / ⌘]), L2 / R2 = move between the sidebar and the file list (⇧Tab / Tab), L3 = home folder.
    private func handleFilePanel(_ command: Command) {
        switch command {
        case .move(let dx, let dy):
            pressPanelKey(dy < 0 ? PanelKey.up : dy > 0 ? PanelKey.down : dx < 0 ? PanelKey.left : PanelKey.right)
        case .confirm: pressPanelKey(PanelKey.down, flags: .maskCommand)
        case .back: pressPanelKey(PanelKey.up, flags: .maskCommand)
        case .play: pressPanelKey(PanelKey.returnKey)
        case .coverSize(let step) where step > 0: pressPanelKey(PanelKey.escape)
        case .previousGame: pressPanelKey(PanelKey.leftBracket, flags: .maskCommand)
        case .nextGame: pressPanelKey(PanelKey.rightBracket, flags: .maskCommand)
        case .previousArea: pressPanelKey(PanelKey.tab, flags: .maskShift)
        case .nextArea: pressPanelKey(PanelKey.tab)
        case .leftStickClick: pressPanelKey(PanelKey.h, flags: [.maskCommand, .maskShift])
        default: break
        }
    }

    /// Sends a key press to the key panel. With Accessibility it goes through the HID tap like a real
    /// keyboard; without it the event is queued in GBear itself, which works because the panel is in-process.
    private func pressPanelKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = (0x7B...0x7E).contains(key) ? flags.union([.maskNumericPad, .maskSecondaryFn]) : flags
            if AccessibilityPermission.isGranted {
                event.post(tap: .cghidEventTap)
            } else if let nsEvent = NSEvent(cgEvent: event) {
                NSApp.postEvent(nsEvent, atStart: false)
            }
        }
    }

    /// Arrow keys and Return drive GBear like the D-pad and A, unless a modifier is held or anything that blocks
    /// the controller is up. Returns true when the key was used.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard blockedReason == nil, !OnScreenKeyboard.shared.isPresented,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        let responder = NSApp.keyWindow?.firstResponder
        let isUp = event.keyCode == 0x7E
        let isDown = event.keyCode == 0x7D
        let isReturn = event.keyCode == 0x24 || event.keyCode == 0x4C
        if let text = responder as? NSText {
            // Typing in a single-line field: up / down leave it and carry on navigating; in the toolbar search
            // field Return does too (the results already filter as you type). Everything else is for the field.
            guard let editor = text as? NSTextView, editor.isFieldEditor else { return false }
            if let window = NSApp.mainWindow, let toolbarSearch = Self.toolbarSearchField(in: window),
               editor.delegate === toolbarSearch {
                guard isUp || isDown || isReturn else { return false }
                NSApp.keyWindow?.makeFirstResponder(nil)
                area = .toolbar
                if !isUp { fire(.leaveArea(dx: 0, dy: 1), fromKeyboard: true) }
                return true
            }
            guard isUp || isDown else { return false }
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        let command: Command
        switch event.keyCode {
        case 0x7B: command = .move(dx: -1, dy: 0)
        case 0x7C: command = .move(dx: 1, dy: 0)
        case _ where isDown: command = .move(dx: 0, dy: 1)
        case _ where isUp: command = .move(dx: 0, dy: -1)
        case _ where isReturn: command = .confirm
        default: return false
        }
        // The sidebar list only holds keyboard focus after a click (areas resign it on the way out), so a
        // click there means the arrows should start in the sidebar.
        if let table = responder as? NSTableView, Self.isSidebar(table), area != .sidebar {
            area = .sidebar
        }
        fire(command, fromKeyboard: true)
        return true
    }

    /// The `.searchable(placement: .toolbar)` field. SwiftUI may host it in an `NSSearchToolbarItem` or as a plain
    /// `NSSearchField` inside a toolbar item's view, so the title bar's views are searched too (the window's
    /// content is skipped, where tabs have search fields of their own).
    static func toolbarSearchField(in window: NSWindow) -> NSSearchField? {
        for item in window.toolbar?.items ?? [] {
            if let search = item as? NSSearchToolbarItem { return search.searchField }
            if let view = item.view, let field = firstSearchField(in: view) { return field }
        }
        guard let frame = window.contentView?.superview else { return nil }
        for subview in frame.subviews where subview !== window.contentView {
            if let field = firstSearchField(in: subview) { return field }
        }
        return nil
    }

    private static func firstSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews {
            if let field = firstSearchField(in: subview) { return field }
        }
        return nil
    }

    /// The Library's sidebar list: the first pane of its split view. (The Info column's grouped Form and other
    /// tabs' lists can be tables too.)
    private static func isSidebar(_ table: NSTableView) -> Bool {
        var view: NSView = table
        while let parent = view.superview {
            if let split = parent as? NSSplitView { return split.subviews.first === view }
            view = parent
        }
        return false
    }

    /// Called by an area's handler when a keyboard arrow can't move any further inside it.
    func leaveArea(dx: Int, dy: Int) {
        fire(.leaveArea(dx: dx, dy: dy), fromKeyboard: true)
    }

    private func fire(_ command: Command, fromKeyboard: Bool = false) {
        commandFromKeyboard = fromKeyboard
        if drivingFilePanel {
            handleFilePanel(command)
            return
        }
        if OnScreenKeyboard.shared.isPresented {
            OnScreenKeyboard.shared.handle(command)
            return
        }
        self.command = command
        commandID &+= 1
    }

    private func currentlyPressed() -> Set<Input> {
        var pressed = Set<Input>()
        for controller in GCController.controllers() {
            if let pad = controller.extendedGamepad {
                let stick = pad.leftThumbstick
                if pad.dpad.up.isPressed || stick.yAxis.value > Self.stickThreshold { pressed.insert(.up) }
                if pad.dpad.down.isPressed || stick.yAxis.value < -Self.stickThreshold { pressed.insert(.down) }
                if pad.dpad.left.isPressed || stick.xAxis.value < -Self.stickThreshold { pressed.insert(.left) }
                if pad.dpad.right.isPressed || stick.xAxis.value > Self.stickThreshold { pressed.insert(.right) }
                if pad.buttonA.isPressed { pressed.insert(.a) }
                if pad.buttonB.isPressed { pressed.insert(.b) }
                if pad.buttonX.isPressed { pressed.insert(.x) }
                if pad.buttonY.isPressed { pressed.insert(.y) }
                if pad.buttonMenu.isPressed { pressed.insert(.start) }
                if let select = pad.buttonOptions {
                    // Otherwise macOS may treat Share / Create as its screenshot button while GBear is in front.
                    if select.preferredSystemGestureState != .disabled { select.preferredSystemGestureState = .disabled }
                    if select.isPressed { pressed.insert(.select) }
                }
                if pad.leftShoulder.isPressed { pressed.insert(.l1) }
                if pad.rightShoulder.isPressed { pressed.insert(.r1) }
                if pad.leftTrigger.isPressed { pressed.insert(.l2) }
                if pad.rightTrigger.isPressed { pressed.insert(.r2) }
                if pad.leftThumbstickButton?.isPressed == true { pressed.insert(.l3) }
                if pad.rightThumbstickButton?.isPressed == true { pressed.insert(.r3) }
            } else if let pad = controller.microGamepad {
                if pad.dpad.up.isPressed { pressed.insert(.up) }
                if pad.dpad.down.isPressed { pressed.insert(.down) }
                if pad.dpad.left.isPressed { pressed.insert(.left) }
                if pad.dpad.right.isPressed { pressed.insert(.right) }
                if pad.buttonA.isPressed { pressed.insert(.a) }
                if pad.buttonX.isPressed { pressed.insert(.y) }
                if pad.buttonMenu.isPressed { pressed.insert(.start) }
            }
        }
        return pressed
    }
}

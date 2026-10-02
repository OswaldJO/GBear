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
    }

    /// The part of the window the D-pad and A button act on. L2 / R2 cycle through them.
    enum Area: Equatable {
        case sidebar
        case covers
        case info
        case toolbar
        /// Emulators / Paths / Streaming tab content, driven by `ControllerPageNavigator`.
        case page
    }

    private(set) var command: Command?
    /// Bumped on every command so views can react to repeats of the same command.
    private(set) var commandID = 0
    var area: Area = .covers

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

    @ObservationIgnored private var timer: Timer?
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
    @ObservationIgnored private var systemComboSince: [SystemCombo: CFTimeInterval] = [:]
    @ObservationIgnored private var systemComboLastFired: [SystemCombo: CFTimeInterval] = [:]
    @ObservationIgnored private var loggedMissingAccessibility = false
    /// Select is also the modifier for volume / brightness, so in GBear it opens Info on release, and only if
    /// no shoulder button was pressed with it.
    @ObservationIgnored private var selectDown = false
    @ObservationIgnored private var selectUsedAsModifier = false
    /// Shoulder buttons pressed with Select; ignored until let go, so they don't also switch games or areas.
    @ObservationIgnored private var suppressedUntilRelease: Set<Input> = []

    private init() {}

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated { LibraryControllerNavigator.shared.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Needed for the Select + Start / Start + R1 combos while a game is in front.
        GCController.shouldMonitorBackgroundEvents = true
        DebugLog.log("Controller navigation started")
    }

    /// Only the frontmost GBear main window with no sheet or modal, and never while this Mac is hosting or
    /// joining a stream. Streaming turns on background controller events for the whole app, so this check
    /// is what keeps a game in another app from also moving around GBear. The host seats this Mac as local
    /// co-op player 1 even when idle, so `GBearHostLocalGamepad.isActive` alone doesn't mean a game is running.
    private var blockedReason: String? {
        if !NSApp.isActive { return "GBear is not the active app" }
        if NSApp.modalWindow != nil { return "a modal window is open" }
        guard let main = NSApp.mainWindow else { return "no main window" }
        if NSApp.keyWindow !== main { return "the main window is not key" }
        // Open / save panels from `begin` aren't modal and can become main.
        if main is NSPanel || NSApp.windows.contains(where: { $0.isVisible && $0 is NSSavePanel }) {
            return "a panel is open"
        }
        if main.attachedSheet != nil { return "a sheet is open" }
        if GBearStreamHostManager.shared.isVideoStreaming { return "this Mac is streaming a game" }
        switch GBearStreamGuestManager.shared.phase {
        case .connected, .streaming: return "a guest stream owns the controllers"
        default: return nil
        }
    }

    private func poll() {
        checkGameCombos(now: CACurrentMediaTime())
        checkSystemCombos(now: CACurrentMediaTime())
        let reason = blockedReason
        let state = reason.map { "blocked: \($0)" } ?? "active (\(GCController.controllers().count) controller(s))"
        if state != lastLoggedState {
            lastLoggedState = state
            DebugLog.log("Controller navigation \(state)")
        }
        guard reason == nil else {
            heldSince.removeAll()
            lastFired.removeAll()
            suppressedUntilRelease.removeAll()
            selectDown = false
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
        if OnScreenKeyboard.shared.isPresented { moveKeyboardWithRightStick(elapsed: elapsed) }
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
        for input in Input.allCases {
            if input == .select || suppressedUntilRelease.contains(input) {
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
        if Self.typeShortcut(key: 0x0C, modifiers: [(0x37, .maskCommand)]) {
            DebugLog.log("Controller Select + Start: sent ⌘Q to \(Self.name(of: app))")
        } else {
            // Without Accessibility GBear can't type ⌘Q; the quit request does the same thing for the app.
            DebugLog.log("Controller Select + Start: asking \(Self.name(of: app)) to quit (no Accessibility permission)")
            app.terminate()
        }
        Task { @MainActor in
            for _ in 0..<40 {
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




    private func fire(_ command: Command) {
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

import AppKit
import Foundation

enum GameLaunchError: LocalizedError {
    case missingEmulator
    case missingRom
    case invalidExecutable
    case unsupportedStandaloneTarget

    var errorDescription: String? {
        switch self {
        case .missingEmulator: return "No emulator is assigned to this game."
        case .missingRom: return "The game file could not be found."
        case .invalidExecutable: return "The emulator path is not valid."
        case .unsupportedStandaloneTarget: return "The selected Mac game path could not be launched."
        }
    }
}

/// Launches a ROM using the emulator’s argument template.
/// GBear uses **`{ImagePath}`** for the game/disc file in profiles ([cmdline arguments](https://github.com/JosefNemec/GBear/wiki/Cmdline-arguments)).
/// We accept `{ImagePath}` (same as GBear), `{rom}`, and `{ROM}` interchangeably.
/// `{user_name}` expands to the current macOS account short name; leading `~` in argv tokens is expanded.
@MainActor
enum GameLauncher {
    /// Running emulator PIDs we are currently tracking for auto-hide/restore.
    private static var trackedLaunchPIDs: Set<pid_t> = []
    /// Notification tokens retained while tracking launched emulator processes.
    private static var terminationObservers: [NSObjectProtocol] = []

    static func launch(game: LibraryGame) throws {
        DebugLog.log("Launch requested: title=\(game.title) romPath=\(game.romPath)")
        let romURL = URL(fileURLWithPath: game.romPath)
        let standardizedPath = (romURL.path as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: standardizedPath) else {
            DebugLog.log("Launch failed: missing ROM at \(standardizedPath)")
            throw GameLaunchError.missingRom
        }
        if game.emulator == nil && game.emulatorUUID == nil {
            if let epicAppName = game.epicAppName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !epicAppName.isEmpty {
                if launchViaEpicLauncher(appName: epicAppName) {
                    return
                }
            }
            try launchStandaloneTarget(at: URL(fileURLWithPath: standardizedPath))
            return
        }
        guard let emulator = game.emulator else {
            DebugLog.log("Launch failed: missing emulator")
            throw GameLaunchError.missingEmulator
        }

        let exe = URL(fileURLWithPath: emulator.executablePath)
        guard FileManager.default.fileExists(atPath: exe.path) else {
            DebugLog.log("Launch failed: missing emulator executable at \(exe.path)")
            throw GameLaunchError.invalidExecutable
        }

        let substituted = LaunchArgumentTemplate.expandPlaceholders(
            emulator.launchArgumentTemplate,
            gameFilePath: standardizedPath
        )
        let parts = parseArguments(substituted).map(LaunchArgumentTemplate.expandTildeInArgument)
        let appOrBinary = resolvedExecutableURL(exe)
        DebugLog.log("Resolved emulator=\(appOrBinary.path)")
        DebugLog.log("Launch template=\(emulator.launchArgumentTemplate)")
        DebugLog.log("Launch substituted=\(substituted)")
        DebugLog.log("Launch args=\(parts.joined(separator: " | "))")

        // When we have CLI args (game path + flags), always launch via argv.
        // Do NOT use Launch Services "open documents" for that case — ARMSX2/PCSX2-family
        // can SIGSEGV in MainWindow::startFile while the setup wizard / MainWindow is not ready.
        if !parts.isEmpty {
            try launchWithCLIArguments(appOrBinary: appOrBinary, arguments: parts)
            return
        }

        // No CLI template: for an already-running .app, ask it to open the game file.
        if appOrBinary.pathExtension.lowercased() == "app",
           let runningApp = runningApplication(forBundlePath: appOrBinary.path) {
            DebugLog.log("Emulator already running (pid=\(runningApp.processIdentifier)); using open document event")
            registerLaunchedApplication(runningApp)
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([URL(fileURLWithPath: standardizedPath)], withApplicationAt: appOrBinary, configuration: config) { _, error in
                if let error {
                    NSLog("Launch error: \(error.localizedDescription)")
                    DebugLog.log("Open document callback error: \(error.localizedDescription)")
                } else {
                    DebugLog.log("Open document callback succeeded")
                }
            }
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(
            at: appOrBinary,
            configuration: configuration
        ) { runningApp, error in
            Task { @MainActor in
                if let error {
                    NSLog("Launch error: \(error.localizedDescription)")
                    DebugLog.log("openApplication callback error: \(error.localizedDescription)")
                    return
                }
                guard let runningApp else {
                    DebugLog.log("openApplication callback returned nil app")
                    return
                }
                DebugLog.log("openApplication callback success pid=\(runningApp.processIdentifier)")
                registerLaunchedApplication(runningApp)
            }
        }
    }

    /// Launches with argv via `NSWorkspace.OpenConfiguration.arguments`.
    ///
    /// Requires a **non-sandboxed** GBear (App Sandbox makes the system ignore `arguments`, so the
    /// emulator opens to an empty game list). Also quits existing instances first — otherwise macOS
    /// may only activate the already-open window and drop argv.
    private static func launchWithCLIArguments(appOrBinary: URL, arguments: [String]) throws {
        if appOrBinary.pathExtension.lowercased() == "app" {
            terminateRunningInstances(ofAppAt: appOrBinary)

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = arguments
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            DebugLog.log(
                "NSWorkspace openApplication app=\(appOrBinary.path) args=\(arguments.joined(separator: " | "))"
            )

            NSWorkspace.shared.openApplication(at: appOrBinary, configuration: configuration) { runningApp, error in
                Task { @MainActor in
                    if let error {
                        NSLog("Launch error: \(error.localizedDescription)")
                        DebugLog.log("NSWorkspace openApplication error: \(error.localizedDescription)")
                        return
                    }
                    guard let runningApp else {
                        DebugLog.log("NSWorkspace openApplication returned nil app; polling…")
                        scheduleRegisterRunningApp(bundlePath: appOrBinary.path, attemptsRemaining: 20)
                        return
                    }
                    DebugLog.log(
                        "NSWorkspace openApplication success pid=\(runningApp.processIdentifier) argsExpected=\(arguments.count)"
                    )
                    registerLaunchedApplication(runningApp)
                }
            }
            return
        }

        guard FileManager.default.isExecutableFile(atPath: appOrBinary.path) else {
            DebugLog.log("Launch failed: executable missing at \(appOrBinary.path)")
            throw GameLaunchError.invalidExecutable
        }

        let process = Process()
        process.executableURL = appOrBinary
        process.arguments = arguments
        process.currentDirectoryURL = appOrBinary.deletingLastPathComponent()
        DebugLog.log("Process launch binary=\(appOrBinary.path) args=\(arguments.joined(separator: " | "))")

        do {
            try process.run()
        } catch {
            DebugLog.log("Process launch failed: \(error.localizedDescription)")
            throw GameLaunchError.invalidExecutable
        }

        if let running = NSRunningApplication(processIdentifier: process.processIdentifier) {
            DebugLog.log("Process launch success pid=\(process.processIdentifier)")
            registerLaunchedApplication(running)
        } else {
            DebugLog.log("Process started pid=\(process.processIdentifier) but NSRunningApplication lookup missed")
        }
    }

    /// Politely quits every running copy of this `.app` so the next `open --args` is not discarded.
    private static func terminateRunningInstances(ofAppAt appURL: URL) {
        let target = (appURL.path as NSString).standardizingPath
        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard let bundleURL = app.bundleURL else { return false }
            return (bundleURL.path as NSString).standardizingPath == target
        }
        guard !running.isEmpty else { return }

        DebugLog.log("Terminating \(running.count) existing instance(s) of \(appURL.lastPathComponent) before CLI launch")
        for app in running {
            trackedLaunchPIDs.remove(app.processIdentifier)
            app.terminate()
        }

        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            let stillThere = NSWorkspace.shared.runningApplications.contains { app in
                guard let bundleURL = app.bundleURL else { return false }
                return (bundleURL.path as NSString).standardizingPath == target
            }
            if !stillThere { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        // Last resort if the app ignores terminate (e.g. modal dialog).
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleURL = app.bundleURL else { continue }
            guard (bundleURL.path as NSString).standardizingPath == target else { continue }
            DebugLog.log("Force-terminating stubborn instance pid=\(app.processIdentifier)")
            app.forceTerminate()
        }
    }

    /// `open` returns before the target app is running; poll briefly then track it.
    private static func scheduleRegisterRunningApp(bundlePath: String, attemptsRemaining: Int) {
        guard attemptsRemaining > 0 else {
            DebugLog.log("Timed out waiting for app to appear: \(bundlePath)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let running = runningApplication(forBundlePath: bundlePath) {
                DebugLog.log("Registered launched app pid=\(running.processIdentifier) path=\(bundlePath)")
                registerLaunchedApplication(running)
                return
            }
            scheduleRegisterRunningApp(bundlePath: bundlePath, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private static func registerLaunchedApplication(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0 else { return }

        let inserted = trackedLaunchPIDs.insert(pid).inserted
        if inserted {
            DebugLog.log("Tracking launched app pid=\(pid); hiding launcher app")
            NSApp.hide(nil)
        }

        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let terminated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            guard terminated.processIdentifier == pid else { return }
            Task { @MainActor in
                unregisterLaunchedApplication(pid: pid)
            }
        }
        terminationObservers.append(observer)
    }

    private static func unregisterLaunchedApplication(pid: pid_t) {
        guard trackedLaunchPIDs.contains(pid) else { return }
        trackedLaunchPIDs.remove(pid)
        DebugLog.log("Launched app terminated pid=\(pid); remaining tracked=\(trackedLaunchPIDs.count)")

        if trackedLaunchPIDs.isEmpty {
            DebugLog.log("No tracked launches remaining; unhiding launcher app")
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Remove stale observers after each termination.
        let center = NSWorkspace.shared.notificationCenter
        terminationObservers.forEach { center.removeObserver($0) }
        terminationObservers.removeAll()

        // Re-register remaining tracked PIDs to keep monitoring if multiple launches overlap.
        for trackedPID in trackedLaunchPIDs {
            let observer = center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let terminated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                guard terminated.processIdentifier == trackedPID else { return }
                Task { @MainActor in
                    unregisterLaunchedApplication(pid: trackedPID)
                }
            }
            terminationObservers.append(observer)
        }
    }

    /// Splits like a minimal shell: spaces separate tokens; text inside `"` is one token (no quotes in argv).
    private static func parseArguments(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var result: [String] = []
        var current = ""
        var inDoubleQuotes = false

        for char in trimmed {
            if char == "\"" {
                if inDoubleQuotes {
                    result.append(current)
                    current = ""
                    inDoubleQuotes = false
                } else {
                    if !current.isEmpty {
                        result.append(current)
                        current = ""
                    }
                    inDoubleQuotes = true
                }
            } else if char.isWhitespace && !inDoubleQuotes {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func resolvedExecutableURL(_ url: URL) -> URL {
        if url.pathExtension.lowercased() == "app" {
            return url
        }
        return url
    }

    private static func runningApplication(forBundlePath bundlePath: String) -> NSRunningApplication? {
        let target = (bundlePath as NSString).standardizingPath
        return NSWorkspace.shared.runningApplications.first { app in
            guard let bundleURL = app.bundleURL else { return false }
            let runningPath = (bundleURL.path as NSString).standardizingPath
            return runningPath == target
        }
    }

    private static func launchStandaloneTarget(at url: URL) throws {
        let standardizedPath = (url.path as NSString).standardizingPath
        let standardizedURL = URL(fileURLWithPath: standardizedPath)
        DebugLog.log("Standalone launch target=\(standardizedPath)")

        if standardizedURL.pathExtension.lowercased() == "app" {
            NSWorkspace.shared.openApplication(
                at: standardizedURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { runningApp, error in
                Task { @MainActor in
                    if let error {
                        NSLog("Standalone launch error: \(error.localizedDescription)")
                        DebugLog.log("Standalone openApplication callback error: \(error.localizedDescription)")
                        return
                    }
                    guard let runningApp else {
                        DebugLog.log("Standalone openApplication callback returned nil app")
                        return
                    }
                    DebugLog.log("Standalone openApplication callback success pid=\(runningApp.processIdentifier)")
                    registerLaunchedApplication(runningApp)
                }
            }
            return
        }

        if NSWorkspace.shared.open(standardizedURL) {
            DebugLog.log("Standalone open succeeded via NSWorkspace.open")
            return
        }
        DebugLog.log("Standalone launch failed for path=\(standardizedPath)")
        throw GameLaunchError.unsupportedStandaloneTarget
    }

    private static func launchViaEpicLauncher(appName: String) -> Bool {
        let escaped = appName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? appName
        guard let launchURL = URL(string: "com.epicgames.launcher://apps/\(escaped)?action=launch&silent=true") else {
            return false
        }
        let didOpen = NSWorkspace.shared.open(launchURL)
        DebugLog.log("Epic launch uri appName=\(appName) opened=\(didOpen)")
        return didOpen
    }

}

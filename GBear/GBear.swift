import AppKit
import GBearKit
import SwiftData
import SwiftUI

@main
struct GBear: App {
    init() {
        DebugLog.log("App init")
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { _ in
            DebugLog.log("didFinishLaunching")
        }
        center.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            DebugLog.log("willTerminate")
            StreamingLifecycle.stopManagedHostOnQuit()
        }
    }

    var sharedModelContainer: ModelContainer = {
        DebugLog.log("Creating ModelContainer at \(PersistenceStoreLocation.storeFileURL.path)")
        let schema = Schema([
            EmulatorProfile.self,
            LibraryGame.self,
            GameFolderPath.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            url: PersistenceStoreLocation.storeFileURL,
            cloudKitDatabase: .none
        )
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            DebugLog.log("ModelContainer created")
            LaunchArgumentTemplate.migrateStoredHomePaths(container: container)
            return container
        } catch {
            DebugLog.log("ModelContainer creation failed: \(error.localizedDescription)")
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .help) {
                Button("RetroArch Launch Arguments") {
                    showHelpDialog(
                        title: "RetroArch Launch Arguments",
                        message: """
                        RetroArch cores on Mac are typically stored in:
                        ~/Library/Application Support/RetroArch/cores

                        To access this folder:
                        Open Finder, click Go in the menu bar, select Go to Folder, and paste:
                        ~/Library/Application Support/RetroArch/

                        Paths can differ between standard and Steam installs.

                        Example launch arguments:
                        -L "/Users/{user_name}/Library/Application Support/RetroArch/cores/mgba_libretro.dylib" --fullscreen "{ImagePath}"
                        """
                    )
                }

                Button("RPCS3 Game not launching") {
                    showHelpDialog(
                        title: "RPCS3 Game not launching",
                        message: """
                        Edge case:
                        If RPCS3 is already open, launching a different PS3 game from this library may not switch games reliably.

                        Workaround:
                        Close RPCS3 first, then launch the other PS3 game from the library.
                        """
                    )
                }

                Button("Missing Orphan Games") {
                    showHelpDialog(
                        title: "Missing Orphan Games",
                        message: """
                        Why this exists:
                        Library rows can go stale in two ways:
                        1) They still reference an emulator that was deleted.
                        2) They were imported from Paths, but the ROM/file is no longer on disk.

                        What the app does:
                        On startup, the app removes games whose emulator no longer exists (ghost entries in “All”).
                        On Scan Paths, the app also removes emulator-linked games under a reachable Paths folder when the file is gone. If an entire Paths folder/volume is offline (unmounted drive), those games are kept so a temporary disconnect does not wipe the library.

                        Result:
                        Library sections stay consistent with what’s actually on disk and configured.
                        """
                    )
                }

                Button("Keystrokes permission") {
                    showHelpDialog(
                        title: "Keystrokes permission",
                        message: """
                        Why macOS prompted this:
                        Some launcher/game components (for example overlays, anti-cheat, controller/input hooks, or launcher helpers) request Input Monitoring or Accessibility permissions to watch low-level input events.

                        Important:
                        This prompt is separate from account login. Being signed in to Epic does not always prevent it.

                        What you can do:
                        You can click Deny first and try launching the game anyway. Many games still run without this permission.

                        If the game fails after Deny:
                        That specific title/runtime likely requires elevated input access on macOS.
                        """
                    )
                }
            }
        }
    }

    private func showHelpDialog(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

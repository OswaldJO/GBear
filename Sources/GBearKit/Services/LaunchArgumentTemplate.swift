import Foundation
import SwiftData

/// Helpers for emulator launch-argument templates.
///
/// Supported placeholders:
/// - `{ImagePath}` / `{rom}` / `{ROM}` — game file path (GBear-compatible)
/// - `{user_name}` — current macOS account short name (`NSUserName()`), for paths like
///   `/Users/{user_name}/Library/Application Support/RetroArch/cores/...`
///
/// Leading `~` in an argument token is expanded with `expandingTildeInPath` at launch.
public enum LaunchArgumentTemplate {
    /// Older ARMSX2/PCSX2 templates that open the UI but skip a reliable boot, or gray-screen with -fullscreen.
    private static let legacyPCSX2Templates: Set<String> = [
        "-batch -fullscreen \"{ImagePath}\"",
        "-batch -fullscreen -- \"{ImagePath}\"",
        "-batch -fullscreen --",
        "-- before {ImagePath}",
        "-- before \"{ImagePath}\"",
    ]
    /// Prefer fast boot without forcing fullscreen/batch (batch+fullscreen often yielded a gray GS window).
    private static let preferredPCSX2Template = "-fastboot -- \"{ImagePath}\""

    /// Rewrites the current user's home directory to `/Users/{user_name}` so templates stay portable.
    /// Never embeds a fixed username — uses `NSHomeDirectory()` at runtime.
    public static func normalizeHomePaths(_ template: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty, template.contains(home) else { return template }
        return template.replacingOccurrences(of: home, with: "/Users/{user_name}")
    }

    /// Upgrades known-broken / gray-screen ARMSX2/PCSX2 templates to a reliable boot line.
    public static func normalizePCSX2StyleBootSeparator(_ template: String) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if legacyPCSX2Templates.contains(trimmed) {
            return preferredPCSX2Template
        }
        let lowered = trimmed.lowercased()
        if lowered.contains("-- before {imagepath}") {
            return preferredPCSX2Template
        }
        return template
    }

    /// Expands `{user_name}` and GBear path tokens. Call `expandTildeInArgument` on each argv token after parsing.
    public static func expandPlaceholders(_ template: String, gameFilePath: String) -> String {
        var text = template.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "{user_name}", with: NSUserName())
        text = text
            .replacingOccurrences(of: "{ImagePath}", with: "{rom}")
            .replacingOccurrences(of: "{ROM}", with: "{rom}")

        if text.isEmpty {
            return "\"\(gameFilePath)\""
        }

        guard text.contains("{rom}") else {
            return text
        }

        let userQuotedPlaceholder = text.contains("\"{rom}\"")
        let pathNeedsQuoting = gameFilePath.contains(where: \.isWhitespace)
        if pathNeedsQuoting && !userQuotedPlaceholder {
            return text.replacingOccurrences(of: "{rom}", with: "\"\(gameFilePath)\"")
        }
        return text.replacingOccurrences(of: "{rom}", with: gameFilePath)
    }

    public static func expandTildeInArgument(_ argument: String) -> String {
        guard argument.hasPrefix("~") else { return argument }
        return (argument as NSString).expandingTildeInPath
    }

    /// Rewrites home absolute paths and known ARMSX2/PCSX2 launch-arg fixes in stored profiles.
    @MainActor
    public static func migrateStoredHomePaths(container: ModelContainer) {
        let context = ModelContext(container)
        do {
            let profiles = try context.fetch(FetchDescriptor<EmulatorProfile>())
            var changed = false
            for profile in profiles {
                var next = normalizeHomePaths(profile.launchArgumentTemplate)
                next = normalizePCSX2StyleBootSeparator(next)

                // Prefer ARMSX2 over retired AetherSX2 when the new app is installed.
                let exe = profile.executablePath
                if exe.localizedCaseInsensitiveContains("AetherSX2"),
                   FileManager.default.fileExists(atPath: "/Applications/ARMSX2.app") {
                    profile.executablePath = "/Applications/ARMSX2.app"
                    next = preferredPCSX2Template
                    DebugLog.log("Retargeted emulator \"\(profile.name)\" from AetherSX2 → ARMSX2")
                    changed = true
                }

                if next != profile.launchArgumentTemplate {
                    DebugLog.log(
                        "Updated launch args for emulator \"\(profile.name)\": \(profile.launchArgumentTemplate) → \(next)"
                    )
                    profile.launchArgumentTemplate = next
                    changed = true
                }
            }
            if changed {
                try context.save()
            }
        } catch {
            DebugLog.log("Launch-arg migration failed: \(error.localizedDescription)")
        }

        CatalogLaunchArgumentOverrides.normalizeHomePathsInOverrides()
        CatalogLaunchArgumentOverrides.normalizePCSX2StyleBootSeparatorsInOverrides()
        CustomEmulatorLibraryStore.normalizeHomePathsInEntries()
        CustomEmulatorLibraryStore.normalizePCSX2StyleBootSeparatorsInEntries()
    }
}

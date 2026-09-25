import Foundation

/// Resolves ScreenScraper `systemeid` for a library game when the emulator relationship is missing or incomplete.
enum MetadataSystemResolver {
    static func systemId(for game: LibraryGame, emulator: EmulatorProfile?) -> Int? {
        if let emulator,
           let id = EmulatorPlatformResolver.resolve(emulator: emulator)?.primarySystemId {
            return id
        }
        if game.librarySourceID == "epic" {
            return ScreenScraperPlatformMap.systemId(forGBearSlug: "pc_windows")
        }
        if let hint = game.platformHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hint.isEmpty,
           let id = ScreenScraperPlatformMap.systemId(forPlatformHint: hint) {
            return id
        }
        return nil
    }
}

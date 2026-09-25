import Foundation
import SwiftData

/// User-defined emulator: binary path + how to pass the ROM and optional args.
@Model
public final class EmulatorProfile {
    public var id: UUID
    public var name: String
    /// Path to the emulator executable (.app bundle or binary).
    public var executablePath: String
    /// GBear-style `{ImagePath}` (and `{rom}` / `{ROM}` aliases) is replaced with the game file path when launching.
    /// Use `{user_name}` for the current macOS account in absolute paths (e.g. RetroArch cores under Application Support).
    public var launchArgumentTemplate: String
    /// Comma-separated extensions (no dots) used by path scans for this emulator. Empty/nil = global defaults.
    public var supportedFileTypesCSV: String?
    /// When true, auto-selected cover defaults to ScreenScraper art over local cover candidates.
    public var preferScreenScraperCovers: Bool = false
    /// When true, library scan auto-links multi-disc sets using the same title matching as manual link suggestions.
    public var autoLinkMultiDiscGames: Bool = false
    /// Cover crop for this emulator’s library tiles (`2:3`, `4:3`, `1:1`, `3:4`, `8:7`, `3:5`, `16:9`).
    public var coverAspectRatioRaw: String = CoverAspectRatio.default.rawValue
    public var sortOrder: Int
    public var dateCreated: Date

    @Relationship(deleteRule: .cascade, inverse: \GameFolderPath.emulator)
    public var folderPaths: [GameFolderPath] = []

    public init(
        id: UUID = UUID(),
        name: String,
        executablePath: String,
        launchArgumentTemplate: String = "\"{ImagePath}\"",
        supportedFileTypesCSV: String? = nil,
        preferScreenScraperCovers: Bool = false,
        autoLinkMultiDiscGames: Bool = false,
        coverAspectRatioRaw: String = CoverAspectRatio.default.rawValue,
        sortOrder: Int = 0,
        dateCreated: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.launchArgumentTemplate = launchArgumentTemplate
        self.supportedFileTypesCSV = supportedFileTypesCSV
        self.preferScreenScraperCovers = preferScreenScraperCovers
        self.autoLinkMultiDiscGames = autoLinkMultiDiscGames
        self.coverAspectRatioRaw = CoverAspectRatio.parse(coverAspectRatioRaw).rawValue
        self.sortOrder = sortOrder
        self.dateCreated = dateCreated
    }
}

extension EmulatorProfile {
    public var coverAspectRatio: CoverAspectRatio {
        get { CoverAspectRatio.parse(coverAspectRatioRaw) }
        set { coverAspectRatioRaw = newValue.rawValue }
    }

    /// Lowercased extensions (no dots) parsed from `supportedFileTypesCSV`.
    public var supportedFileTypesSet: Set<String> {
        Set((supportedFileTypesCSV ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty })
    }
}

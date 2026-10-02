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
    /// ScreenScraper `systemeid` for this emulator’s library (manual cover search + scrape). `nil` = infer from catalog/name.
    public var screenScraperSystemId: Int? = nil
    /// Shared by linked profiles (same platform); they appear as one library section named after the platform.
    public var linkGroupIDString: String? = nil
    /// The user's name for the linked group's library section, stored on every member; nil = the platform name.
    public var linkGroupName: String? = nil
    /// The linked profile that opens the group's games unless a game picks another in **Launch with**.
    public var isLinkGroupDefault: Bool = false
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
        screenScraperSystemId: Int? = nil,
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
        self.screenScraperSystemId = screenScraperSystemId
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

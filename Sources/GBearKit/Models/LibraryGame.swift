import Foundation
import SwiftData

/// One library entry: a ROM/disc image linked to an emulator and optional scraped metadata.
@Model
public final class LibraryGame {
    public var id: UUID
    public var title: String
    /// Optional name shown in the library grid; does not rename the file on disk. When `nil`, `title` is shown.
    public var libraryDisplayName: String?
    /// Absolute path to the ROM or disc image.
    public var romPath: String
    /// Snapshot of the emulator UUID used for resilient filtering even if relationship data becomes stale.
    public var emulatorIDString: String?
    public var emulator: EmulatorProfile?
    /// Remote or cached cover image URL (file:// or https://).
    public var coverImageURLString: String?
    /// JSON-encoded ordered cover options detected/imported for this game.
    public var coverImageOptionsJSON: String?
    /// Optional platform/system hint for metadata search (e.g. "SNES", "PS2").
    public var platformHint: String?
    /// User- or scrape-confirmed ScreenScraper game id (`jeuInfos` / `gameid`).
    public var screenScraperGameId: Int?
    /// User- or scrape-confirmed ScreenScraper system id (`systemeid`).
    public var screenScraperSystemId: Int?
    /// User skipped automatic ScreenScraper disambiguation for this game.
    public var screenScraperSelectionSkipped: Bool = false
    /// Optional source identifier (e.g. "epic") for imported launcher ecosystems.
    public var librarySourceID: String?
    /// Epic app name used to launch via Epic Games Launcher URI protocol.
    public var epicAppName: String?
    public var sortOrder: Int
    public var dateAdded: Date
    public var lastPlayed: Date?
    /// When remote metadata was last requested; used to throttle background retries.
    public var metadataLastFetchAt: Date?
    /// Shared id for multi-disc sets; discs with the same value share cover art and ScreenScraper metadata.
    public var discGroupIDString: String?
    /// Display order within a multi-disc set (0 = first). Also drives library grid order for grouped discs.
    public var discGroupOrder: Int?

    public init(
        id: UUID = UUID(),
        title: String,
        libraryDisplayName: String? = nil,
        romPath: String,
        emulatorIDString: String? = nil,
        emulator: EmulatorProfile? = nil,
        coverImageURLString: String? = nil,
        coverImageOptionsJSON: String? = nil,
        platformHint: String? = nil,
        screenScraperGameId: Int? = nil,
        screenScraperSystemId: Int? = nil,
        screenScraperSelectionSkipped: Bool = false,
        librarySourceID: String? = nil,
        epicAppName: String? = nil,
        sortOrder: Int = 0,
        dateAdded: Date = Date(),
        lastPlayed: Date? = nil,
        metadataLastFetchAt: Date? = nil,
        discGroupIDString: String? = nil,
        discGroupOrder: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.libraryDisplayName = libraryDisplayName
        self.romPath = romPath
        self.emulatorIDString = emulatorIDString
        self.emulator = emulator
        self.coverImageURLString = coverImageURLString
        self.coverImageOptionsJSON = coverImageOptionsJSON
        self.platformHint = platformHint
        self.screenScraperGameId = screenScraperGameId
        self.screenScraperSystemId = screenScraperSystemId
        self.screenScraperSelectionSkipped = screenScraperSelectionSkipped
        self.librarySourceID = librarySourceID
        self.epicAppName = epicAppName
        self.sortOrder = sortOrder
        self.dateAdded = dateAdded
        self.lastPlayed = lastPlayed
        self.metadataLastFetchAt = metadataLastFetchAt
        self.discGroupIDString = discGroupIDString
        self.discGroupOrder = discGroupOrder
    }

    /// Title shown in the library UI (user override or `title`).
    public var libraryListTitle: String {
        let custom = libraryDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty { return custom }
        return title
    }

    /// True when this game already has ScreenScraper-sourced box art (cached file or pinned match + cover).
    public var hasScreenScraperCover: Bool {
        let cover = coverImageURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let options = coverImageOptions
        let looksLikeRemoteCover: (String) -> Bool = { value in
            let lowered = value.lowercased()
            return lowered.contains("/cover-cache/") || lowered.contains("screenscraper.fr")
        }
        if !cover.isEmpty, looksLikeRemoteCover(cover) { return true }
        if options.contains(where: looksLikeRemoteCover) { return true }
        if screenScraperGameId != nil, !cover.isEmpty { return true }
        return false
    }

    public var emulatorUUID: UUID? {
        guard let emulatorIDString, let uuid = UUID(uuidString: emulatorIDString) else { return nil }
        return uuid
    }

    public var coverImageOptions: [String] {
        get {
            var options: [String] = []
            if let json = coverImageOptionsJSON,
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                options = decoded
            }
            if let primary = coverImageURLString, !primary.isEmpty, !options.contains(primary) {
                options.insert(primary, at: 0)
            }
            return LibraryGame.normalizedCoverOptions(options)
        }
        set {
            let normalized = LibraryGame.normalizedCoverOptions(newValue)
            if let data = try? JSONEncoder().encode(normalized),
               let json = String(data: data, encoding: .utf8) {
                coverImageOptionsJSON = json
            } else {
                coverImageOptionsJSON = nil
            }
            if let current = coverImageURLString, normalized.contains(current) {
                coverImageURLString = current
            } else {
                coverImageURLString = normalized.first
            }
        }
    }

    private static func normalizedCoverOptions(_ options: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in options {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                out.append(trimmed)
            }
        }
        return out
    }
}

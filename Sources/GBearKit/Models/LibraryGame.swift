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
    /// Remote cover provider for the current scraped art: `screenscraper`, `igdb`, `steamgriddb`, or `thegamesdb`.
    public var remoteCoverSource: String?
    /// Last TheGamesDB search for this game, including a miss.
    public var theGamesDBCheckedAt: Date?
    /// Last IGDB search for this game, including a miss.
    public var igdbCheckedAt: Date?
    /// Last SteamGridDB search for this game, including a miss.
    public var steamGridDBCheckedAt: Date?
    /// Storefront raw value (`epic`, `steam`, `gog`) for launcher-imported games; nil for ROMs and manual Mac games.
    public var librarySourceID: String?
    /// Epic app name used to launch via Epic Games Launcher URI protocol.
    public var epicAppName: String?
    /// Store-side id: Epic app name, Steam app id, or GOG product id.
    public var storefrontGameID: String?
    /// False for owned storefront games that are not installed on this Mac. Nil for non-storefront games.
    public var storefrontInstalled: Bool?
    /// Comma-separated `GamePlatform` raw values the store lists for this game. Nil until known.
    public var storefrontPlatforms: String?
    /// ROMM status for games on an emulator linked to a ROMM platform: `in_romm` or `missing`. Nil when not linked.
    public var rommStatus: String?
    /// Matching ROMM rom id and its server path (`full_path`).
    public var rommRomID: Int?
    public var rommPath: String?
    /// ROMM `fs_name`, used for the download URL and as the local file / folder name.
    public var rommFileName: String?
    /// ROMM serves multi-file games as a zip; it is extracted into a folder named `rommFileName`.
    public var rommHasMultipleFiles: Bool?
    /// True for rows added from ROMM with no local file match until they are downloaded.
    public var rommImported: Bool?
    /// Emulator profile that launches this game instead of its library emulator. Nil uses the library emulator.
    public var launchEmulatorIDString: String?
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
        remoteCoverSource: String? = nil,
        theGamesDBCheckedAt: Date? = nil,
        igdbCheckedAt: Date? = nil,
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
        self.remoteCoverSource = remoteCoverSource
        self.theGamesDBCheckedAt = theGamesDBCheckedAt
        self.igdbCheckedAt = igdbCheckedAt
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

    /// True when this game already has scraped box art in the cover cache, or a pinned ScreenScraper match plus a cover.
    /// TheGamesDB and IGDB downloads land in the same cache, so Only Scan Missing treats them as already scraped.
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

    public var storefront: Storefront? {
        librarySourceID.flatMap(Storefront.init(rawValue:))
    }

    public var platforms: Set<GamePlatform>? {
        get {
            storefrontPlatforms.map { Set($0.split(separator: ",").compactMap { GamePlatform(rawValue: String($0)) }) }
        }
        set {
            storefrontPlatforms = newValue.map { set in
                GamePlatform.allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
            }
        }
    }

    /// Installed storefront games get the green check on their cover.
    public var isInstalledStorefrontGame: Bool {
        storefront != nil && storefrontInstalled != false
    }

    public var isInROMM: Bool { rommStatus == RommStatus.inROMM }

    public var isFilePresent: Bool {
        FileManager.default.fileExists(atPath: (romPath as NSString).standardizingPath)
    }

    /// Linked to a ROMM game and the local file is not on this Mac.
    public var needsROMMDownload: Bool {
        rommRomID != nil && rommStatus == RommStatus.inROMM && !isFilePresent
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

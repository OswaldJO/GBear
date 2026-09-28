import Foundation
import Observation
import SwiftData

/// Links ROMM platforms to emulator profiles and blends each platform's roms into that emulator's library collection.
@Observable
@MainActor
final class RommSync {
    static let shared = RommSync()

    struct Summary: Sendable {
        var inROMM = 0
        var missing = 0
        var added = 0
        var removed = 0
        var skippedBlocked = 0
        var ignoredFiles = 0
        var errors: [String] = []

        var feedbackParts: [String] {
            var parts: [String] = []
            if inROMM + missing > 0 { parts.append("ROMM: \(inROMM) in ROMM, \(missing) missing") }
            if added > 0 { parts.append("Added \(added) game(s) not on this Mac") }
            if removed > 0 { parts.append("Removed \(removed) ROMM game(s) not on this Mac") }
            if skippedBlocked > 0 { parts.append("Skipped \(skippedBlocked) blocked ROMM game(s)") }
            if ignoredFiles > 0 { parts.append("Ignored \(ignoredFiles) hidden or non-game file(s) in ROMM") }
            parts.append(contentsOf: errors)
            return parts
        }
    }

    /// ROMM platform id → emulator profile id.
    private(set) var links: [Int: UUID]
    private(set) var addGamesNotOnMac: Bool
    private(set) var platforms: [RommClient.Platform] = []
    private(set) var serverVersion: String?
    private(set) var connectionError: String?
    private(set) var isConnecting = false
    private(set) var isSyncing = false
    private(set) var status: String?
    private(set) var lastSummary: Summary?
    private(set) var lastSyncAt: Date?
    private(set) var downloading: Set<UUID> = []

    private static let linksKey = "ROMM.PlatformLinks"
    private static let addNotOnMacKey = "ROMM.AddGamesNotOnMac"

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.linksKey) as? [String: String] ?? [:]
        links = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            guard let id = Int(key), let uuid = UUID(uuidString: value) else { return nil }
            return (id, uuid)
        })
        addGamesNotOnMac = UserDefaults.standard.bool(forKey: Self.addNotOnMacKey)
    }

    func setAddGamesNotOnMac(_ on: Bool) {
        addGamesNotOnMac = on
        UserDefaults.standard.set(on, forKey: Self.addNotOnMacKey)
    }

    /// Removes ROMM games that are not on this Mac and every ROMM status, keeping downloaded files' library rows.
    @discardableResult
    func clearSync(modelContext: ModelContext) -> (removed: Int, cleared: Int) {
        guard !isSyncing else { return (0, 0) }
        var removed = 0
        var cleared = 0
        for game in (try? modelContext.fetch(FetchDescriptor<LibraryGame>())) ?? [] {
            if game.rommImported == true, !game.isFilePresent {
                modelContext.delete(game)
                removed += 1
            } else if game.rommStatus != nil || game.rommRomID != nil || game.rommImported != nil {
                clearROMMFields(game)
                game.rommImported = nil
                cleared += 1
            }
        }
        try? modelContext.save()
        lastSummary = nil
        lastSyncAt = nil
        return (removed, cleared)
    }

    func setLink(platformID: Int, emulatorID: UUID?) {
        links[platformID] = emulatorID
        let stored = Dictionary(uniqueKeysWithValues: links.map { (String($0.key), $0.value.uuidString) })
        UserDefaults.standard.set(stored, forKey: Self.linksKey)
    }

    /// Checks the server and loads its platform list.
    func connect() async {
        guard RommCredentials.isConfigured else {
            connectionError = RommClient.RommError.notConfigured.localizedDescription
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        do {
            serverVersion = try await RommClient.serverVersion()
            platforms = try await RommClient.platforms()
            connectionError = nil
        } catch {
            connectionError = error.localizedDescription
            platforms = []
        }
    }

    func disconnect() {
        RommCredentials.signOut()
        platforms = []
        serverVersion = nil
        connectionError = nil
    }

    // MARK: Sync

    @discardableResult
    func sync(modelContext: ModelContext) async -> Summary {
        var summary = Summary()
        guard RommCredentials.isConfigured, !isSyncing else { return summary }
        isSyncing = true
        defer {
            isSyncing = false
            status = nil
        }

        let emulators = (try? modelContext.fetch(FetchDescriptor<EmulatorProfile>())) ?? []
        let blocked = LibraryBlocklist.blockedKeys
        var linkedEmulatorIDs = Set<UUID>()

        for (platformID, emulatorID) in links.sorted(by: { $0.key < $1.key }) {
            guard let emulator = emulators.first(where: { $0.id == emulatorID }) else { continue }
            linkedEmulatorIDs.insert(emulatorID)
            let platformName = platforms.first { $0.id == platformID }?.name ?? "platform \(platformID)"
            status = "Syncing \(platformName)…"
            let roms: [RommClient.Rom]
            do {
                roms = try await RommClient.roms(platformID: platformID)
            } catch {
                summary.errors.append("ROMM \(platformName): \(error.localizedDescription)")
                continue
            }
            let extensions = emulator.supportedFileTypesSet
            let games = roms.filter { Self.isGame($0, supportedExtensions: extensions) }
            summary.ignoredFiles += roms.count - games.count
            blend(games, into: emulator, modelContext: modelContext, blocked: blocked, summary: &summary)
        }

        let allGames = (try? modelContext.fetch(FetchDescriptor<LibraryGame>())) ?? []
        for game in allGames {
            guard let emulatorID = game.emulatorUUID, !linkedEmulatorIDs.contains(emulatorID) else { continue }
            if game.rommImported == true, !FileManager.default.fileExists(atPath: game.romPath) {
                modelContext.delete(game)
                summary.removed += 1
            } else if game.rommStatus != nil {
                clearROMMFields(game)
            }
        }

        try? modelContext.save()
        lastSummary = summary
        lastSyncAt = Date()
        return summary
    }

    private func blend(
        _ roms: [RommClient.Rom],
        into emulator: EmulatorProfile,
        modelContext: ModelContext,
        blocked: Set<String>,
        summary: inout Summary
    ) {
        var romsByKey: [String: RommClient.Rom] = [:]
        for rom in roms {
            for key in [Self.matchKey(rom.fileNameNoTags), Self.matchKey(rom.name)] where !key.isEmpty {
                if romsByKey[key] == nil { romsByKey[key] = rom }
            }
        }
        let romsByID = Dictionary(roms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let emulatorID = emulator.id
        let games = ((try? modelContext.fetch(FetchDescriptor<LibraryGame>())) ?? []).filter { $0.emulatorUUID == emulatorID }
        var matchedRomIDs = Set<Int>()

        for game in games where game.rommImported != true {
            let stem = URL(fileURLWithPath: game.romPath).deletingPathExtension().lastPathComponent
            let rom = [stem, game.title, game.libraryListTitle].lazy
                .map(Self.matchKey)
                .compactMap { romsByKey[$0] }
                .first
            if let rom {
                apply(rom, to: game)
                matchedRomIDs.insert(rom.id)
                summary.inROMM += 1
            } else {
                clearROMMFields(game)
                game.rommStatus = RommStatus.missing
                summary.missing += 1
            }
        }

        var importedRomIDs = Set<Int>()
        for game in games where game.rommImported == true {
            let downloaded = FileManager.default.fileExists(atPath: game.romPath)
            guard let romID = game.rommRomID, let rom = romsByID[romID], !matchedRomIDs.contains(romID),
                  addGamesNotOnMac || downloaded else {
                if downloaded {
                    game.rommImported = false
                    clearROMMFields(game)
                    game.rommStatus = RommStatus.missing
                } else {
                    modelContext.delete(game)
                    summary.removed += 1
                }
                continue
            }
            apply(rom, to: game)
            importedRomIDs.insert(romID)
            summary.inROMM += 1
        }

        guard addGamesNotOnMac else { return }
        var maxSort = ((try? modelContext.fetch(FetchDescriptor<LibraryGame>())) ?? []).map(\.sortOrder).max() ?? 0
        for rom in roms where !matchedRomIDs.contains(rom.id) && !importedRomIDs.contains(rom.id) {
            if blocked.contains(LibraryBlocklist.comparisonKey(Self.blocklistIdentity(romID: rom.id))) {
                summary.skippedBlocked += 1
                continue
            }
            maxSort += 1
            let game = LibraryGame(
                title: rom.name,
                romPath: Self.placeholderPath(for: rom),
                emulatorIDString: emulator.id.uuidString,
                emulator: emulator,
                coverImageURLString: rom.coverURL?.absoluteString,
                platformHint: EmulatorPlatformResolver.resolve(emulator: emulator)?.primaryPlatformHint,
                sortOrder: maxSort,
                metadataLastFetchAt: rom.coverURL == nil ? nil : Date()
            )
            game.rommImported = true
            apply(rom, to: game)
            modelContext.insert(game)
            summary.added += 1
            summary.inROMM += 1
        }
    }

    private func apply(_ rom: RommClient.Rom, to game: LibraryGame) {
        game.rommStatus = RommStatus.inROMM
        game.rommRomID = rom.id
        game.rommPath = rom.fullPath
        game.rommFileName = rom.fileName
        game.rommHasMultipleFiles = rom.hasMultipleFiles
    }

    private func clearROMMFields(_ game: LibraryGame) {
        game.rommStatus = nil
        game.rommRomID = nil
        game.rommPath = nil
        game.rommFileName = nil
        game.rommHasMultipleFiles = nil
    }

    static func blocklistIdentity(romID: Int) -> String { "romm/\(romID)" }

    private static let nonGameExtensions: Set<String> = [
        "txt", "nfo", "diz", "md", "pdf", "rtf", "doc", "htm", "html", "url", "webloc",
        "jpg", "jpeg", "png", "gif", "bmp", "webp", "tif", "tiff", "ico", "svg",
        "mp3", "wav", "flac", "ogg", "mp4", "mkv", "avi", "mov",
        "xml", "json", "dat", "db", "ini", "cfg", "log", "sfv", "md5", "sha1", "crc",
        "sav", "srm", "state", "ds_store", "torrent", "part", "tmp", "bak",
    ]
    private static let nonGameNames: Set<String> = ["thumbs.db", "desktop.ini"]

    /// Keeps real games: no hidden files (`.DS_Store`, `._` AppleDouble), no docs / images / saves, and single files must
    /// use one of the emulator's supported extensions when it has any. Multi-file games are folders and pass.
    static func isGame(_ rom: RommClient.Rom, supportedExtensions: Set<String>) -> Bool {
        let name = rom.fileName.lowercased()
        if name.hasPrefix(".") || nonGameNames.contains(name) { return false }
        if rom.fullPath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false }
        if rom.hasMultipleFiles { return true }
        let ext = (name as NSString).pathExtension
        if nonGameExtensions.contains(ext) { return false }
        return supportedExtensions.isEmpty || supportedExtensions.contains(ext)
    }

    /// Placeholder `romPath` for ROMM-only rows until they are downloaded into a game folder.
    static func placeholderPath(for rom: RommClient.Rom) -> String {
        "/ROMM/\(rom.platformSlug)/\(rom.fileName)"
    }

    /// The emulator's game folders from Paths, the places a ROMM download can go.
    static func downloadFolders(for emulator: EmulatorProfile?) -> [URL] {
        (emulator?.folderPaths ?? [])
            .filter { $0.resolvedPurpose == .games }
            .map { URL(fileURLWithPath: ($0.folderPath as NSString).standardizingPath, isDirectory: true) }
    }

    /// Order-insensitive word key: tags in () / [] dropped, accents folded, roman numerals as digits, filler words removed.
    static func matchKey(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
        text = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        text = text.replacingOccurrences(of: "&", with: " and ")
        let romans = ["ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "vii": "7", "viii": "8", "ix": "9", "x": "10"]
        let filler: Set<String> = ["the", "a", "an", "and"]
        let words = text
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !filler.contains($0) }
            .map { romans[$0] ?? $0 }
        return words.sorted().joined(separator: " ")
    }

    // MARK: Download

    /// Downloads a ROMM game into one of its emulator's game folders and points the library row at it.
    func download(_ game: LibraryGame, into folder: URL, modelContext: ModelContext) async throws {
        guard let romID = game.rommRomID, let fileName = game.rommFileName else { throw RommClient.RommError.decoding }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RommClient.RommError.folderUnavailable(folder.path)
        }
        downloading.insert(game.id)
        defer { downloading.remove(game.id) }

        let temp = try await RommClient.download(romID: romID, fileName: fileName)
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = folder.appending(path: fileName, directoryHint: game.rommHasMultipleFiles == true ? .isDirectory : .notDirectory)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        if game.rommHasMultipleFiles == true {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try await Self.unzip(temp, into: destination)
        } else {
            try FileManager.default.moveItem(at: temp, to: destination)
        }

        game.romPath = destination.path
        game.rommImported = false
        try? modelContext.save()
    }

    private nonisolated static func unzip(_ archive: URL, into folder: URL) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, folder.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw RommClient.RommError.unzipFailed }
        }.value
    }
}

import Foundation
import SwiftData

/// Scans configured game folders one level deep: each file and each immediate subfolder is one game.
public enum GamePathScanner {
    public struct ScanSummary: Sendable {
        public var added: Int
        public var reassigned: Int
        public var linkedCovers: Int
        public var autoLinkedDiscSets: Int
        /// Emulator-linked games under a reachable Paths root whose ROM/file is gone.
        public var removedMissing: Int
        /// Previously imported files that now sit inside a folder treated as a single game.
        public var removedNested: Int

        public init(
            added: Int,
            reassigned: Int,
            linkedCovers: Int,
            autoLinkedDiscSets: Int = 0,
            removedMissing: Int = 0,
            removedNested: Int = 0
        ) {
            self.added = added
            self.reassigned = reassigned
            self.linkedCovers = linkedCovers
            self.autoLinkedDiscSets = autoLinkedDiscSets
            self.removedMissing = removedMissing
            self.removedNested = removedNested
        }

        public var hasAnyChanges: Bool {
            added > 0 || reassigned > 0 || linkedCovers > 0 || autoLinkedDiscSets > 0
                || removedMissing > 0 || removedNested > 0
        }
    }

    /// Common extensions for disc images, archives, and ROMs (lowercase, no dot).
    public static let romExtensions: Set<String> = [
        "nes", "fds", "unf", "unif",
        "smc", "sfc", "fig", "swc", "bs",
        "gb", "gbc", "gba", "nds", "dsi",
        "n64", "z64", "v64",
        "3ds", "cia", "cci", "cxi",
        "md", "smd", "gen", "32x", "sms", "gg", "sg",
        "pce", "sgx", "ngp", "ngc",
        "iso", "gcn", "ciso", "gcz", "rvz", "wbfs", "wad", "dol", "elf",
        "cue", "chd", "gdi", "cdi", "m3u", "pbp",
        "nsp", "xci", "wua",
        "zip", "7z", "rar",
        "psx", "img", "mdf", "bin",
        "lnx", "a26", "a52", "int",
        "crt", "tap", "prg", "d64", "t64",
        "rom", "mx1", "mx2",
        "wad", "pk3", "iwad"
    ]

    private static let coverImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "heic", "bmp", "tif", "tiff", "avif"
    ]
    /// Restrictive file-based imports for PS3/RPCS3 scanners to avoid importing random assets from `dev_hdd0/game`.
    private static let ps3FileExtensions: Set<String> = ["iso"]

    private struct PS3FolderMetadata {
        let title: String?
        let titleID: String?
        let category: String?
    }

    private struct CoverCandidate {
        let url: URL
        let tokens: Set<String>
        let order: Int
    }

    /// Returns an executable PS3 target path when this folder looks like a PS3 disc dump or RPCS3 installed title.
    private static func ps3LaunchPathIfPresent(for folder: URL) -> URL? {
        let fm = FileManager.default
        let candidatePaths = [
            // Disc dump structure: <Game>/PS3_GAME/USRDIR/EBOOT.BIN
            folder.appendingPathComponent("PS3_GAME/USRDIR/EBOOT.BIN").path,
            // RPCS3 installed structure: <TitleID>/USRDIR/EBOOT.BIN
            folder.appendingPathComponent("USRDIR/EBOOT.BIN").path
        ]
        for p in candidatePaths {
            if fm.fileExists(atPath: p) {
                return URL(fileURLWithPath: (p as NSString).standardizingPath)
            }
        }
        return nil
    }

    private static func ps3Metadata(for folder: URL) -> PS3FolderMetadata? {
        let sfoCandidates = [
            folder.appendingPathComponent("PS3_GAME/PARAM.SFO"),
            folder.appendingPathComponent("PARAM.SFO")
        ]

        for url in sfoCandidates {
            guard let data = try? Data(contentsOf: url),
                  let fields = parsePS3SFO(data) else { continue }

            let title = fields["TITLE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let titleID = fields["TITLE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let category = fields["CATEGORY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return PS3FolderMetadata(
                title: (title?.isEmpty == false ? title : nil),
                titleID: (titleID?.isEmpty == false ? titleID : nil),
                category: (category?.isEmpty == false ? category : nil)
            )
        }
        return nil
    }

    /// Resolves a readable title for PS3 content from PARAM.SFO (TITLE > TITLE_ID > fallback folder name).
    private static func ps3DisplayTitle(for folder: URL) -> String {
        let fallback = folder.lastPathComponent
        guard let meta = ps3Metadata(for: folder) else { return fallback }
        if let title = meta.title { return title }
        if let titleID = meta.titleID { return titleID }
        return fallback
    }

    /// Keeps scan results focused on playable titles and avoids importing game data/patch/DLC folders.
    /// Playable PARAM.SFO categories: `GD` (disc install) and `HG` (PSN/HDD install).
    private static func shouldIncludePS3Folder(_ folder: URL) -> Bool {
        guard let meta = ps3Metadata(for: folder), let category = meta.category?.uppercased() else { return false }
        return category == "GD" || category == "HG"
    }

    private static func isPS3StyleEmulator(_ emulator: EmulatorProfile) -> Bool {
        let name = emulator.name.lowercased()
        let exe = emulator.executablePath.lowercased()
        if name.contains("rpcs3") || name.contains("ps3") { return true }
        if exe.contains("rpcs3") { return true }
        return false
    }

    private static func isPath(_ path: String, insideAny excludedRoots: [String]) -> Bool {
        let normalizedPath = normalizedPathForComparison(path)
        for root in excludedRoots {
            let normalizedRoot = normalizedPathForComparison(root)
            if normalizedPath == normalizedRoot { return true }
            if normalizedPath.hasPrefix(normalizedRoot + "/") { return true }
        }
        return false
    }

    private static func normalizedPathForComparison(_ path: String) -> String {
        var normalized = (path as NSString).standardizingPath
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized.lowercased()
    }

    /// Minimal parser for PS3 PARAM.SFO key/value string fields.
    private static func parsePS3SFO(_ data: Data) -> [String: String]? {
        guard data.count >= 20 else { return nil }

        func u16(_ offset: Int) -> UInt16? {
            guard offset + 2 <= data.count else { return nil }
            return data.withUnsafeBytes { raw in
                raw.load(fromByteOffset: offset, as: UInt16.self).littleEndian
            }
        }

        func u32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            return data.withUnsafeBytes { raw in
                raw.load(fromByteOffset: offset, as: UInt32.self).littleEndian
            }
        }

        guard let magic = u32(0), magic == 0x46535000,
              let keyTableStart = u32(8),
              let dataTableStart = u32(12),
              let count = u32(16) else { return nil }

        var out: [String: String] = [:]
        let base = 20
        let entrySize = 16

        for i in 0..<Int(count) {
            let entry = base + i * entrySize
            guard entry + entrySize <= data.count,
                  let keyOffset = u16(entry),
                  let valueLen = u32(entry + 4),
                  let dataOffset = u32(entry + 12) else { continue }

            let keyStart = Int(keyTableStart) + Int(keyOffset)
            guard keyStart < data.count else { continue }
            let keyEnd = data[keyStart...].firstIndex(of: 0) ?? data.endIndex
            guard keyEnd > keyStart else { continue }
            guard let key = String(data: data[keyStart..<keyEnd], encoding: .utf8), !key.isEmpty else { continue }

            let valueStart = Int(dataTableStart) + Int(dataOffset)
            let safeLen = max(0, Int(valueLen))
            guard valueStart >= 0, valueStart + safeLen <= data.count else { continue }

            var valueData = data[valueStart..<(valueStart + safeLen)]
            while valueData.last == 0 { valueData.removeLast() }
            if let value = String(data: valueData, encoding: .utf8), !value.isEmpty {
                out[key] = value
            }
        }

        return out.isEmpty ? nil : out
    }

    /// Ordered cover candidates per emulator with fuzzy-match tokens.
    private static func buildCoverCandidates(folderEntries: [GameFolderPath]) -> [UUID: [CoverCandidate]] {
        var result: [UUID: [CoverCandidate]] = [:]
        var globalOrder = 0
        let coverEntries = folderEntries
            .filter { $0.resolvedPurpose == .covers }
            .sorted { $0.sortOrder < $1.sortOrder }

        for entry in coverEntries {
            guard let emulator = entry.emulator else { continue }
            let emuID = emulator.id
            let root = URL(fileURLWithPath: entry.folderPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let item = enumerator.nextObject() as? URL {
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                let isFileLike = (values?.isRegularFile == true) || (values?.isSymbolicLink == true)
                guard isFileLike else { continue }

                let ext = item.pathExtension.lowercased()
                guard coverImageExtensions.contains(ext) else { continue }

                let stem = strippedImageSuffixes(from: item.lastPathComponent)
                let tokens = significantTokens(from: stem)
                guard !tokens.isEmpty else { continue }

                let standardized = URL(fileURLWithPath: (item.path as NSString).standardizingPath)
                globalOrder += 1
                var perEmu = result[emuID] ?? []
                perEmu.append(CoverCandidate(url: standardized, tokens: tokens, order: globalOrder))
                result[emuID] = perEmu
            }
        }
        return result
    }

    private static func strippedImageSuffixes(from fileName: String) -> String {
        var base = fileName
        while true {
            let ext = (base as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, coverImageExtensions.contains(ext) else { break }
            base = (base as NSString).deletingPathExtension
        }
        return base
    }

    private static let nonDistinctiveTokens: Set<String> = [
        "cover", "covers", "art", "image", "img", "scan", "poster", "wallpaper", "game"
    ]

    private static func significantTokens(from raw: String) -> Set<String> {
        let lowered = raw.lowercased()
        let cleaned = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let normalized = String(cleaned)
        return Set(
            normalized
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter { token in
                    if token.isEmpty { return false }
                    if token.allSatisfy(\.isNumber) { return false }
                    if token.first == "v", token.dropFirst().allSatisfy(\.isNumber) { return false }
                    if token.rangeOfCharacter(from: .decimalDigits) != nil { return false }
                    if nonDistinctiveTokens.contains(token) { return false }
                    return true
                }
        )
    }

    private static func gameTokens(title: String, romPath: String) -> Set<String> {
        let titleStem = URL(fileURLWithPath: romPath).deletingPathExtension().lastPathComponent
        let bracketStripped = titleStem.replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        let combined = title + " " + bracketStripped
        return significantTokens(from: combined)
    }

    private static func matchedCoverURLs(
        for title: String,
        romPath: String,
        candidates: [CoverCandidate]
    ) -> [URL] {
        let tokens = gameTokens(title: title, romPath: romPath)
        guard !tokens.isEmpty else { return [] }

        let matches: [(score: Double, order: Int, url: URL)] = candidates.compactMap { candidate in
            guard !candidate.tokens.isEmpty else { return nil }
            // Require candidate tokens to be contained in game tokens to avoid sequel/prequel bleed.
            guard candidate.tokens.isSubset(of: tokens) else { return nil }
            let recall = Double(candidate.tokens.count) / Double(max(tokens.count, 1))
            let precision = 1.0
            let f1 = (2 * precision * recall) / (precision + recall)
            return (f1, candidate.order, candidate.url)
        }

        return matches
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.order < rhs.order }
                return lhs.score > rhs.score
            }
            .map(\.url)
    }

    private static func applyDetectedCovers(_ urls: [URL], to game: LibraryGame) {
        guard !urls.isEmpty else { return }
        let existing = game.coverImageOptions
        let merged = existing + urls.map(\.absoluteString)
        game.coverImageOptions = merged
    }

    /// Prefer playlists and cue sheets over raw tracks so a bin/cue folder launches as one game.
    private static let folderLaunchExtensionPriority: [String] = [
        "m3u", "m3u8", "cue", "gdi", "chd", "iso", "cso", "ciso", "cdi", "pbp",
        "rvz", "wbfs", "wad", "wua", "nsp", "xci",
        "3ds", "cia", "cci", "cxi",
        "z64", "n64", "v64",
        "gba", "gbc", "gb", "nds", "dsi",
        "smc", "sfc", "nes", "fds",
        "md", "smd", "gen", "32x", "sms", "gg",
        "zip", "7z", "rar",
        "bin", "img", "mdf", "psx"
    ]

    private static func allowedRomExtensions(for emulator: EmulatorProfile, isPS3Emulator: Bool) -> Set<String> {
        let specific = emulator.supportedFileTypesSet
        if !specific.isEmpty { return specific }
        if isPS3Emulator { return ps3FileExtensions }
        return romExtensions
    }

    private static func directoryListing(at root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private static func resourceFlags(for url: URL) -> (isDirectory: Bool, isFileLike: Bool, isPackage: Bool) {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        var isDirectory = values?.isDirectory == true
        var isFileLike = (values?.isRegularFile == true) || (values?.isSymbolicLink == true && !isDirectory)
        let isPackage = values?.isPackage == true
        if !isDirectory && !isFileLike {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                isDirectory = isDir.boolValue
                isFileLike = !isDir.boolValue
            }
        }
        return (isDirectory, isFileLike, isPackage)
    }

    /// Raw tracks that sit beside a cue/gdi/m3u (or are named `(Track N)`). Not PS3 `EBOOT.BIN`.
    private static let sidecarTrackExtensions: Set<String> = ["bin", "img", "mdf", "raw", "wav", "ape", "flac"]
    private static let discDescriptorExtensions: Set<String> = ["cue", "m3u", "m3u8", "gdi"]

    private static func isPS3Eboot(_ url: URL) -> Bool {
        url.lastPathComponent.compare("EBOOT.BIN", options: .caseInsensitive) == .orderedSame
    }

    private static func looksLikeNumberedTrackFile(_ url: URL) -> Bool {
        url.lastPathComponent.range(
            of: #"\(Track\s*\d+\)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isSidecarTrackFile(_ url: URL, siblings: [URL]) -> Bool {
        if isPS3Eboot(url) { return false }
        let ext = url.pathExtension.lowercased()
        guard sidecarTrackExtensions.contains(ext) else { return false }
        if looksLikeNumberedTrackFile(url) { return true }
        return siblings.contains { discDescriptorExtensions.contains($0.pathExtension.lowercased()) }
    }

    private static func belongs(_ game: LibraryGame, to emulator: EmulatorProfile) -> Bool {
        if game.emulator?.id == emulator.id { return true }
        if game.emulatorUUID == emulator.id { return true }
        return false
    }

    /// Best launch file among **immediate** children of a game folder (does not recurse).
    private static func preferredLaunchFile(in folder: URL, allowedExtensions: Set<String>) -> URL? {
        let folderName = folder.lastPathComponent.lowercased()
        let files = directoryListing(at: folder).compactMap { item -> URL? in
            let flags = resourceFlags(for: item)
            guard flags.isFileLike, !flags.isPackage else { return nil }
            let ext = item.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { return nil }
            return URL(fileURLWithPath: (item.path as NSString).standardizingPath)
        }
        guard !files.isEmpty else { return nil }

        func rank(_ url: URL) -> (Int, Int, String) {
            let ext = url.pathExtension.lowercased()
            let priority = folderLaunchExtensionPriority.firstIndex(of: ext) ?? (folderLaunchExtensionPriority.count + 1)
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            let nameMatch = stem == folderName ? 0 : 1
            return (priority, nameMatch, url.lastPathComponent.lowercased())
        }

        return files.min { rank($0) < rank($1) }
    }

    private struct IngestState {
        var existingPaths: Set<String>
        var existingByPath: [String: LibraryGame]
        var maxSort: Int
        var added: Int
        var reassignedTotal: Int
        var addedForEmulator: Int
        var reassignedExisting: Int
        var skippedAsExisting: Int
        var wantedPaths: Set<String>
    }

    @discardableResult
    private static func ingestCandidate(
        title: String,
        romURL: URL,
        emulator: EmulatorProfile,
        coverCandidates: [CoverCandidate],
        modelContext: ModelContext,
        state: inout IngestState
    ) -> Bool {
        let standardized = (romURL.path as NSString).standardizingPath
        let comparisonPath = normalizedPathForComparison(standardized)
        state.wantedPaths.insert(comparisonPath)

        if state.existingPaths.contains(comparisonPath) {
            if let existing = state.existingByPath[comparisonPath] {
                var changed = false
                if existing.emulator == nil
                    || existing.emulatorUUID == nil
                    || existing.emulatorUUID != emulator.id
                    || existing.platformHint == nil {
                    existing.emulator = emulator
                    existing.emulatorIDString = emulator.id.uuidString
                    existing.platformHint = EmulatorPlatformResolver.resolve(emulator: emulator)?.primaryPlatformHint
                    changed = true
                }
                if existing.title != title {
                    existing.title = title
                    changed = true
                }
                if changed {
                    state.reassignedExisting += 1
                    state.reassignedTotal += 1
                } else {
                    state.skippedAsExisting += 1
                }
            } else {
                state.skippedAsExisting += 1
            }
            return false
        }

        state.existingPaths.insert(comparisonPath)
        let matchedCovers = matchedCoverURLs(
            for: title,
            romPath: standardized,
            candidates: coverCandidates
        )
        state.maxSort += 1
        let game = LibraryGame(
            title: title,
            romPath: standardized,
            emulatorIDString: emulator.id.uuidString,
            emulator: emulator,
            platformHint: EmulatorPlatformResolver.resolve(emulator: emulator)?.primaryPlatformHint,
            sortOrder: state.maxSort
        )
        applyDetectedCovers(matchedCovers, to: game)
        modelContext.insert(game)
        state.existingByPath[comparisonPath] = game
        state.added += 1
        state.addedForEmulator += 1
        return true
    }

    /// Drops leftover per-file rows under this scan root that are not the chosen file/folder launch path.
    private static func removeStaleGames(
        under root: URL,
        emulator: EmulatorProfile,
        wantedPaths: Set<String>,
        otherGameRoots: [String],
        modelContext: ModelContext,
        state: inout IngestState
    ) -> Int {
        let rootNorm = normalizedPathForComparison(root.path)
        let moreSpecificRoots = otherGameRoots.filter { other in
            other.count > rootNorm.count && other.hasPrefix(rootNorm + "/")
        }
        var removed = 0
        let snapshot = (try? modelContext.fetch(FetchDescriptor<LibraryGame>())) ?? Array(state.existingByPath.values)
        for game in snapshot {
            guard belongs(game, to: emulator) else { continue }
            let gamePath = normalizedPathForComparison(game.romPath)
            guard isPath(gamePath, insideAny: [rootNorm]) else { continue }
            if wantedPaths.contains(gamePath) { continue }
            if !moreSpecificRoots.isEmpty, isPath(gamePath, insideAny: moreSpecificRoots) {
                continue
            }
            deleteStaleGame(game, gamePath: gamePath, modelContext: modelContext, state: &state, removed: &removed)
        }
        return removed
    }

    private static func deleteStaleGame(
        _ game: LibraryGame,
        gamePath: String,
        modelContext: ModelContext,
        state: inout IngestState,
        removed: inout Int
    ) {
        DebugLog.log(
            "Scan: removing nested/stale path-scanned game title=\(game.title) path=\(game.romPath)"
        )
        modelContext.delete(game)
        state.existingPaths.remove(gamePath)
        state.existingByPath.removeValue(forKey: gamePath)
        removed += 1
    }

    /// Cue/gdi dumps leave `.bin` tracks in the same folder; those rows are never games.
    private static func removeSidecarTrackLibraryRows(modelContext: ModelContext) -> Int {
        let games = (try? modelContext.fetch(FetchDescriptor<LibraryGame>())) ?? []
        var removed = 0
        var siblingCache: [String: [URL]] = [:]
        for game in games {
            let romURL = URL(fileURLWithPath: game.romPath)
            if isPS3Eboot(romURL) { continue }
            let parent = romURL.deletingLastPathComponent()
            let parentKey = normalizedPathForComparison(parent.path)
            let siblings = siblingCache[parentKey] ?? directoryListing(at: parent)
            siblingCache[parentKey] = siblings
            guard isSidecarTrackFile(romURL, siblings: siblings) else { continue }
            DebugLog.log(
                "Scan: removing cue sidecar title=\(game.title) path=\(game.romPath)"
            )
            modelContext.delete(game)
            removed += 1
        }
        if removed > 0 {
            DebugLog.log("Scan: removed cue/gdi sidecar tracks count=\(removed)")
        }
        return removed
    }

    public static func scan(modelContext: ModelContext) throws -> ScanSummary {
        let gamesFetch = FetchDescriptor<LibraryGame>()
        let existingGames = try modelContext.fetch(gamesFetch)
        var state = IngestState(
            existingPaths: Set(existingGames.map { normalizedPathForComparison($0.romPath) }),
            existingByPath: Dictionary(
                existingGames.map { (normalizedPathForComparison($0.romPath), $0) },
                uniquingKeysWith: { first, _ in first }
            ),
            maxSort: existingGames.map(\.sortOrder).max() ?? 0,
            added: 0,
            reassignedTotal: 0,
            addedForEmulator: 0,
            reassignedExisting: 0,
            skippedAsExisting: 0,
            wantedPaths: []
        )
        var removedNested = 0

        let pathsFetch = FetchDescriptor<GameFolderPath>()
        let folderEntries = try modelContext.fetch(pathsFetch)
        let coverCandidates = buildCoverCandidates(folderEntries: folderEntries)
        let romFolderEntries = folderEntries.filter { $0.resolvedPurpose == .games }

        for entry in romFolderEntries {
            guard let emulator = entry.emulator else { continue }
            let isPS3Emulator = isPS3StyleEmulator(emulator)
            let allowedExtensions = allowedRomExtensions(for: emulator, isPS3Emulator: isPS3Emulator)
            var scannedItems = 0
            var skippedByExclude = 0
            var skippedByExtension = 0
            var skippedEmptyFolders = 0
            state.addedForEmulator = 0
            state.reassignedExisting = 0
            state.skippedAsExisting = 0
            state.wantedPaths = []
            let root = URL(fileURLWithPath: entry.folderPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
                DebugLog.log("Scan: skipping missing root for emulator=\(emulator.name) root=\(entry.folderPath)")
                continue
            }

            let excludedRoots = folderEntries
                .filter { $0.emulator?.id == emulator.id && $0.resolvedPurpose == .excludes }
                .map { normalizedPathForComparison($0.folderPath) }
                .sorted { $0.count > $1.count }
            let standardizedRoot = normalizedPathForComparison(root.path)
            let extensionSummary = emulator.supportedFileTypesSet.isEmpty
                ? (isPS3Emulator ? "ps3-iso-only" : "global-defaults")
                : allowedExtensions.sorted().joined(separator: ",")
            DebugLog.log(
                "Scan start: emulator=\(emulator.name) root=\(root.path) depth=1 extMode=\(extensionSummary) excludes=\(excludedRoots)"
            )
            if isPath(standardizedRoot, insideAny: excludedRoots) {
                DebugLog.log("Scan: root excluded for emulator=\(emulator.name) root=\(root.path)")
                continue
            }

            var removedExistingBecauseExcluded = 0
            for game in Array(state.existingByPath.values) where game.emulatorUUID == emulator.id {
                let gamePath = normalizedPathForComparison(game.romPath)
                if isPath(gamePath, insideAny: excludedRoots) {
                    modelContext.delete(game)
                    state.existingPaths.remove(gamePath)
                    state.existingByPath.removeValue(forKey: gamePath)
                    removedExistingBecauseExcluded += 1
                }
            }
            if removedExistingBecauseExcluded > 0 {
                DebugLog.log(
                    "Scan: removed existing excluded games emulator=\(emulator.name) count=\(removedExistingBecauseExcluded)"
                )
            }

            let children = directoryListing(at: root).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            let covers = coverCandidates[emulator.id] ?? []

            for item in children {
                let flags = resourceFlags(for: item)
                if flags.isPackage { continue }

                if flags.isDirectory {
                    let dirPath = normalizedPathForComparison(item.path)
                    if isPath(dirPath, insideAny: excludedRoots) {
                        skippedByExclude += 1
                        continue
                    }
                    scannedItems += 1

                    if isPS3Emulator {
                        if let ps3Launch = ps3LaunchPathIfPresent(for: item), shouldIncludePS3Folder(item) {
                            ingestCandidate(
                                title: ps3DisplayTitle(for: item),
                                romURL: ps3Launch,
                                emulator: emulator,
                                coverCandidates: covers,
                                modelContext: modelContext,
                                state: &state
                            )
                        } else {
                            skippedEmptyFolders += 1
                        }
                        continue
                    }

                    if let launch = preferredLaunchFile(in: item, allowedExtensions: allowedExtensions) {
                        ingestCandidate(
                            title: item.lastPathComponent,
                            romURL: launch,
                            emulator: emulator,
                            coverCandidates: covers,
                            modelContext: modelContext,
                            state: &state
                        )
                    } else {
                        skippedEmptyFolders += 1
                    }
                    continue
                }

                guard flags.isFileLike else { continue }
                scannedItems += 1
                let itemPath = (item.path as NSString).standardizingPath
                if isPath(itemPath, insideAny: excludedRoots) {
                    skippedByExclude += 1
                    continue
                }

                let ext = item.pathExtension.lowercased()
                guard allowedExtensions.contains(ext) else {
                    skippedByExtension += 1
                    continue
                }
                let siblingFiles = children.filter { resourceFlags(for: $0).isFileLike }
                if isSidecarTrackFile(item, siblings: siblingFiles) {
                    skippedByExtension += 1
                    continue
                }

                ingestCandidate(
                    title: item.deletingPathExtension().lastPathComponent,
                    romURL: URL(fileURLWithPath: itemPath),
                    emulator: emulator,
                    coverCandidates: covers,
                    modelContext: modelContext,
                    state: &state
                )
            }

            let nestedRemoved = removeStaleGames(
                under: root,
                emulator: emulator,
                wantedPaths: state.wantedPaths,
                otherGameRoots: romFolderEntries.compactMap { other in
                    guard other.emulator?.id == emulator.id else { return nil }
                    let normalized = normalizedPathForComparison(other.folderPath)
                    return normalized == standardizedRoot ? nil : normalized
                },
                modelContext: modelContext,
                state: &state
            )
            removedNested += nestedRemoved

            DebugLog.log(
                "Scan done: emulator=\(emulator.name) root=\(root.path) scanned=\(scannedItems) added=\(state.addedForEmulator) reassigned=\(state.reassignedExisting) skipExcluded=\(skippedByExclude) skipExtension=\(skippedByExtension) skipExisting=\(state.skippedAsExisting) skipEmptyFolders=\(skippedEmptyFolders) removedNested=\(nestedRemoved)"
            )
        }

        let sidecarRemoved = removeSidecarTrackLibraryRows(modelContext: modelContext)
        removedNested += sidecarRemoved

        let removedMissing = pruneMissingPathScannedGames(
            modelContext: modelContext,
            folderEntries: romFolderEntries
        )

        var linkedCovers = 0
        let allGames = try modelContext.fetch(gamesFetch)
        for game in allGames {
            guard let emulatorID = game.emulatorUUID else { continue }
            let matched = matchedCoverURLs(
                for: game.title,
                romPath: game.romPath,
                candidates: coverCandidates[emulatorID] ?? []
            )
            let before = game.coverImageOptions.count
            applyDetectedCovers(matched, to: game)
            linkedCovers += max(0, game.coverImageOptions.count - before)
        }

        let autoLinkedDiscSets = DiscGroupService.autoLinkAllEnabledEmulators(context: modelContext)

        if state.added > 0 || state.reassignedTotal > 0 || linkedCovers > 0 || autoLinkedDiscSets > 0
            || removedMissing > 0 || removedNested > 0 {
            try modelContext.save()
        }
        DebugLog.log(
            "Scan result: added=\(state.added) reassigned=\(state.reassignedTotal) linkedCovers=\(linkedCovers) autoLinkedDiscSets=\(autoLinkedDiscSets) removedMissing=\(removedMissing) removedNested=\(removedNested)"
        )
        return ScanSummary(
            added: state.added,
            reassigned: state.reassignedTotal,
            linkedCovers: linkedCovers,
            autoLinkedDiscSets: autoLinkedDiscSets,
            removedMissing: removedMissing,
            removedNested: removedNested
        )
    }

    /// Removes path-scanned games whose files are gone, without wiping entries when a whole drive/root is offline.
    ///
    /// Only considers emulator-linked games whose `romPath` sits under a configured **Paths** game folder.
    /// If every matching root is missing (unmounted volume), the game is kept. If at least one matching
    /// root is reachable and the file is absent, the library row is deleted.
    @discardableResult
    private static func pruneMissingPathScannedGames(
        modelContext: ModelContext,
        folderEntries: [GameFolderPath]
    ) -> Int {
        struct RootInfo {
            let normalized: String
            let reachable: Bool
        }

        var rootsByEmulator: [UUID: [RootInfo]] = [:]
        for entry in folderEntries {
            guard let emulatorID = entry.emulator?.id else { continue }
            let rootURL = URL(fileURLWithPath: entry.folderPath)
            var isDir: ObjCBool = false
            let reachable = FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir) && isDir.boolValue
            let info = RootInfo(
                normalized: normalizedPathForComparison(rootURL.path),
                reachable: reachable
            )
            rootsByEmulator[emulatorID, default: []].append(info)
        }

        guard !rootsByEmulator.isEmpty else { return 0 }

        let games = (try? modelContext.fetch(FetchDescriptor<LibraryGame>())) ?? []
        var removed = 0
        for game in games {
            guard let emulatorID = game.emulatorUUID,
                  let roots = rootsByEmulator[emulatorID],
                  !roots.isEmpty else { continue }

            let gamePath = normalizedPathForComparison(game.romPath)
            let matching = roots.filter { isPath(gamePath, insideAny: [$0.normalized]) }
            guard !matching.isEmpty else { continue }

            let reachableMatches = matching.filter(\.reachable)
            guard !reachableMatches.isEmpty else {
                continue
            }

            let standardized = (game.romPath as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: standardized) {
                continue
            }

            DebugLog.log(
                "Scan: removing missing path-scanned game title=\(game.title) path=\(standardized)"
            )
            modelContext.delete(game)
            removed += 1
        }

        if removed > 0 {
            DebugLog.log("Scan: pruned missing path-scanned games count=\(removed)")
        }
        return removed
    }
}

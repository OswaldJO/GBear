import Foundation
import SwiftData

/// Recursively scans configured folders and inserts new `LibraryGame` rows for recognized ROM-like files.
public enum GamePathScanner {
    public struct ScanSummary: Sendable {
        public var added: Int
        public var reassigned: Int
        public var linkedCovers: Int
        public var autoLinkedDiscSets: Int
        /// Emulator-linked games under a reachable Paths root whose ROM/file is gone.
        public var removedMissing: Int

        public init(
            added: Int,
            reassigned: Int,
            linkedCovers: Int,
            autoLinkedDiscSets: Int = 0,
            removedMissing: Int = 0
        ) {
            self.added = added
            self.reassigned = reassigned
            self.linkedCovers = linkedCovers
            self.autoLinkedDiscSets = autoLinkedDiscSets
            self.removedMissing = removedMissing
        }

        public var hasAnyChanges: Bool {
            added > 0 || reassigned > 0 || linkedCovers > 0 || autoLinkedDiscSets > 0 || removedMissing > 0
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

    public static func scan(modelContext: ModelContext) throws -> ScanSummary {
        let gamesFetch = FetchDescriptor<LibraryGame>()
        let existingGames = try modelContext.fetch(gamesFetch)
        var existingPaths = Set(
            existingGames.map { normalizedPathForComparison($0.romPath) }
        )
        var existingByPath: [String: LibraryGame] = [:]
        for game in existingGames {
            existingByPath[normalizedPathForComparison(game.romPath)] = game
        }

        let pathsFetch = FetchDescriptor<GameFolderPath>()
        let folderEntries = try modelContext.fetch(pathsFetch)
        let coverCandidates = buildCoverCandidates(folderEntries: folderEntries)
        let romFolderEntries = folderEntries.filter { $0.resolvedPurpose == .games }

        var maxSort = existingGames.map(\.sortOrder).max() ?? 0
        var added = 0
        var reassignedTotal = 0

        for entry in romFolderEntries {
            guard let emulator = entry.emulator else { continue }
            let isPS3Emulator = isPS3StyleEmulator(emulator)
            let emulatorSpecificExtensions = emulator.supportedFileTypesSet
            var scannedFileLikeItems = 0
            var skippedByExclude = 0
            var skippedByExtension = 0
            var skippedAsExisting = 0
            var reassignedExisting = 0
            var addedForEmulator = 0
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
            let extensionSummary = emulatorSpecificExtensions.isEmpty
                ? (isPS3Emulator ? "ps3-iso-only" : "global-defaults")
                : emulatorSpecificExtensions.sorted().joined(separator: ",")
            DebugLog.log(
                "Scan start: emulator=\(emulator.name) root=\(root.path) extMode=\(extensionSummary) excludes=\(excludedRoots)"
            )
            if isPath(standardizedRoot, insideAny: excludedRoots) {
                DebugLog.log("Scan: root excluded for emulator=\(emulator.name) root=\(root.path)")
                continue
            }

            // If excluded roots changed since a prior scan, remove already-imported entries now under exclusion.
            var removedExistingBecauseExcluded = 0
            for existingGame in existingGames where existingGame.emulatorUUID == emulator.id {
                let gamePath = normalizedPathForComparison(existingGame.romPath)
                if isPath(gamePath, insideAny: excludedRoots) {
                    modelContext.delete(existingGame)
                    existingPaths.remove(gamePath)
                    existingByPath.removeValue(forKey: gamePath)
                    removedExistingBecauseExcluded += 1
                }
            }
            if removedExistingBecauseExcluded > 0 {
                DebugLog.log(
                    "Scan: removed existing excluded games emulator=\(emulator.name) count=\(removedExistingBecauseExcluded)"
                )
            }

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let item = enumerator.nextObject() as? URL {
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])

                if values?.isDirectory == true, let ps3Launch = ps3LaunchPathIfPresent(for: item) {
                    let dirPath = normalizedPathForComparison(item.path)
                    if isPath(dirPath, insideAny: excludedRoots) {
                        skippedByExclude += 1
                        enumerator.skipDescendants()
                        continue
                    }
                    guard shouldIncludePS3Folder(item) else {
                        enumerator.skipDescendants()
                        continue
                    }
                    let standardized = (ps3Launch.path as NSString).standardizingPath
                    let comparisonPath = normalizedPathForComparison(standardized)
                    let title = ps3DisplayTitle(for: item)
                    if existingPaths.contains(comparisonPath) {
                        if let existing = existingByPath[comparisonPath] {
                            if existing.emulator == nil
                                || existing.emulatorUUID == nil
                                || existing.emulatorUUID != emulator.id
                                || existing.platformHint == nil {
                                existing.emulator = emulator
                                existing.emulatorIDString = emulator.id.uuidString
                                existing.platformHint = EmulatorPlatformResolver.resolve(emulator: emulator)?.primaryPlatformHint
                                reassignedExisting += 1
                                reassignedTotal += 1
                            }
                            if existing.title != title {
                                existing.title = title
                                reassignedExisting += 1
                                reassignedTotal += 1
                            }
                        } else {
                            skippedAsExisting += 1
                        }
                        enumerator.skipDescendants()
                        continue
                    }
                    existingPaths.insert(comparisonPath)
                    let matchedCovers = matchedCoverURLs(
                        for: title,
                        romPath: standardized,
                        candidates: coverCandidates[emulator.id] ?? []
                    )
                    maxSort += 1
                    let game = LibraryGame(
                        title: title,
                        romPath: standardized,
                        emulatorIDString: emulator.id.uuidString,
                        emulator: emulator,
                        platformHint: EmulatorPlatformResolver.resolve(emulator: emulator)?.primaryPlatformHint,
                        sortOrder: maxSort
                    )
                    applyDetectedCovers(matchedCovers, to: game)
                    modelContext.insert(game)
                    added += 1
                    addedForEmulator += 1
                    enumerator.skipDescendants()
                    continue
                }

                let isFileLike = (values?.isRegularFile == true) || (values?.isSymbolicLink == true)
                guard isFileLike else { continue }
                scannedFileLikeItems += 1
                let itemPath = (item.path as NSString).standardizingPath
                let comparisonItemPath = normalizedPathForComparison(itemPath)
                if isPath(comparisonItemPath, insideAny: excludedRoots) {
                    skippedByExclude += 1
                    continue
                }

                let ext = item.pathExtension.lowercased()
                if !emulatorSpecificExtensions.isEmpty {
                    guard emulatorSpecificExtensions.contains(ext) else {
                        skippedByExtension += 1
                        continue
                    }
                } else if isPS3Emulator {
                    guard ps3FileExtensions.contains(ext) else {
                        skippedByExtension += 1
                        continue
                    }
                } else {
                    guard romExtensions.contains(ext) else {
                        skippedByExtension += 1
                        continue
                    }
                }

                let standardized = itemPath
                guard !existingPaths.contains(comparisonItemPath) else {
                    if let existing = existingByPath[comparisonItemPath] {
                        if existing.emulator == nil
                            || existing.emulatorUUID == nil
                            || existing.emulatorUUID != emulator.id
                            || existing.platformHint == nil {
                            existing.emulator = emulator
                            existing.emulatorIDString = emulator.id.uuidString
                            existing.platformHint = EmulatorPlatformResolver.resolve(emulator: emulator)?.primaryPlatformHint
                            reassignedExisting += 1
                            reassignedTotal += 1
                        } else {
                            skippedAsExisting += 1
                        }
                    } else {
                        skippedAsExisting += 1
                    }
                    continue
                }
                existingPaths.insert(comparisonItemPath)

                let title = item.deletingPathExtension().lastPathComponent
                let matchedCovers = matchedCoverURLs(
                    for: title,
                    romPath: standardized,
                    candidates: coverCandidates[emulator.id] ?? []
                )
                maxSort += 1
                let game = LibraryGame(
                    title: title,
                    romPath: standardized,
                    emulatorIDString: emulator.id.uuidString,
                    emulator: emulator,
                    platformHint: EmulatorPlatformResolver.resolve(emulator: emulator)?.primaryPlatformHint,
                    sortOrder: maxSort
                )
                applyDetectedCovers(matchedCovers, to: game)
                modelContext.insert(game)
                existingByPath[comparisonItemPath] = game
                added += 1
                addedForEmulator += 1
            }
            DebugLog.log(
                "Scan done: emulator=\(emulator.name) root=\(root.path) scanned=\(scannedFileLikeItems) added=\(addedForEmulator) reassigned=\(reassignedExisting) skipExcluded=\(skippedByExclude) skipExtension=\(skippedByExtension) skipExisting=\(skippedAsExisting)"
            )
        }

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

        if added > 0 || reassignedTotal > 0 || linkedCovers > 0 || autoLinkedDiscSets > 0 || removedMissing > 0 {
            try modelContext.save()
        }
        DebugLog.log(
            "Scan result: added=\(added) reassigned=\(reassignedTotal) linkedCovers=\(linkedCovers) autoLinkedDiscSets=\(autoLinkedDiscSets) removedMissing=\(removedMissing)"
        )
        return ScanSummary(
            added: added,
            reassigned: reassignedTotal,
            linkedCovers: linkedCovers,
            autoLinkedDiscSets: autoLinkedDiscSets,
            removedMissing: removedMissing
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

import AppKit
import Foundation
import SwiftData

/// Background metadata passes: periodically fills missing covers from local folders, ScreenScraper when a user is signed in, then IGDB and finally TheGamesDB (user keys) when that leaves no cover.
@Observable
@MainActor
final class MetadataBackgroundFetcher {
    static let shared = MetadataBackgroundFetcher()
    /// Per-provider tallies for one batch.
    struct ProviderUsage: Sendable {
        var searched = 0
        var covers = 0
        var noMatch = 0
        var ambiguous = 0
        var errors = 0
        var skipped = 0
        /// API calls (TheGamesDB only; each counts against the monthly allowance).
        var requests = 0
        var remainingAllowance: Int?
    }

    struct ScrapeSummary: Sendable {
        var processed: Int
        var updated: Int
        var usage: [CoverProvider: ProviderUsage] = [:]
    }

    private(set) var libraryScrapeInProgress = false
    private(set) var libraryScrapeProcessed = 0
    private(set) var libraryScrapeTotal = 0
    private(set) var libraryScrapeUpdated = 0
    private(set) var libraryScrapeCurrentTitle: String?
    private(set) var lastLibraryScrapeSummary: ScrapeSummary?
    private(set) var lastLibraryScrapeFinishedAt: Date?
    private(set) var lastLibraryScrapeLogPath: String?
    private(set) var backgroundPassInProgress = false
    private(set) var libraryScrapeWaitingForBackground = false

    private var loopTask: Task<Void, Never>?
    private var libraryScrapeTask: Task<Void, Never>?
    private var container: ModelContainer?
    /// Set for the rest of a batch after TheGamesDB returns HTTP 403 (monthly allowance).
    private var theGamesDBPausedForQuota = false
    /// Set for the rest of a batch after Twitch rejects the IGDB keys.
    private var igdbPausedForCredentials = false
    private var providerUsage: [CoverProvider: ProviderUsage] = [:]

    private struct BackupCover {
        var url: URL
        /// Set only when the backup title may replace the library title.
        var title: String?
        var source: String
    }

    private init() {}
    private static let localCoverExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "heic", "bmp", "tif", "tiff", "avif"
    ]
    private static let likelyCoverFolderNames: Set<String> = [
        "cover", "covers", "boxart", "art", "images", "image", "posters", "media"
    ]

    func startIfNeeded(container: ModelContainer) {
        self.container = container
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Run one batch soon (e.g. after a scan adds new games).
    func scheduleExtraPass(container: ModelContainer) {
        Task { @MainActor in
            self.container = container
            _ = await processBatch(container: container, forceAll: false, maxGames: 3, reportLibraryProgress: false)
        }
    }

    /// Starts a user-requested full-library scrape; observe [libraryScrapeInProgress] and counters for UI.
    func startLibraryScrape(container: ModelContainer) {
        guard !libraryScrapeInProgress else { return }
        self.container = container
        libraryScrapeTask?.cancel()
        libraryScrapeInProgress = true
        libraryScrapeProcessed = 0
        libraryScrapeTotal = 0
        libraryScrapeUpdated = 0
        libraryScrapeCurrentTitle = nil
        lastLibraryScrapeSummary = nil
        lastLibraryScrapeLogPath = nil
        libraryScrapeTask = Task { @MainActor in
            defer {
                libraryScrapeInProgress = false
                libraryScrapeWaitingForBackground = false
                libraryScrapeCurrentTitle = nil
                libraryScrapeTask = nil
            }

            if backgroundPassInProgress {
                libraryScrapeWaitingForBackground = true
                while backgroundPassInProgress && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                libraryScrapeWaitingForBackground = false
            }
            guard !Task.isCancelled else { return }
            let summary = await processBatch(
                container: container,
                forceAll: true,
                maxGames: nil,
                reportLibraryProgress: true
            )
            lastLibraryScrapeSummary = summary
            lastLibraryScrapeFinishedAt = Date()
            if let logURL = MetadataScrapeSessionLog.endSession(summary: summary),
               let saved = MetadataScrapeSessionLog.saveCopyToDownloads(from: logURL) {
                lastLibraryScrapeLogPath = saved.path
                NSWorkspace.shared.activateFileViewerSelecting([saved])
            }
        }
    }

    func cancelLibraryScrape() {
        libraryScrapeTask?.cancel()
    }

    /// Clears ScreenScraper cover art and match pins for every library game (for scrape testing).
    func clearAllScrapedMetadata(container: ModelContainer) throws -> Int {
        let context = container.mainContext
        let games = try context.fetch(FetchDescriptor<LibraryGame>())
        var cleared = 0
        for game in games {
            let hadData = game.coverImageURLString != nil
                || game.coverImageOptionsJSON != nil
                || game.screenScraperGameId != nil
                || game.screenScraperSystemId != nil
                || game.metadataLastFetchAt != nil
                || game.screenScraperSelectionSkipped
                || game.remoteCoverSource != nil
                || game.theGamesDBCheckedAt != nil
                || game.igdbCheckedAt != nil
            guard hadData else { continue }
            game.coverImageURLString = nil
            game.coverImageOptionsJSON = nil
            game.screenScraperGameId = nil
            game.screenScraperSystemId = nil
            game.screenScraperSelectionSkipped = false
            game.metadataLastFetchAt = nil
            game.remoteCoverSource = nil
            game.theGamesDBCheckedAt = nil
            game.igdbCheckedAt = nil
            cleared += 1
        }
        try context.save()
        ScreenScraperDisambiguationCoordinator.shared.clearAllPending()
        lastLibraryScrapeSummary = nil
        lastLibraryScrapeFinishedAt = nil
        lastLibraryScrapeLogPath = nil
        return cleared
    }

    /// Legacy await API — prefer [startLibraryScrape] for UI progress.
    func scrapeAllNow(container: ModelContainer) async -> ScrapeSummary {
        self.container = container
        return await processBatch(container: container, forceAll: true, maxGames: nil, reportLibraryProgress: false)
    }

    private func runLoop() async {
        while !Task.isCancelled {
            if let c = container, !libraryScrapeInProgress {
                backgroundPassInProgress = true
                defer { backgroundPassInProgress = false }
                _ = await processBatch(container: c, forceAll: false, maxGames: 3, reportLibraryProgress: false)
            }
            try? await Task.sleep(for: .seconds(45))
        }
    }

    private func processBatch(
        container: ModelContainer,
        forceAll: Bool,
        maxGames: Int?,
        reportLibraryProgress: Bool
    ) async -> ScrapeSummary {
        theGamesDBPausedForQuota = false
        igdbPausedForCredentials = false
        providerUsage = [:]
        let context = container.mainContext
        var descriptor = FetchDescriptor<LibraryGame>(sortBy: [SortDescriptor(\.sortOrder)])
        descriptor.fetchLimit = forceAll ? 0 : 250

        let games = (try? context.fetch(descriptor)) ?? []
        let now = Date()
        let retryInterval: TimeInterval = 24 * 3600

        let onlyScanMissing = forceAll && MetadataCredentials.screenScraperOnlyScanMissing
        let candidates = games.filter { g in
            if g.storefront != nil, g.coverImageURLString != nil { return false }
            if forceAll {
                if onlyScanMissing, g.hasScreenScraperCover { return false }
                return true
            }
            if let t = g.metadataLastFetchAt {
                return now.timeIntervalSince(t) > retryInterval
            }
            return true
        }

        let selectedCandidates: [LibraryGame]
        if let maxGames {
            selectedCandidates = Array(candidates.prefix(maxGames))
        } else {
            selectedCandidates = candidates
        }

        if reportLibraryProgress {
            relinkEmulators(in: selectedCandidates, context: context)
            libraryScrapeTotal = selectedCandidates.count
            libraryScrapeProcessed = 0
            libraryScrapeUpdated = 0
            MetadataScrapeSessionLog.startSession(
                totalGames: selectedCandidates.count,
                preferredRegion: MetadataCredentials.screenScraperRegionPriority.joined(separator: ",")
            )
            if onlyScanMissing {
                let skipped = games.count - selectedCandidates.count
                if skipped > 0 {
                    MetadataScrapeSessionLog.i(
                        "only_scan_missing skipped=\(skipped) remaining=\(selectedCandidates.count)"
                    )
                }
            }
        }

        var processed = 0
        var updated = 0
        for game in selectedCandidates {
            if Task.isCancelled { break }
            if reportLibraryProgress {
                libraryScrapeCurrentTitle = game.libraryListTitle
            }
            processed += 1
            if await fetchAndSave(
                gameID: game.id,
                container: container,
                logToSession: reportLibraryProgress,
                allowBackupRetry: forceAll
            ) {
                updated += 1
            }
            if reportLibraryProgress {
                libraryScrapeProcessed = processed
                libraryScrapeUpdated = updated
            }
            try? await Task.sleep(for: .milliseconds(450))
        }
        return ScrapeSummary(processed: processed, updated: updated, usage: providerUsage)
    }

    private func recordUsage(_ provider: CoverProvider, _ update: (inout ProviderUsage) -> Void) {
        update(&providerUsage[provider, default: ProviderUsage()])
    }

    private func fetchAndSave(
        gameID: UUID,
        container: ModelContainer,
        logToSession: Bool = false,
        allowBackupRetry: Bool = false
    ) async -> Bool {
        let context = container.mainContext
        var desc = FetchDescriptor<LibraryGame>(predicate: #Predicate { $0.id == gameID })
        desc.fetchLimit = 1
        guard let game = try? context.fetch(desc).first else { return false }

        let romStem = URL(fileURLWithPath: game.romPath).deletingPathExtension().lastPathComponent
        let searchTitle = game.libraryListTitle
        let emulator = EmulatorProfileLookup.resolve(for: game, context: context)
        let preferScreenScraper = emulator?.preferScreenScraperCovers == true
        let emulatorSystemId = MetadataSystemResolver.systemId(for: game, emulator: emulator)
        let localCoverURL = localCoverForGame(path: game.romPath, title: searchTitle, romStem: romStem)
        var remoteResult: MetadataResult?
        var awaitingDisambiguation = false
        if MetadataCredentials.hasUserCredentials && MetadataCredentials.isConfigured {
            recordUsage(.screenScraper) { $0.searched += 1 }
            do {
                if let outcome = try await MetadataService.fetchMetadata(
                    libraryGameId: game.id,
                    displayTitle: searchTitle,
                    romFileNameStem: romStem,
                    romPath: game.romPath,
                    emulatorSystemId: emulatorSystemId,
                    pinnedGameId: game.screenScraperGameId,
                    pinnedSystemId: game.screenScraperSystemId,
                    selectionSkipped: game.screenScraperSelectionSkipped
                ) {
                    switch outcome {
                    case .resolved(let result):
                        remoteResult = result
                        recordUsage(.screenScraper) { usage in
                            if result.coverImageURL != nil { usage.covers += 1 } else { usage.noMatch += 1 }
                        }
                        if logToSession {
                            let coverNote = result.coverImageURL?.absoluteString ?? "none"
                            let mode = result.autoResolvedAmbiguity ? "auto_ambiguous" : "resolved"
                            MetadataScrapeSessionLog.i(
                                "\(mode) method=\(result.matchMethod.rawValue) title=\(searchTitle) " +
                                    "query=\(MetadataService.searchQuery(displayTitle: searchTitle, romFileNameStem: romStem)) " +
                                    "emulatorSystemeid=\(emulatorSystemId.map(String.init) ?? "nil") " +
                                    "systemeid=\(result.screenScraperSystemId.map(String.init) ?? "nil") pick=\(result.normalizedTitle) cover=\(coverNote)"
                            )
                        }
                    case .needsDisambiguation(let request):
                        awaitingDisambiguation = true
                        recordUsage(.screenScraper) { $0.ambiguous += 1 }
                        ScreenScraperDisambiguationCoordinator.shared.enqueue(request)
                        if logToSession {
                            MetadataScrapeSessionLog.w(
                                "ambiguous title=\(searchTitle) emulatorSystemeid=\(emulatorSystemId.map(String.init) ?? "nil") " +
                                    "candidates=\(request.candidates.count) " +
                                    "systems=\(Set(request.candidates.map(\.systemName)).sorted().joined(separator: ", "))"
                            )
                        }
                    case .unavailable:
                        recordUsage(.screenScraper) { $0.noMatch += 1 }
                        if logToSession {
                            MetadataScrapeSessionLog.w(
                                "no_match title=\(searchTitle) emulatorSystemeid=\(emulatorSystemId.map(String.init) ?? "nil")"
                            )
                        }
                    }
                } else {
                    recordUsage(.screenScraper) { $0.skipped += 1 }
                    if logToSession {
                        MetadataScrapeSessionLog.w("skipped title=\(searchTitle) reason=credentials_not_configured")
                    }
                }
            } catch {
                recordUsage(.screenScraper) { $0.errors += 1 }
                if logToSession {
                    MetadataScrapeSessionLog.e("error title=\(searchTitle) message=\(error.localizedDescription)")
                }
            }
        } else {
            recordUsage(.screenScraper) { $0.skipped += 1 }
            if logToSession {
                let reason = MetadataCredentials.hasUserCredentials ? "credentials_not_configured" : "no_user_login"
                MetadataScrapeSessionLog.i("screenscraper_skipped title=\(searchTitle) reason=\(reason)")
            }
        }

        var backupCover: BackupCover?
        if remoteResult?.coverImageURL == nil, !awaitingDisambiguation {
            let slugs = EmulatorPlatformResolver.resolve(emulator: emulator)?.gbearPlatformSlugs ?? []
            let query = MetadataService.searchQuery(displayTitle: searchTitle, romFileNameStem: romStem)
            if shouldQueryBackup(
                .igdb,
                game: game,
                hasKey: MetadataCredentials.hasIGDBCredentials,
                paused: igdbPausedForCredentials,
                checkedAt: game.igdbCheckedAt,
                allowRetry: allowBackupRetry
            ) {
                backupCover = await queryIGDB(
                    game: game,
                    query: query,
                    slugs: slugs,
                    emulatorSystemId: emulatorSystemId,
                    searchTitle: searchTitle,
                    logToSession: logToSession
                )
            }
            if backupCover == nil,
               shouldQueryBackup(
                   .theGamesDB,
                   game: game,
                   hasKey: MetadataCredentials.hasTheGamesDBAPIKey,
                   paused: theGamesDBPausedForQuota,
                   checkedAt: game.theGamesDBCheckedAt,
                   allowRetry: allowBackupRetry
               ) {
                backupCover = await queryTheGamesDB(
                    game: game,
                    query: query,
                    slugs: slugs,
                    emulatorSystemId: emulatorSystemId,
                    searchTitle: searchTitle,
                    logToSession: logToSession
                )
            }
        }

        var didChange = false

        if let ids = remoteResult?.screenScraperGameId {
            if game.screenScraperGameId != ids {
                game.screenScraperGameId = ids
                didChange = true
            }
        }
        if let systemId = remoteResult?.screenScraperSystemId {
            if game.screenScraperSystemId != systemId {
                game.screenScraperSystemId = systemId
                didChange = true
            }
        }

        let searchQuery = MetadataService.searchQuery(displayTitle: searchTitle, romFileNameStem: romStem)
        if let normalized = remoteResult?.normalizedTitle.trimmingCharacters(in: .whitespacesAndNewlines),
           !normalized.isEmpty,
           game.title != normalized,
           MetadataService.shouldApplyScrapedTitle(
               searchQuery: searchQuery,
               pickedTitle: normalized,
               matchMethod: remoteResult?.matchMethod ?? .search
           ) {
            game.title = normalized
            didChange = true
        } else if remoteResult == nil,
                  let normalized = backupCover?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !normalized.isEmpty,
                  game.title != normalized,
                  MetadataService.backupTitleMatches(searchQuery: searchQuery, candidate: normalized) {
            game.title = normalized
            didChange = true
        }

        var options = game.coverImageOptions
        if let localCoverURL {
            let localCandidate = localCoverURL.absoluteString
            if !options.contains(localCandidate) {
                options.insert(localCandidate, at: 0)
                didChange = true
            }
        }
        var cachedRemotePrimary: String?
        let remoteCoverString = remoteResult?.coverImageURL?.absoluteString ?? backupCover?.url.absoluteString
        let remoteCoverSource = remoteResult?.coverImageURL != nil ? "screenscraper" : backupCover?.source
        if let remoteCoverString {
            cachedRemotePrimary = await CoverImageCache.persistCoverReference(remoteCoverString)
            if let remoteCandidate = cachedRemotePrimary, !options.contains(remoteCandidate) {
                options.append(remoteCandidate)
                didChange = true
            }
            if let remoteCoverSource, game.remoteCoverSource != remoteCoverSource {
                game.remoteCoverSource = remoteCoverSource
                didChange = true
            }
        }

        let priorPrimary = game.coverImageURLString
        game.coverImageOptions = options

        let hasPrimaryCover = !(game.coverImageURLString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        let preferredPrimary: String? = {
            if preferScreenScraper {
                if let remote = cachedRemotePrimary { return remote }
                if let local = localCoverURL?.absoluteString { return local }
            } else {
                if let local = localCoverURL?.absoluteString { return local }
                if let remote = cachedRemotePrimary { return remote }
            }
            if !hasPrimaryCover, let remote = cachedRemotePrimary {
                return remote
            }
            return game.coverImageURLString
        }()

        if let preferredPrimary, preferredPrimary != game.coverImageURLString {
            game.coverImageURLString = preferredPrimary
            didChange = true
        }

        game.metadataLastFetchAt = Date()
        if priorPrimary != game.coverImageURLString {
            didChange = true
        }
        if didChange {
            DiscGroupService.propagateSharedState(from: game, context: context)
            try? context.save()
        } else {
            try? context.save()
        }
        return didChange
    }

    private func shouldQueryBackup(
        _ provider: CoverProvider,
        game: LibraryGame,
        hasKey: Bool,
        paused: Bool,
        checkedAt: Date?,
        allowRetry: Bool
    ) -> Bool {
        guard hasKey else { return false }
        if paused {
            recordUsage(provider) { $0.skipped += 1 }
            return false
        }
        if game.hasScreenScraperCover, !allowRetry { return false }
        if checkedAt != nil, !allowRetry { return false }
        return true
    }

    private func queryTheGamesDB(
        game: LibraryGame,
        query: String,
        slugs: [String],
        emulatorSystemId: Int?,
        searchTitle: String,
        logToSession: Bool
    ) async -> BackupCover? {
        guard let platformFilter = TheGamesDBPlatformMap.platformFilter(
            gbearSlugs: slugs,
            screenScraperSystemId: emulatorSystemId
        ) else {
            recordUsage(.theGamesDB) { $0.skipped += 1 }
            if logToSession {
                MetadataScrapeSessionLog.w(
                    "thegamesdb_skipped title=\(searchTitle) reason=no_platform emulatorSystemeid=\(emulatorSystemId.map(String.init) ?? "nil")"
                )
            }
            return nil
        }

        recordUsage(.theGamesDB) { $0.searched += 1 }
        do {
            let found = try await TheGamesDBClient.searchFrontCover(
                name: query,
                platformFilter: platformFilter,
                regionPriority: MetadataCredentials.screenScraperRegionPriority
            )
            game.theGamesDBCheckedAt = Date()
            recordUsage(.theGamesDB) { usage in
                usage.requests += found.requests
                if let remaining = found.remainingMonthlyAllowance { usage.remainingAllowance = remaining }
                if found.match != nil { usage.covers += 1 } else { usage.noMatch += 1 }
            }
            let allowance = found.remainingMonthlyAllowance.map(String.init) ?? "nil"
            if let allowanceValue = found.remainingMonthlyAllowance, allowanceValue <= 0 {
                theGamesDBPausedForQuota = true
                if logToSession {
                    MetadataScrapeSessionLog.w("thegamesdb_quota_exhausted")
                }
            }
            guard let match = found.match else {
                if logToSession {
                    MetadataScrapeSessionLog.w(
                        "thegamesdb_no_match title=\(searchTitle) query=\(query) platform=\(platformFilter) allowance=\(allowance)"
                    )
                }
                return nil
            }
            if logToSession {
                MetadataScrapeSessionLog.i(
                    "thegamesdb title=\(searchTitle) query=\(query) platform=\(platformFilter) " +
                        "region=\(match.regionCode ?? "unspecified") pick=\(match.title) gameid=\(match.gameId) " +
                        "cover=\(match.coverURL.absoluteString) allowance=\(allowance)"
                )
            }
            return BackupCover(
                url: match.coverURL,
                title: match.replacesLibraryTitle ? match.title : nil,
                source: "thegamesdb"
            )
        } catch {
            recordUsage(.theGamesDB) { usage in
                usage.errors += 1
                usage.requests += 1
            }
            if case TheGamesDBClient.TheGamesDBError.quota = error {
                theGamesDBPausedForQuota = true
                recordUsage(.theGamesDB) { $0.remainingAllowance = 0 }
            }
            if logToSession {
                MetadataScrapeSessionLog.e("thegamesdb_error title=\(searchTitle) message=\(error.localizedDescription)")
            }
            return nil
        }
    }

    private func queryIGDB(
        game: LibraryGame,
        query: String,
        slugs: [String],
        emulatorSystemId: Int?,
        searchTitle: String,
        logToSession: Bool
    ) async -> BackupCover? {
        guard let platformFilter = IGDBPlatformMap.platformFilter(
            gbearSlugs: slugs,
            screenScraperSystemId: emulatorSystemId
        ) else {
            recordUsage(.igdb) { $0.skipped += 1 }
            if logToSession {
                MetadataScrapeSessionLog.w(
                    "igdb_skipped title=\(searchTitle) reason=no_platform emulatorSystemeid=\(emulatorSystemId.map(String.init) ?? "nil")"
                )
            }
            return nil
        }

        recordUsage(.igdb) { $0.searched += 1 }
        do {
            let match = try await IGDBClient.searchFrontCover(
                name: query,
                platformFilter: platformFilter,
                regionPriority: MetadataCredentials.screenScraperRegionPriority
            )
            game.igdbCheckedAt = Date()
            recordUsage(.igdb) { usage in
                if match != nil { usage.covers += 1 } else { usage.noMatch += 1 }
            }
            guard let match else {
                if logToSession {
                    MetadataScrapeSessionLog.w("igdb_no_match title=\(searchTitle) query=\(query) platform=\(platformFilter)")
                }
                return nil
            }
            if logToSession {
                MetadataScrapeSessionLog.i(
                    "igdb title=\(searchTitle) query=\(query) platform=\(platformFilter) " +
                        "region=\(match.regionCode ?? "main") pick=\(match.title) gameid=\(match.gameId) " +
                        "cover=\(match.coverURL.absoluteString)"
                )
            }
            return BackupCover(
                url: match.coverURL,
                title: match.replacesLibraryTitle ? match.title : nil,
                source: "igdb"
            )
        } catch {
            recordUsage(.igdb) { $0.errors += 1 }
            if case IGDBClient.IGDBError.credentialsRejected = error {
                igdbPausedForCredentials = true
            }
            if logToSession {
                MetadataScrapeSessionLog.e("igdb_error title=\(searchTitle) message=\(error.localizedDescription)")
            }
            return nil
        }
    }

    private func relinkEmulators(in games: [LibraryGame], context: ModelContext) {
        for game in games {
            _ = EmulatorProfileLookup.resolve(for: game, context: context)
        }
        try? context.save()
    }

    private func localCoverForGame(path: String, title: String, romStem: String) -> URL? {
        let gameURL = URL(fileURLWithPath: (path as NSString).standardizingPath)
        let gameDir = gameURL.hasDirectoryPath ? gameURL : gameURL.deletingLastPathComponent()
        let candidateDirectories = coverSearchDirectories(startingAt: gameDir)
        let targetTokens = searchableTokens(from: title + " " + romStem)
        let fallbackStem = romStem.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !targetTokens.isEmpty || !fallbackStem.isEmpty else { return nil }

        let fm = FileManager.default
        var best: (score: Int, url: URL)?
        for directory in candidateDirectories {
            guard let items = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in items {
                let ext = item.pathExtension.lowercased()
                guard Self.localCoverExtensions.contains(ext) else { continue }
                let stem = item.deletingPathExtension().lastPathComponent
                let stemTokens = searchableTokens(from: stem)
                var score = 0
                if !targetTokens.isEmpty {
                    let overlap = targetTokens.intersection(stemTokens).count
                    score += overlap * 10
                }
                if !fallbackStem.isEmpty, stem.lowercased().contains(fallbackStem) {
                    score += 8
                }
                if score <= 0 { continue }

                if let best, best.score >= score { continue }
                best = (score, item)
            }
        }
        return best?.url
    }

    private func coverSearchDirectories(startingAt gameDirectory: URL) -> [URL] {
        var directories: [URL] = []
        var current = gameDirectory
        let fm = FileManager.default

        for _ in 0..<3 {
            directories.append(current)
            if let children = try? fm.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for child in children {
                    let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    guard isDirectory else { continue }
                    let name = child.lastPathComponent.lowercased()
                    if Self.likelyCoverFolderNames.contains(name) {
                        directories.append(child)
                    }
                }
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return directories
    }

    private func searchableTokens(from raw: String) -> Set<String> {
        let cleaned = raw.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        return Set(
            String(cleaned)
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter { $0.count >= 3 }
        )
    }
}

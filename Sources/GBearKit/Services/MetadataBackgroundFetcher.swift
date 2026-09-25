import AppKit
import Foundation
import SwiftData

/// Background metadata passes: periodically fills missing covers from local folders and ScreenScraper when credentials are set.
@Observable
@MainActor
final class MetadataBackgroundFetcher {
    static let shared = MetadataBackgroundFetcher()
    struct ScrapeSummary: Sendable {
        var processed: Int
        var updated: Int
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
            guard hadData else { continue }
            game.coverImageURLString = nil
            game.coverImageOptionsJSON = nil
            game.screenScraperGameId = nil
            game.screenScraperSystemId = nil
            game.screenScraperSelectionSkipped = false
            game.metadataLastFetchAt = nil
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
        let context = container.mainContext
        var descriptor = FetchDescriptor<LibraryGame>(sortBy: [SortDescriptor(\.sortOrder)])
        descriptor.fetchLimit = forceAll ? 0 : 250

        let games = (try? context.fetch(descriptor)) ?? []
        let now = Date()
        let retryInterval: TimeInterval = 24 * 3600

        let onlyScanMissing = forceAll && MetadataCredentials.screenScraperOnlyScanMissing
        let candidates = games.filter { g in
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
                preferredRegion: MetadataCredentials.screenScraperPreferredRegion
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
            if await fetchAndSave(gameID: game.id, container: container, logToSession: reportLibraryProgress) {
                updated += 1
            }
            if reportLibraryProgress {
                libraryScrapeProcessed = processed
                libraryScrapeUpdated = updated
            }
            try? await Task.sleep(for: .milliseconds(450))
        }
        return ScrapeSummary(processed: processed, updated: updated)
    }

    private func fetchAndSave(gameID: UUID, container: ModelContainer, logToSession: Bool = false) async -> Bool {
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
        if MetadataCredentials.isConfigured {
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
                        ScreenScraperDisambiguationCoordinator.shared.enqueue(request)
                        if logToSession {
                            MetadataScrapeSessionLog.w(
                                "ambiguous title=\(searchTitle) emulatorSystemeid=\(emulatorSystemId.map(String.init) ?? "nil") " +
                                    "candidates=\(request.candidates.count) " +
                                    "systems=\(Set(request.candidates.map(\.systemName)).sorted().joined(separator: ", "))"
                            )
                        }
                    case .unavailable:
                        if logToSession {
                            MetadataScrapeSessionLog.w(
                                "no_match title=\(searchTitle) emulatorSystemeid=\(emulatorSystemId.map(String.init) ?? "nil")"
                            )
                        }
                    }
                } else if logToSession {
                    MetadataScrapeSessionLog.w("skipped title=\(searchTitle) reason=credentials_not_configured")
                }
            } catch {
                if logToSession {
                    MetadataScrapeSessionLog.e("error title=\(searchTitle) message=\(error.localizedDescription)")
                }
            }
        } else if logToSession {
            MetadataScrapeSessionLog.w("skipped title=\(searchTitle) reason=credentials_not_configured")
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

        if let normalized = remoteResult?.normalizedTitle.trimmingCharacters(in: .whitespacesAndNewlines),
           !normalized.isEmpty,
           game.title != normalized,
           MetadataService.shouldApplyScrapedTitle(
               searchQuery: MetadataService.searchQuery(displayTitle: searchTitle, romFileNameStem: romStem),
               pickedTitle: normalized,
               matchMethod: remoteResult?.matchMethod ?? .search
           ) {
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
        if let remote = remoteResult?.coverImageURL?.absoluteString {
            cachedRemotePrimary = await CoverImageCache.persistCoverReference(remote)
            if let remoteCandidate = cachedRemotePrimary, !options.contains(remoteCandidate) {
                options.append(remoteCandidate)
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

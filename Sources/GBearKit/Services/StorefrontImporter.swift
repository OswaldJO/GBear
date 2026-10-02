import Foundation
import Observation
import SwiftData

/// Imports enabled storefronts into the library: installed games from disk, plus every owned game when signed in.
@Observable
@MainActor
final class StorefrontImporter {
    static let shared = StorefrontImporter()

    struct Summary: Sendable {
        var added = 0
        var updated = 0
        var removed = 0
        var skippedBlocked = 0
        var errors: [String] = []

        var hasChanges: Bool { added > 0 || updated > 0 || removed > 0 }

        /// Sentence fragments for the Scan Paths / import alert.
        var feedbackParts: [String] {
            var parts: [String] = []
            if added > 0 { parts.append("Imported \(added) storefront game(s)") }
            if updated > 0 { parts.append("Updated \(updated) storefront game(s)") }
            if removed > 0 { parts.append("Removed \(removed) storefront game(s) no longer installed or owned") }
            if skippedBlocked > 0 { parts.append("Skipped \(skippedBlocked) blocked storefront game(s)") }
            parts.append(contentsOf: errors)
            return parts
        }
    }

    private(set) var isImporting = false
    private(set) var status: String?
    private(set) var lastSummary: Summary?
    private(set) var lastImportAt: Date?

    private init() {}

    static func placeholderPath(store: Storefront, gameID: String) -> String {
        switch store {
        case .steam: return "steam://rungameid/\(gameID)"
        case .gog: return "goggalaxy://openGameView/\(gameID)"
        case .epic: return "com.epicgames.launcher://apps/\(gameID)?action=launch&silent=true"
        }
    }

    @discardableResult
    func importAll(modelContext: ModelContext) async -> Summary {
        guard !isImporting else { return Summary() }
        isImporting = true
        defer {
            isImporting = false
            status = nil
        }
        var summary = Summary()
        var coverJobs: [(UUID, Storefront, String)] = []
        for store in Storefront.allCases where StorefrontSettings.shared.isEnabled(store) {
            status = "Importing \(store.displayName)…"
            await importStore(store, modelContext: modelContext, summary: &summary, coverJobs: &coverJobs)
        }
        try? modelContext.save()
        lastSummary = summary
        lastImportAt = Date()
        let container = modelContext.container
        if !coverJobs.isEmpty {
            Task { await Self.resolveCovers(coverJobs, container: container) }
        }
        Task { await fillMissingPlatforms(container: container) }
        return summary
    }

    /// Steam / GOG games still waiting for a supported-systems lookup; 0 when idle.
    private(set) var platformChecksRemaining = 0

    /// Looks up supported systems for Steam and GOG games that don't have them yet, so the "works on Mac" filter
    /// can act on the whole library. Steam's store API allows roughly 200 requests per 5 minutes, so Steam lookups are spaced out.
    func fillMissingPlatforms(container: ModelContainer) async {
        guard platformChecksRemaining == 0 else { return }
        let context = container.mainContext
        let pending: [(UUID, Storefront, String)] = ((try? context.fetch(FetchDescriptor<LibraryGame>())) ?? [])
            .compactMap { game in
                guard game.storefrontPlatforms == nil,
                      let store = game.storefront, store != .epic,
                      let gameID = game.storefrontGameID else { return nil }
                return (game.id, store, gameID)
            }
        platformChecksRemaining = pending.count
        defer { platformChecksRemaining = 0 }
        for (index, job) in pending.enumerated() {
            if index > 0 { try? await Task.sleep(for: .seconds(job.1 == .steam ? 1.5 : 0.3)) }
            defer { platformChecksRemaining = pending.count - index - 1 }
            guard let platforms = await StorefrontPlatformLookup.platforms(store: job.1, gameID: job.2) else { continue }
            let id = job.0
            var descriptor = FetchDescriptor<LibraryGame>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let game = try? context.fetch(descriptor).first else { continue }
            game.platforms = platforms
            if index % 10 == 9 { try? context.save() }
        }
        try? context.save()
    }

    private func importStore(
        _ store: Storefront,
        modelContext: ModelContext,
        summary: inout Summary,
        coverJobs: inout [(UUID, Storefront, String)]
    ) async {
        let allGames = (try? modelContext.fetch(FetchDescriptor<LibraryGame>())) ?? []
        let existing = allGames.filter { $0.storefront == store }
        var byID: [String: LibraryGame] = [:]
        for game in existing {
            if let id = game.storefrontGameID ?? (store == .epic ? game.epicAppName : nil) {
                byID[id] = game
            }
        }

        let installed: [StorefrontGame]
        switch store {
        case .steam: installed = SteamClient.installedGames()
        case .gog: installed = GOGClient.installedGames()
        case .epic: installed = EpicClient.installedGames()
        }

        let signedIn = StorefrontCredentials.isSignedIn(store)
        var owned: [StorefrontGame] = []
        var ownedIDs: Set<String>?
        if signedIn {
            do {
                switch store {
                case .steam:
                    owned = try await SteamClient.ownedGames()
                    ownedIDs = Set(owned.map(\.gameID))
                case .gog:
                    owned = try await GOGClient.ownedGames()
                    ownedIDs = Set(owned.map(\.gameID))
                case .epic:
                    let result = try await EpicClient.ownedGames(knownAppNames: Set(byID.keys))
                    owned = result.games
                    ownedIDs = result.ownedAppNames
                }
            } catch {
                summary.errors.append("\(store.displayName): \(error.localizedDescription)")
            }
        }

        var merged: [String: StorefrontGame] = [:]
        for game in owned { merged[game.gameID] = game }
        for game in installed {
            var entry = game
            if entry.coverURL == nil { entry.coverURL = merged[game.gameID]?.coverURL }
            if entry.platforms == nil { entry.platforms = merged[game.gameID]?.platforms }
            if let ownedTitle = merged[game.gameID]?.title, store == .epic { entry.title = ownedTitle }
            merged[game.gameID] = entry
        }

        let blocked = LibraryBlocklist.blockedKeys
        var maxSort = allGames.map(\.sortOrder).max() ?? -1
        var touchedIDs = Set<String>()

        for game in merged.values {
            touchedIDs.insert(game.gameID)
            let path = game.installPath ?? Self.placeholderPath(store: store, gameID: game.gameID)
            if let row = byID[game.gameID] ?? legacyMatch(existing, path: game.installPath) {
                if apply(game, path: path, to: row) { summary.updated += 1 }
                continue
            }
            let identity = LibraryBlocklist.comparisonKey(store.blocklistIdentity(gameID: game.gameID))
            if blocked.contains(identity) || blocked.contains(LibraryBlocklist.comparisonKey(path)) {
                summary.skippedBlocked += 1
                continue
            }
            maxSort += 1
            let row = LibraryGame(
                title: game.title,
                romPath: path,
                coverImageURLString: game.coverURL?.absoluteString,
                platformHint: "PC",
                librarySourceID: store.rawValue,
                epicAppName: store == .epic ? game.gameID : nil,
                sortOrder: maxSort,
                metadataLastFetchAt: Date()
            )
            row.storefrontGameID = game.gameID
            row.storefrontInstalled = game.installed
            row.platforms = game.platforms
            modelContext.insert(row)
            byID[game.gameID] = row
            summary.added += 1
            if store != .epic { coverJobs.append((row.id, store, game.gameID)) }
        }

        for (id, row) in byID where !touchedIDs.contains(id) {
            let stillOwned = ownedIDs?.contains(id) == true
            let ownershipUnknown = signedIn && ownedIDs == nil
            if stillOwned || ownershipUnknown {
                if row.storefrontInstalled != false {
                    row.storefrontInstalled = false
                    row.romPath = Self.placeholderPath(store: store, gameID: id)
                    summary.updated += 1
                }
            } else {
                modelContext.delete(row)
                summary.removed += 1
            }
        }
    }

    /// Games imported before storefront ids existed (Epic installs keyed only by path).
    private func legacyMatch(_ rows: [LibraryGame], path: String?) -> LibraryGame? {
        guard let path else { return nil }
        let key = LibraryBlocklist.comparisonKey(path)
        return rows.first { $0.storefrontGameID == nil && LibraryBlocklist.comparisonKey($0.romPath) == key }
    }

    private func apply(_ game: StorefrontGame, path: String, to row: LibraryGame) -> Bool {
        var changed = false
        func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<LibraryGame, T>, _ value: T) {
            if row[keyPath: keyPath] != value {
                row[keyPath: keyPath] = value
                changed = true
            }
        }
        set(\.title, game.title)
        set(\.romPath, path)
        set(\.storefrontGameID, Optional(game.gameID))
        set(\.storefrontInstalled, Optional(game.installed))
        set(\.librarySourceID, Optional(game.store.rawValue))
        if game.store == .epic { set(\.epicAppName, Optional(game.gameID)) }
        if let platforms = game.platforms, row.platforms != platforms {
            row.platforms = platforms
            changed = true
        }
        if row.emulatorIDString != nil || row.emulator != nil {
            row.emulatorIDString = nil
            row.emulator = nil
            changed = true
        }
        if row.coverImageURLString == nil, let cover = game.coverURL?.absoluteString {
            row.coverImageURLString = cover
            changed = true
        }
        return changed
    }

    // MARK: Covers

    /// Portrait art for new Steam / GOG rows: Steam falls back to the header image when there is no library capsule;
    /// GOG prefers the games-database vertical cover over the landscape product image.
    private static func resolveCovers(_ jobs: [(UUID, Storefront, String)], container: ModelContainer) async {
        let resolved = await withTaskGroup(of: (UUID, URL?).self) { group in
            var results: [(UUID, URL?)] = []
            var iterator = jobs.makeIterator()
            for _ in 0 ..< 6 {
                guard let job = iterator.next() else { break }
                group.addTask { (job.0, await coverURL(store: job.1, gameID: job.2)) }
            }
            while let result = await group.next() {
                results.append(result)
                if let job = iterator.next() {
                    group.addTask { (job.0, await coverURL(store: job.1, gameID: job.2)) }
                }
            }
            return results
        }
        let context = container.mainContext
        for (id, url) in resolved {
            guard let url else { continue }
            var descriptor = FetchDescriptor<LibraryGame>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let game = try? context.fetch(descriptor).first else { continue }
            game.coverImageOptions = [url.absoluteString]
            game.coverImageURLString = url.absoluteString
        }
        try? context.save()
    }

    private nonisolated static func coverURL(store: Storefront, gameID: String) async -> URL? {
        switch store {
        case .steam:
            guard let portrait = SteamClient.coverURL(appID: gameID) else { return nil }
            var request = URLRequest(url: portrait)
            request.httpMethod = "HEAD"
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return nil
            }
            return SteamClient.fallbackCoverURL(appID: gameID)
        case .gog:
            return await GOGClient.verticalCoverURL(productID: gameID)
        case .epic:
            return nil
        }
    }
}

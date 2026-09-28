import Foundation
import SwiftData

/// Queues ScreenScraper matches that need the user to pick a console/release.
@Observable
@MainActor
final class ScreenScraperDisambiguationCoordinator {
    static let shared = ScreenScraperDisambiguationCoordinator()

    private(set) var pending: [ScreenScraperDisambiguationRequest] = []

    private init() {}

    var hasPending: Bool { !pending.isEmpty }

    func enqueue(_ request: ScreenScraperDisambiguationRequest) {
        guard !request.candidates.isEmpty else { return }
        guard !pending.contains(where: { $0.libraryGameId == request.libraryGameId }) else { return }
        pending.append(request)
    }

    func remove(libraryGameId: UUID) {
        pending.removeAll { $0.libraryGameId == libraryGameId }
    }

    func clearAllPending() {
        pending.removeAll()
    }

    func applySelection(
        libraryGameId: UUID,
        match: ScreenScraperGameMatch,
        container: ModelContainer,
        forcePrimaryCover: Bool = false
    ) {
        Task { @MainActor in
            let context = container.mainContext
            var desc = FetchDescriptor<LibraryGame>(predicate: #Predicate { $0.id == libraryGameId })
            desc.fetchLimit = 1
            guard let game = try? context.fetch(desc).first else { return }

            game.screenScraperGameId = match.gameId
            game.screenScraperSystemId = match.systemId
            game.screenScraperSelectionSkipped = false
            if !match.title.isEmpty,
               MetadataService.shouldApplyScrapedTitle(
                   searchQuery: MetadataService.searchQuery(
                       displayTitle: game.libraryListTitle,
                       romFileNameStem: URL(fileURLWithPath: game.romPath).deletingPathExtension().lastPathComponent
                   ),
                   pickedTitle: match.title,
                   matchMethod: .search
               ) {
                game.title = match.title
            }
            if let cover = match.coverURL?.absoluteString {
                let persisted = await CoverImageCache.persistCoverReference(cover)
                var options = game.coverImageOptions
                if !options.contains(persisted) {
                    options.append(persisted)
                    game.coverImageOptions = options
                }
                let preferRemote = game.emulator?.preferScreenScraperCovers == true
                if forcePrimaryCover || preferRemote || game.coverImageURLString == nil {
                    game.coverImageURLString = persisted
                    game.remoteCoverSource = CoverProvider.screenScraper.rawValue
                }
            }
            game.metadataLastFetchAt = Date()
            DiscGroupService.propagateSharedState(from: game, context: context)
            try? context.save()
            remove(libraryGameId: libraryGameId)
        }
    }

    func skipSelection(libraryGameId: UUID, container: ModelContainer) {
        let context = container.mainContext
        var desc = FetchDescriptor<LibraryGame>(predicate: #Predicate { $0.id == libraryGameId })
        desc.fetchLimit = 1
        guard let game = try? context.fetch(desc).first else { return }
        game.screenScraperSelectionSkipped = true
        game.metadataLastFetchAt = Date()
        try? context.save()
        remove(libraryGameId: libraryGameId)
    }
}

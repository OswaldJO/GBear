import SwiftData
import SwiftUI

/// One hit from manual cover search.
struct CoverSearchResult: Sendable, Identifiable {
    var id: String { "\(provider.rawValue)-\(gameId)" }
    let provider: CoverProvider
    let gameId: Int
    let title: String
    let platformName: String?
    let regionCode: String?
    let coverURL: URL?
    /// Set for ScreenScraper hits so choosing one also pins the ScreenScraper game.
    let screenScraperMatch: ScreenScraperGameMatch?
}

/// Manual cover search across every provider that is set up (title, platform, cover region).
struct CoverSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let libraryGameId: UUID
    let initialTitle: String
    let initialSystemId: Int?

    private struct ProviderSection: Sendable, Identifiable {
        var id: String { provider.rawValue }
        let provider: CoverProvider
        let results: [CoverSearchResult]
        let message: String?
    }

    @State private var searchTitle: String
    @State private var selectedSystemId: Int?
    @State private var selectedCoverRegion: String
    @State private var sections: [ProviderSection] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    private let anyPlatformSentinel = -1
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    init(libraryGameId: UUID, initialTitle: String, initialSystemId: Int?) {
        self.libraryGameId = libraryGameId
        self.initialTitle = initialTitle
        self.initialSystemId = initialSystemId
        _searchTitle = State(initialValue: RomTitleNormalizer.strippingTrailingParentheticalTags(initialTitle))
        _selectedSystemId = State(initialValue: initialSystemId)
        _selectedCoverRegion = State(initialValue: MetadataCredentials.screenScraperPreferredRegion)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    searchForm
                    if isSearching {
                        HStack {
                            ProgressView()
                            Text("Searching \(CoverProvider.configured.map(\.displayName).joined(separator: ", "))…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    ForEach(sections) { section in
                        providerSection(section)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Search for Covers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Search") {
                        Task { await runSearch() }
                    }
                    .disabled(isSearching || RomTitleNormalizer.strippingTrailingParentheticalTags(searchTitle).isEmpty)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    private var searchForm: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Title search", text: $searchTitle)
                    .textFieldStyle(.roundedBorder)

                Picker("Platform", selection: platformBinding) {
                    Text("Any platform").tag(anyPlatformSentinel)
                    ForEach(ScreenScraperPlatformMap.selectableSystems, id: \.id) { system in
                        Text(system.name).tag(system.id)
                    }
                }

                Picker("Cover region", selection: $selectedCoverRegion) {
                    ForEach(ScreenScraperRegionPreference.selectableRegions, id: \.code) { region in
                        Text(region.label).tag(region.code)
                    }
                }

                Text(
                    "Searches \(providerListText). Results prefer this cover region, then the rest of your region priority list. " +
                        "Platform limits results to one console."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } label: {
            Label("Search parameters", systemImage: "slider.horizontal.3")
        }
    }

    private var providerListText: String {
        let names = CoverProvider.configured.map(\.displayName)
        switch names.count {
        case 0: return "no providers"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }

    private func providerSection(_ section: ProviderSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.provider.displayName)
                    .font(.headline)
                Spacer()
                if let message = section.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(section.results.count) result\(section.results.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !section.results.isEmpty {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(section.results) { result in
                        Button {
                            Task { await apply(result) }
                        } label: {
                            resultCard(result)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func resultCard(_ result: CoverSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedCoverThumbnail(urlString: result.coverURL?.absoluteString, contentMode: .fit)
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 180)
                .clipped()
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            Text(detailLine(for: result))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(result.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private func detailLine(for result: CoverSearchResult) -> String {
        var parts: [String] = []
        if let platform = result.platformName, !platform.isEmpty {
            parts.append(platform)
        }
        if let region = result.regionCode {
            parts.append(ScreenScraperRegionPreference.label(forCode: region))
        }
        return parts.isEmpty ? result.provider.displayName : parts.joined(separator: " · ")
    }

    private var platformBinding: Binding<Int> {
        Binding(
            get: { selectedSystemId ?? anyPlatformSentinel },
            set: { newValue in
                selectedSystemId = newValue == anyPlatformSentinel ? nil : newValue
            }
        )
    }

    // MARK: - Search

    @MainActor
    private func runSearch() async {
        let providers = CoverProvider.configured
        guard !providers.isEmpty else {
            errorMessage = "No cover providers are set up. Add IGDB or TheGamesDB keys under Cover Art and Metadata → Manage Providers."
            return
        }
        let query = RomTitleNormalizer.strippingTrailingParentheticalTags(
            searchTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !query.isEmpty else { return }
        if query != searchTitle {
            searchTitle = query
        }

        isSearching = true
        errorMessage = nil
        sections = []
        defer { isSearching = false }

        let systemId = selectedSystemId
        let coverRegion = selectedCoverRegion
        let regionOrder = ScreenScraperRegionPreference.mediaRegionOrder(preferredCode: coverRegion)
        let selectedPlatformName = systemId.map { ScreenScraperPlatformMap.displayName(forSystemId: $0) }

        let found = await withTaskGroup(of: ProviderSection.self) { group in
            for provider in providers {
                group.addTask {
                    await Self.search(
                        provider: provider,
                        query: query,
                        systemId: systemId,
                        coverRegion: coverRegion,
                        regionOrder: regionOrder,
                        selectedPlatformName: selectedPlatformName
                    )
                }
            }
            var collected: [ProviderSection] = []
            for await section in group {
                collected.append(section)
            }
            return collected
        }

        sections = providers.compactMap { provider in found.first { $0.provider == provider } }
        if sections.allSatisfy({ $0.results.isEmpty }) {
            errorMessage = "No covers found. Try a different title or platform."
        }
    }

    private static func search(
        provider: CoverProvider,
        query: String,
        systemId: Int?,
        coverRegion: String,
        regionOrder: [String],
        selectedPlatformName: String?
    ) async -> ProviderSection {
        do {
            let results: [CoverSearchResult]
            switch provider {
            case .screenScraper:
                let matches: [ScreenScraperGameMatch]
                do {
                    matches = try await ScreenScraperClient.searchGames(
                        searchQuery: query,
                        systemId: systemId,
                        coverRegion: coverRegion
                    )
                } catch ScreenScraperClient.ScreenScraperError.noResults {
                    matches = []
                }
                results = matches.map { match in
                    CoverSearchResult(
                        provider: .screenScraper,
                        gameId: match.gameId,
                        title: match.title,
                        platformName: match.systemName,
                        regionCode: nil,
                        coverURL: match.coverURL,
                        screenScraperMatch: match
                    )
                }

            case .theGamesDB:
                let filter = systemId.flatMap { TheGamesDBPlatformMap.platformFilter(gbearSlugs: [], screenScraperSystemId: $0) }
                if systemId != nil, filter == nil {
                    return ProviderSection(provider: provider, results: [], message: "This platform isn't on TheGamesDB")
                }
                let hits = try await TheGamesDBClient.searchCoverList(name: query, platformFilter: filter)
                results = hits
                    .filter { $0.coverURL != nil }
                    .enumerated()
                    .sorted { lhs, rhs in
                        let left = rank(lhs.element.regionCode, in: regionOrder)
                        let right = rank(rhs.element.regionCode, in: regionOrder)
                        return left != right ? left < right : lhs.offset < rhs.offset
                    }
                    .map { entry in
                        let hit = entry.element
                        return CoverSearchResult(
                            provider: .theGamesDB,
                            gameId: hit.gameId,
                            title: hit.title,
                            platformName: hit.platformName ?? selectedPlatformName,
                            regionCode: hit.regionCode,
                            coverURL: hit.coverURL,
                            screenScraperMatch: nil
                        )
                    }

            case .igdb:
                let filter = systemId.flatMap { IGDBPlatformMap.platformFilter(gbearSlugs: [], screenScraperSystemId: $0) }
                if systemId != nil, filter == nil {
                    return ProviderSection(provider: provider, results: [], message: "This platform isn't mapped for IGDB")
                }
                let hits = try await IGDBClient.searchCoverList(name: query, platformFilter: filter, regionPriority: regionOrder)
                results = hits
                    .filter { $0.coverURL != nil }
                    .map { hit in
                        CoverSearchResult(
                            provider: .igdb,
                            gameId: hit.gameId,
                            title: hit.title,
                            platformName: selectedPlatformName ?? hit.platformName,
                            regionCode: hit.regionCode,
                            coverURL: hit.coverURL,
                            screenScraperMatch: nil
                        )
                    }
            }
            return ProviderSection(provider: provider, results: results, message: results.isEmpty ? "No matches" : nil)
        } catch {
            return ProviderSection(provider: provider, results: [], message: error.localizedDescription)
        }
    }

    private static func rank(_ code: String?, in order: [String]) -> Int {
        guard let code, let index = order.firstIndex(of: code) else { return order.count + 1 }
        return index
    }

    // MARK: - Apply

    @MainActor
    private func apply(_ result: CoverSearchResult) async {
        if let match = result.screenScraperMatch {
            ScreenScraperDisambiguationCoordinator.shared.applySelection(
                libraryGameId: libraryGameId,
                match: match,
                container: modelContext.container,
                forcePrimaryCover: true
            )
            dismiss()
            return
        }

        let context = modelContext
        let gameId = libraryGameId
        var desc = FetchDescriptor<LibraryGame>(predicate: #Predicate { $0.id == gameId })
        desc.fetchLimit = 1
        guard let game = try? context.fetch(desc).first, let cover = result.coverURL else {
            dismiss()
            return
        }

        let persisted = await CoverImageCache.persistCoverReference(cover.absoluteString)
        var options = game.coverImageOptions
        if !options.contains(persisted) {
            options.append(persisted)
            game.coverImageOptions = options
        }
        game.coverImageURLString = persisted
        game.remoteCoverSource = result.provider.rawValue

        let libraryQuery = MetadataService.searchQuery(
            displayTitle: game.libraryListTitle,
            romFileNameStem: URL(fileURLWithPath: game.romPath).deletingPathExtension().lastPathComponent
        )
        if game.title != result.title,
           MetadataService.backupTitleMatches(searchQuery: libraryQuery, candidate: result.title) {
            game.title = result.title
        }
        game.metadataLastFetchAt = Date()
        DiscGroupService.propagateSharedState(from: game, context: context)
        try? context.save()
        dismiss()
    }
}

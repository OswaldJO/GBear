import SwiftData
import SwiftUI

/// User-controlled ScreenScraper search (title, platform, cover region).
struct ScreenScraperManualSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let libraryGameId: UUID
    let initialTitle: String
    let initialSystemId: Int?

    @State private var searchTitle: String
    @State private var selectedSystemId: Int?
    @State private var selectedCoverRegion: String
    @State private var candidates: [ScreenScraperGameMatch] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    private let anyPlatformSentinel = -1

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
                            Text("Searching ScreenScraper…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    if !candidates.isEmpty {
                        Text("Results")
                            .font(.headline)
                        ScreenScraperMatchGrid(candidates: candidates) { match in
                            apply(match)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Search ScreenScraper")
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
        .frame(minWidth: 580, minHeight: 480)
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

                Text("Results pick box art using this region first, then the rest of your Screen Scrapper region priority list. Platform limits results to one console.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } label: {
            Label("Search parameters", systemImage: "slider.horizontal.3")
        }
    }

    private var platformBinding: Binding<Int> {
        Binding(
            get: { selectedSystemId ?? anyPlatformSentinel },
            set: { newValue in
                selectedSystemId = newValue == anyPlatformSentinel ? nil : newValue
            }
        )
    }

    @MainActor
    private func runSearch() async {
        guard MetadataCredentials.isConfigured else {
            errorMessage = "ScreenScraper is not configured in this build."
            return
        }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        let query = RomTitleNormalizer.strippingTrailingParentheticalTags(
            searchTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !query.isEmpty else { return }
        if query != searchTitle {
            searchTitle = query
        }

        do {
            candidates = try await ScreenScraperClient.searchGames(
                searchQuery: query,
                systemId: selectedSystemId,
                coverRegion: selectedCoverRegion
            )
            if candidates.isEmpty {
                errorMessage = "No matches found. Try a different title or platform."
            }
        } catch {
            candidates = []
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ match: ScreenScraperGameMatch) {
        ScreenScraperDisambiguationCoordinator.shared.applySelection(
            libraryGameId: libraryGameId,
            match: match,
            container: modelContext.container,
            forcePrimaryCover: true
        )
        dismiss()
    }
}

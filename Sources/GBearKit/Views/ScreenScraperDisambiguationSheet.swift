import SwiftData
import SwiftUI

/// Lets the user pick which ScreenScraper console/release matches an ambiguous game title.
struct ScreenScraperDisambiguationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var coordinator: ScreenScraperDisambiguationCoordinator

    @State private var activeRequestIndex = 0
    @State private var manualSearchRequest: ScreenScraperDisambiguationRequest?

    private var activeRequest: ScreenScraperDisambiguationRequest? {
        guard coordinator.pending.indices.contains(activeRequestIndex) else { return nil }
        return coordinator.pending[activeRequestIndex]
    }

    var body: some View {
        NavigationStack {
            Group {
                if let request = activeRequest {
                    disambiguationContent(for: request)
                } else {
                    ContentUnavailableView(
                        "Nothing to resolve",
                        systemImage: "checkmark.circle",
                        description: Text("All ambiguous ScreenScraper matches have been handled.")
                    )
                }
            }
            .navigationTitle("Choose console")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if let request = activeRequest {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Skip") {
                            skip(request)
                        }
                    }
                }
                if coordinator.pending.count > 1, activeRequest != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Text("\(activeRequestIndex + 1) of \(coordinator.pending.count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .sheet(item: $manualSearchRequest) { request in
                CoverSearchSheet(
                    libraryGameId: request.libraryGameId,
                    initialTitle: request.searchQuery,
                    initialSystemId: request.candidates.first?.systemId
                )
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onChange(of: coordinator.pending.count) { _, newCount in
            if newCount == 0 {
                dismiss()
            } else if activeRequestIndex >= newCount {
                activeRequestIndex = max(0, newCount - 1)
            }
        }
    }

    @ViewBuilder
    private func disambiguationContent(for request: ScreenScraperDisambiguationRequest) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.libraryTitle)
                        .font(.title3.weight(.semibold))
                    Text("ScreenScraper found multiple consoles for “\(request.searchQuery)”. Pick the one that matches your ROM.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ScreenScraperMatchGrid(candidates: request.candidates) { candidate in
                    select(candidate, for: request)
                }

                HStack(spacing: 10) {
                    Button("Search manually…") {
                        manualSearchRequest = request
                    }
                    .buttonStyle(.bordered)

                    Button("None of these — skip") {
                        skip(request)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
        }
    }

    private func select(_ candidate: ScreenScraperGameMatch, for request: ScreenScraperDisambiguationRequest) {
        coordinator.applySelection(
            libraryGameId: request.libraryGameId,
            match: candidate,
            container: modelContext.container
        )
        if activeRequestIndex >= coordinator.pending.count {
            activeRequestIndex = max(0, coordinator.pending.count - 1)
        }
    }

    private func skip(_ request: ScreenScraperDisambiguationRequest) {
        coordinator.skipSelection(libraryGameId: request.libraryGameId, container: modelContext.container)
        if activeRequestIndex >= coordinator.pending.count {
            activeRequestIndex = max(0, coordinator.pending.count - 1)
        }
    }
}

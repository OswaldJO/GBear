import SwiftData
import SwiftUI

/// Sidebar detail: ScreenScraper login status and full-library scrape progress.
struct ScreenScraperLibrarySettingsView: View {
    @Bindable var fetcher: MetadataBackgroundFetcher
    @Bindable var disambiguationCoordinator: ScreenScraperDisambiguationCoordinator
    let isConfigured: Bool
    let credentialsRevision: Int
    let onOpenCredentials: () -> Void
    let onScrapeNow: () -> Void
    let onResolveAmbiguous: () -> Void
    let onClearScrapedCovers: () -> Int

    @State private var preferredRegion: String = MetadataCredentials.screenScraperPreferredRegion
    @State private var autoSelectAmbiguous = MetadataCredentials.screenScraperAutoSelectAmbiguousMatches
    @State private var onlyScanMissing = MetadataCredentials.screenScraperOnlyScanMissing
    @State private var showClearCoversConfirmation = false
    @State private var clearCoversStatus: String?

    private var isLoggedIn: Bool { MetadataCredentials.hasUserCredentials }
    private var username: String? { MetadataCredentials.screenScraperUserID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if disambiguationCoordinator.hasPending {
                    disambiguationCard
                }
                loginStatusCard
                defaultRegionCard
                autoSelectCard
                if fetcher.libraryScrapeInProgress {
                    scrapeProgressCard
                } else if let summary = fetcher.lastLibraryScrapeSummary,
                          let finished = fetcher.lastLibraryScrapeFinishedAt {
                    lastScrapeResultCard(summary: summary, finishedAt: finished)
                }
                actionsCard
                if fetcher.backgroundPassInProgress && !fetcher.libraryScrapeInProgress {
                    backgroundPassBanner
                }
                helpText
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(credentialsRevision)
        .confirmationDialog(
            "Clear all scraped covers?",
            isPresented: $showClearCoversConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear scraped covers", role: .destructive) {
                let count = onClearScrapedCovers()
                clearCoversStatus = "Cleared cover and ScreenScraper data for \(count) game(s). Run Scrape library to fetch fresh art."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes cover images and ScreenScraper match pins from every library game. " +
                    "File titles on disk are unchanged. Per-game display names are kept."
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Screen Scrapper")
                .font(.title3.weight(.semibold))
            Text("Fetch cover art and titles from ScreenScraper for your library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var loginStatusCard: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: isLoggedIn ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle.badge.plus")
                    .font(.system(size: 32))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isLoggedIn ? .green : .orange)

                VStack(alignment: .leading, spacing: 6) {
                    Text(isLoggedIn ? "Signed in" : "Not signed in")
                        .font(.headline)
                    if let username, isLoggedIn {
                        Label(username, systemImage: "person")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !isConfigured {
                        Label("ScreenScraper unavailable in this build", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button {
                        onOpenCredentials()
                    } label: {
                        Label(isLoggedIn ? "Change login" : "Sign in", systemImage: "person.badge.key")
                    }
                    .buttonStyle(.bordered)

                    if isLoggedIn {
                        Button("Sign out", role: .destructive) {
                            MetadataCredentials.screenScraperUserID = nil
                            MetadataCredentials.screenScraperUserPassword = nil
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("ScreenScraper login", systemImage: "person.badge.key")
        }
    }

    private var scrapeProgressCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if fetcher.libraryScrapeWaitingForBackground {
                    HStack(alignment: .top, spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            "Waiting for the background metadata pass to finish. " +
                                "A full scrape runs after that so both passes don’t compete for ScreenScraper requests."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    ProgressView()
                        .controlSize(.regular)
                    Text(fetcher.libraryScrapeWaitingForBackground ? "Preparing library scrape…" : "Scraping library…")
                        .font(.headline)
                    Spacer()
                    Text("\(fetcher.libraryScrapeProcessed) / \(max(fetcher.libraryScrapeTotal, 1))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if fetcher.libraryScrapeTotal > 0 {
                    ProgressView(
                        value: Double(fetcher.libraryScrapeProcessed),
                        total: Double(fetcher.libraryScrapeTotal)
                    )
                    .progressViewStyle(.linear)
                }

                if let title = fetcher.libraryScrapeCurrentTitle, !title.isEmpty {
                    Label(title, systemImage: "gamecontroller")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text("\(fetcher.libraryScrapeUpdated) updated so far")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Cancel scrape", role: .destructive) {
                    fetcher.cancelLibraryScrape()
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        } label: {
            Label("Library scrape", systemImage: "sparkle.magnifyingglass")
        }
    }

    private func lastScrapeResultCard(summary: MetadataBackgroundFetcher.ScrapeSummary, finishedAt: Date) -> some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last scrape complete")
                        .font(.headline)
                    Text(
                        "Processed \(summary.processed) game(s), updated \(summary.updated). " +
                            finishedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    if let logPath = fetcher.lastLibraryScrapeLogPath {
                        Text("Scrape log saved to Downloads: \(logPath)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        } label: {
            Label("Recent result", systemImage: "clock.arrow.circlepath")
        }
    }

    private var actionsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    onScrapeNow()
                } label: {
                    Label("Scrape library", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isConfigured || fetcher.libraryScrapeInProgress || fetcher.libraryScrapeWaitingForBackground)

                Button("Clear scraped covers…", role: .destructive) {
                    showClearCoversConfirmation = true
                }
                .buttonStyle(.bordered)
                .disabled(fetcher.libraryScrapeInProgress || fetcher.libraryScrapeWaitingForBackground)

                if let clearCoversStatus {
                    Text(clearCoversStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Actions", systemImage: "slider.horizontal.3")
        }
    }

    private var backgroundPassBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(
                "Background metadata pass running (up to 3 games). " +
                    "This fetches missing covers for new entries — it does not cache emulator/core matching. " +
                    "A full Scrape library waits for this pass to finish."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var disambiguationCard: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(disambiguationCoordinator.pending.count) game(s) need a console")
                        .font(.headline)
                    Text("ScreenScraper found multiple platforms for these titles. Choose the correct console so cover art matches your ROM.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Choose consoles…") {
                        onResolveAmbiguous()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        } label: {
            Label("Needs your input", systemImage: "rectangle.stack.badge.questionmark")
        }
    }

    private var defaultRegionCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Default cover region", selection: $preferredRegion) {
                    ForEach(ScreenScraperRegionPreference.selectableRegions, id: \.code) { region in
                        Text(region.label).tag(region.code)
                    }
                }
                .onChange(of: preferredRegion) { _, newValue in
                    MetadataCredentials.screenScraperPreferredRegion = newValue
                }

                Text(
                    "Library scrapes prefer box art from this region. If a game has no art for that region, other regions are used as fallback."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } label: {
            Label("Default region", systemImage: "globe")
        }
    }

    private var autoSelectCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Auto-select when multiple platforms match", isOn: $autoSelectAmbiguous)
                    .onChange(of: autoSelectAmbiguous) { _, newValue in
                        MetadataCredentials.screenScraperAutoSelectAmbiguousMatches = newValue
                    }

                Toggle("Only Scan Missing", isOn: $onlyScanMissing)
                    .onChange(of: onlyScanMissing) { _, newValue in
                        MetadataCredentials.screenScraperOnlyScanMissing = newValue
                    }

                Text(
                    "When off, you choose the console when ScreenScraper finds several matches. When on, the app picks using your emulator platform, title similarity, and ScreenScraper’s result order. Check the scrape log for lines tagged auto_ambiguous to review those picks."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Text(
                    "Only Scan Missing skips games that already have ScreenScraper cover art. Uncheck it to scrape every game again."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } label: {
            Label("Automatic matching", systemImage: "wand.and.stars")
        }
    }

    private var helpText: some View {
        Text(
            "Scrape uses your emulator (and RetroArch core) to pick the right ScreenScraper console; " +
                "that mapping is cached for the session. Cover art is saved locally after the first download. " +
                "Per-emulator “prioritize ScreenScraper art” is in Paths. Use the info button on a game for manual ScreenScraper search."
        )
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}

/// Compact login/scrape indicators for the library sidebar row.
struct ScreenScraperSidebarRow: View {
    @Bindable var fetcher: MetadataBackgroundFetcher

    var body: some View {
        HStack(spacing: 8) {
            Text("Screen Scrapper")
            Spacer(minLength: 4)
            if fetcher.libraryScrapeInProgress {
                ProgressView()
                    .controlSize(.small)
            } else if MetadataCredentials.hasUserCredentials {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .help("ScreenScraper login saved")
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("No personal ScreenScraper login")
            }
        }
    }
}

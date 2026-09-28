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

    @State private var regionPriority: [String] = MetadataCredentials.screenScraperRegionPriority
    @State private var autoSelectAmbiguous = MetadataCredentials.screenScraperAutoSelectAmbiguousMatches
    @State private var onlyScanMissing = MetadataCredentials.screenScraperOnlyScanMissing
    @State private var theGamesDBAPIKey = MetadataCredentials.theGamesDBAPIKey ?? ""
    @State private var theGamesDBKeySaved = MetadataCredentials.hasTheGamesDBAPIKey
    @State private var igdbClientID = MetadataCredentials.igdbClientID ?? ""
    @State private var igdbClientSecret = MetadataCredentials.igdbClientSecret ?? ""
    @State private var igdbKeysSaved = MetadataCredentials.hasIGDBCredentials
    @State private var igdbStatus: String?
    @State private var igdbStatusIsError = false
    @State private var igdbVerifying = false
    @State private var steamGridDBAPIKey = MetadataCredentials.steamGridDBAPIKey ?? ""
    @State private var steamGridDBKeySaved = MetadataCredentials.hasSteamGridDBAPIKey
    @State private var steamGridDBStatus: String?
    @State private var steamGridDBStatusIsError = false
    @State private var steamGridDBVerifying = false
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
                igdbKeysCard
                steamGridDBKeyCard
                theGamesDBKeyCard
                actionsCard
                if fetcher.libraryScrapeInProgress {
                    scrapeProgressCard
                } else if let summary = fetcher.lastLibraryScrapeSummary,
                          let finished = fetcher.lastLibraryScrapeFinishedAt {
                    lastScrapeResultCard(summary: summary, finishedAt: finished)
                }
                if fetcher.backgroundPassInProgress && !fetcher.libraryScrapeInProgress {
                    backgroundPassBanner
                }
                autoSelectCard
                defaultRegionCard
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
            Text("Fetch cover art and titles from ScreenScraper. IGDB, SteamGridDB, then TheGamesDB fill in a cover with your own keys when ScreenScraper has none or you are not signed in.")
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
                    } else if !isLoggedIn, theGamesDBKeySaved || igdbKeysSaved || steamGridDBKeySaved {
                        Text("Covers come from your IGDB / SteamGridDB / TheGamesDB keys until you sign in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !isLoggedIn {
                        Text("Save IGDB, SteamGridDB, or TheGamesDB keys to fetch covers without a ScreenScraper login.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

    private var theGamesDBKeyCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("TheGamesDB is the last fallback because each key has a small monthly allowance. It uses your own API key; paste it here, then scrape.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("API key", text: $theGamesDBAPIKey)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Link("Request an API key", destination: URL(string: "https://api.thegamesdb.net/key.php")!)
                    Spacer(minLength: 8)
                    if theGamesDBKeySaved {
                        Button("Remove", role: .destructive) {
                            theGamesDBAPIKey = ""
                            MetadataCredentials.theGamesDBAPIKey = nil
                            theGamesDBKeySaved = false
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Save key") {
                        let trimmed = theGamesDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed != MetadataCredentials.theGamesDBAPIKey {
                            CoverProviderQuota.shared.reset(.theGamesDB)
                        }
                        MetadataCredentials.theGamesDBAPIKey = trimmed
                        theGamesDBAPIKey = trimmed
                        theGamesDBKeySaved = !trimmed.isEmpty
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(theGamesDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if theGamesDBKeySaved {
                    Label("API key saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("TheGamesDB API key", systemImage: "key")
        }
    }

    private var igdbKeysCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "IGDB runs when ScreenScraper has no cover, before SteamGridDB and TheGamesDB. It uses your own Twitch application: " +
                        "create one in the Twitch developer console and paste its Client ID and Client Secret."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                TextField("Client ID", text: $igdbClientID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Client Secret", text: $igdbClientSecret)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Link("How to get IGDB keys", destination: URL(string: "https://api-docs.igdb.com/#account-creation")!)
                    Spacer(minLength: 8)
                    if igdbKeysSaved {
                        Button("Remove", role: .destructive) {
                            igdbClientID = ""
                            igdbClientSecret = ""
                            MetadataCredentials.igdbClientID = nil
                            MetadataCredentials.igdbClientSecret = nil
                            igdbKeysSaved = false
                            igdbStatus = nil
                            Task { await IGDBTokenStore.shared.clear() }
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Save keys") { saveIGDBKeys() }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            igdbVerifying
                                || igdbClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || igdbClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }

                if igdbVerifying {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking keys with Twitch…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let igdbStatus {
                    Label(igdbStatus, systemImage: igdbStatusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(igdbStatusIsError ? .orange : .green)
                } else if igdbKeysSaved {
                    Label("Keys saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("IGDB keys", systemImage: "key")
        }
    }

    private var steamGridDBKeyCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "SteamGridDB runs after IGDB and before TheGamesDB. It has community-made portrait covers and finds Steam games by app id. " +
                        "It uses your own API key from your SteamGridDB account preferences."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                SecureField("API key", text: $steamGridDBAPIKey)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 8) {
                    Link("Get an API key", destination: URL(string: "https://www.steamgriddb.com/profile/preferences/api")!)
                    Spacer(minLength: 8)
                    if steamGridDBKeySaved {
                        Button("Remove", role: .destructive) {
                            steamGridDBAPIKey = ""
                            MetadataCredentials.steamGridDBAPIKey = nil
                            steamGridDBKeySaved = false
                            steamGridDBStatus = nil
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Save key") { saveSteamGridDBKey() }
                        .buttonStyle(.borderedProminent)
                        .disabled(steamGridDBVerifying || steamGridDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if steamGridDBVerifying {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking key with SteamGridDB…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let steamGridDBStatus {
                    Label(steamGridDBStatus, systemImage: steamGridDBStatusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(steamGridDBStatusIsError ? .orange : .green)
                } else if steamGridDBKeySaved {
                    Label("API key saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("SteamGridDB API key", systemImage: "key")
        }
    }

    private func saveSteamGridDBKey() {
        let trimmed = steamGridDBAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != MetadataCredentials.steamGridDBAPIKey {
            CoverProviderQuota.shared.reset(.steamGridDB)
        }
        MetadataCredentials.steamGridDBAPIKey = trimmed
        steamGridDBAPIKey = trimmed
        steamGridDBKeySaved = MetadataCredentials.hasSteamGridDBAPIKey
        steamGridDBStatus = nil
        steamGridDBVerifying = true
        Task { @MainActor in
            defer { steamGridDBVerifying = false }
            do {
                try await SteamGridDBClient.verifyKey()
                steamGridDBStatus = "API key saved and accepted by SteamGridDB"
                steamGridDBStatusIsError = false
            } catch {
                steamGridDBStatus = "Saved, but \(error.localizedDescription)"
                steamGridDBStatusIsError = true
            }
        }
    }

    private func saveIGDBKeys() {
        let id = igdbClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = igdbClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if id != MetadataCredentials.igdbClientID {
            CoverProviderQuota.shared.reset(.igdb)
        }
        MetadataCredentials.igdbClientID = id
        MetadataCredentials.igdbClientSecret = secret
        igdbClientID = id
        igdbClientSecret = secret
        igdbKeysSaved = MetadataCredentials.hasIGDBCredentials
        igdbStatus = nil
        igdbVerifying = true
        Task { @MainActor in
            defer { igdbVerifying = false }
            do {
                try await IGDBClient.verifyCredentials()
                igdbStatus = "Keys saved and accepted by Twitch"
                igdbStatusIsError = false
            } catch {
                igdbStatus = "Saved, but \(error.localizedDescription)"
                igdbStatusIsError = true
            }
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
                .disabled(
                    !isConfigured || fetcher.libraryScrapeInProgress || fetcher.libraryScrapeWaitingForBackground
                        || CoverProviderQuota.shared.allScrapeProvidersBlocked
                )

                if CoverProviderQuota.shared.allScrapeProvidersBlocked {
                    Label(MetadataBackgroundFetcher.allBlockedMessage(stopped: false), systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let message = fetcher.libraryScrapeLimitMessage {
                    Label(message, systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                apiLimitsList

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

    /// One line per provider the scrape uses: remaining allowance, or when a used-up provider resumes.
    private var apiLimitsList: some View {
        let quota = CoverProviderQuota.shared
        return VStack(alignment: .leading, spacing: 4) {
            Text("API limits")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if CoverProviderQuota.scrapeProviders.isEmpty {
                Text("No cover provider is set up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(CoverProviderQuota.scrapeProviders, id: \.self) { provider in
                let status = quota.status(provider)
                HStack(spacing: 6) {
                    Image(systemName: quota.isAvailable(provider) ? "checkmark.circle.fill" : "pause.circle.fill")
                        .foregroundStyle(quota.isAvailable(provider) ? .green : .orange)
                    Text(provider.displayName).fontWeight(.medium)
                    Text(limitDescription(provider, status: status, available: quota.isAvailable(provider)))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Text(
                "A provider that reaches its limit is skipped until it resets (ScreenScraper daily at midnight Paris time, " +
                    "TheGamesDB monthly, IGDB and SteamGridDB after a short pause). When every provider is at its limit, scrapes stop and don't start."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    private func limitDescription(_ provider: CoverProvider, status: CoverProviderQuota.Status, available: Bool) -> String {
        if !available {
            let until = status.blockedUntil.map { "resumes \(CoverProviderQuota.describe($0))" } ?? "paused"
            return "\(status.reason ?? "limit reached") — \(until)"
        }
        switch provider {
        case .screenScraper:
            if let used = status.used, let limit = status.limit {
                return "\(used.formatted()) of \(limit.formatted()) requests used today"
            }
            return "daily limit shown after the first request"
        case .theGamesDB:
            if let remaining = status.remaining {
                return "\(remaining.formatted()) requests left this month"
            }
            return "monthly allowance shown after the first request"
        case .igdb:
            return "no daily limit; requests are spaced to 4 per second"
        case .steamGridDB:
            return "no published limit; paused briefly if it asks the app to slow down"
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
            ScreenScraperRegionPriorityList(order: $regionPriority)
                .onChange(of: regionPriority) { _, newValue in
                    MetadataCredentials.screenScraperRegionPriority = newValue
                }
                .padding(.vertical, 4)
        } label: {
            Label("Region priority", systemImage: "globe")
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
                    "Only Scan Missing skips games that already have scraped cover art. Uncheck it to scrape every game again."
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
            "Scrape uses your emulator (and RetroArch core) to pick the right console. " +
                "ScreenScraper runs when you are signed in. IGDB, SteamGridDB, then TheGamesDB run when their keys are saved, including when you are not signed in. " +
                "Cover art is saved locally after the first download. " +
                "Per-emulator “prioritize ScreenScraper art” is in Paths. Use the info button on a game for Search for Covers."
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
            Text("Manage Providers")
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
                    .help(
                        MetadataCredentials.hasTheGamesDBAPIKey || MetadataCredentials.hasIGDBCredentials
                            || MetadataCredentials.hasSteamGridDBAPIKey
                            ? "No personal ScreenScraper login. Covers fall back to IGDB / SteamGridDB / TheGamesDB."
                            : "No personal ScreenScraper login. Add IGDB, SteamGridDB, or TheGamesDB keys to fetch covers."
                    )
            }
        }
    }
}

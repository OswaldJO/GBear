import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum MainSection: Hashable {
    case library
    case emulators
    case paths
    case streaming
}

private struct PendingROMMDownload {
    let gameID: UUID
    let title: String
    let folders: [URL]
    let launchAfter: Bool
}

private enum LibrarySidebarSelection: Hashable {
    case all
    case macGames
    case emulator(UUID)
    case storefrontManager
    case romm
    case screenScraper
}

public struct RootView: View {
    public init() {}

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\EmulatorProfile.name, comparator: .localizedStandard)]) private var emulators: [EmulatorProfile]
    @Query(sort: \LibraryGame.sortOrder) private var games: [LibraryGame]

    @State private var sidebarSelection: LibrarySidebarSelection = .all
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var section: MainSection = .library
    @State private var scanFeedback: String?
    @State private var cleanupFeedback: String?
    @State private var confirmClearAllGames = false
    @State private var confirmClearMacGames = false
    @State private var showScreenScraperSettings = false
    @State private var showBlockedGames = false
    @State private var showScreenScraperDisambiguation = false
    @State private var screenScraperCredentialsRevision = 0
    @Bindable private var screenScraperDisambiguationCoordinator = ScreenScraperDisambiguationCoordinator.shared
    @State private var clearEmulatorGamesID: UUID?
    @State private var pendingROMMDownload: PendingROMMDownload?
    /// Game card showing play / info overlay.
    @State private var actionOverlayGameID: UUID?
    /// Game open in the trailing inspector column.
    @State private var inspectorGameID: UUID?

    private var activeEmulatorIDs: Set<UUID> {
        Set(emulators.map(\.id))
    }

    private var visibleLibraryGames: [LibraryGame] {
        games.filter { game in
            guard let emulatorID = game.emulatorUUID else { return StorefrontSettings.shared.isVisible(game) }
            return activeEmulatorIDs.contains(emulatorID)
        }
    }

    private var filteredGames: [LibraryGame] {
        let sortedVisible = visibleLibraryGames.sorted { DiscGroupService.librarySort(lhs: $0, rhs: $1) }
        switch sidebarSelection {
        case .all:
            return sortedVisible
        case .macGames:
            return sortedVisible.filter { $0.emulatorUUID == nil }
        case .emulator(let id):
            return sortedVisible.filter { $0.emulatorUUID == id }
        case .storefrontManager, .romm, .screenScraper:
            return []
        }
    }

    private var selectedLibrarySidebarTitle: String? {
        switch sidebarSelection {
        case .all: return "All"
        case .macGames: return "Mac Games"
        case .emulator(let id): return emulators.first(where: { $0.id == id })?.name
        case .storefrontManager, .romm, .screenScraper: return nil
        }
    }

    @ViewBuilder
    private var selectedLibraryCountFooter: some View {
        if let title = selectedLibrarySidebarTitle {
            let count = filteredGames.count
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text(title)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(count == 1 ? "1 game" : "\(count) games")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }

    @ViewBuilder
    private var macGamesSidebarItem: some View {
        Text("Mac Games")
            .tag(LibrarySidebarSelection.macGames)
            .contextMenu {
                Button("Clear Mac Games…", systemImage: "trash", role: .destructive) {
                    confirmClearMacGames = true
                }
            }
    }

    @ViewBuilder
    private var libraryDetailContent: some View {
        switch sidebarSelection {
        case .storefrontManager:
            StorefrontManagerView(
                settings: StorefrontSettings.shared,
                importer: StorefrontImporter.shared,
                games: games,
                onImport: { importStorefrontGames() }
            )
        case .romm:
            RommSettingsView(
                sync: RommSync.shared,
                emulators: emulators,
                games: games,
                onSync: { syncROMM() }
            )
        case .screenScraper:
            ScreenScraperLibrarySettingsView(
                fetcher: MetadataBackgroundFetcher.shared,
                disambiguationCoordinator: ScreenScraperDisambiguationCoordinator.shared,
                isConfigured: MetadataCredentials.isConfigured,
                credentialsRevision: screenScraperCredentialsRevision,
                onOpenCredentials: { showScreenScraperSettings = true },
                onScrapeNow: { runScreenScraperScrapeNow() },
                onResolveAmbiguous: { showScreenScraperDisambiguation = true },
                onClearScrapedCovers: { clearAllScrapedCovers() }
            )
        case .all, .macGames, .emulator:
            HStack(spacing: 0) {
                LibraryGamesGridView(
                    games: filteredGames,
                    coverAspects: Dictionary(uniqueKeysWithValues: emulators.map { ($0.id, $0.coverAspectRatio) }),
                    actionOverlayGameID: $actionOverlayGameID,
                    inspectorGameID: $inspectorGameID,
                    onPlay: { play($0) },
                    onDelete: { deleteGame($0) }
                )
                .frame(minWidth: 240)
                .layoutPriority(1)

                if let id = inspectorGameID,
                   let game = filteredGames.first(where: { $0.id == id }) {
                    Divider()
                    NavigationStack {
                        LibraryGameInspectorView(
                            game: game,
                            allGames: games,
                            emulators: emulators,
                            coverAspect: game.emulatorUUID.flatMap { id in
                                emulators.first(where: { $0.id == id })?.coverAspectRatio
                            } ?? .default,
                            onDismiss: { inspectorGameID = nil },
                            onDownloadFromROMM: { downloadFromROMM(game, launchAfter: false) }
                        )
                    }
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 520)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: inspectorGameID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var libraryTab: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $sidebarSelection) {
                Section("Library") {
                    Text("All")
                        .tag(LibrarySidebarSelection.all)
                        .contextMenu {
                            Button("Clear All Games…", systemImage: "trash", role: .destructive) {
                                confirmClearAllGames = true
                            }
                        }
                    macGamesSidebarItem
                    ForEach(emulators, id: \.id) { emu in
                        Text(emu.name)
                            .tag(LibrarySidebarSelection.emulator(emu.id))
                            .contextMenu {
                                Button("Clear Games for “\(emu.name)”…", systemImage: "trash", role: .destructive) {
                                    clearEmulatorGamesID = emu.id
                                }
                            }
                    }
                }
                Section("Storefront Manager") {
                    Label("Show Manager", systemImage: "storefront")
                        .tag(LibrarySidebarSelection.storefrontManager)
                }
                Section("ROMM") {
                    Label("Show ROMM", systemImage: "server.rack")
                        .tag(LibrarySidebarSelection.romm)
                }
                Section("Cover Art and Metadata") {
                    ScreenScraperSidebarRow(fetcher: MetadataBackgroundFetcher.shared)
                        .tag(LibrarySidebarSelection.screenScraper)
                }
            }
            .navigationTitle("Games")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                selectedLibraryCountFooter
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        addManualMacGame()
                    } label: {
                        Label("Add Game", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                    }

                    Button {
                        performScan()
                    } label: {
                        Label("Scan Paths", systemImage: "arrow.triangle.2.circlepath")
                            .labelStyle(.titleAndIcon)
                    }

                    Button {
                        importStorefrontGames()
                    } label: {
                        Label("Import Storefront Installed Games", systemImage: "shippingbox")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(StorefrontImporter.shared.isImporting)

                    Button {
                        showScreenScraperSettings = true
                    } label: {
                        Label {
                            Text("ScreenScraper Login")
                        } icon: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "person.badge.key")
                                if MetadataCredentials.hasUserCredentials {
                                    Circle()
                                        .fill(.green)
                                        .frame(width: 7, height: 7)
                                        .offset(x: 3, y: -3)
                                }
                            }
                        }
                        .labelStyle(.titleAndIcon)
                    }

                    Button {
                        showBlockedGames = true
                    } label: {
                        Label("Manage Blocked List", systemImage: "hand.raised")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            .alert("Scan Paths", isPresented: Binding(
                get: { scanFeedback != nil },
                set: { if !$0 { scanFeedback = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(scanFeedback ?? "")
            }
            .confirmationDialog(
                "Clear entire library?",
                isPresented: $confirmClearAllGames,
                titleVisibility: .visible
            ) {
                Button("Clear All Games", role: .destructive) {
                    removeEveryGameFromLibrary()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every game entry is removed. Your folders on disk are unchanged—use Scan Paths to import again.")
            }
            .confirmationDialog(
                "Clear Mac games?",
                isPresented: $confirmClearMacGames,
                titleVisibility: .visible
            ) {
                Button("Clear Mac Games", role: .destructive) {
                    removeAllMacGames()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes all standalone Mac game entries. Files on disk are unchanged.")
            }
            .confirmationDialog(
                "Clear games for this emulator?",
                isPresented: Binding(
                    get: { clearEmulatorGamesID != nil },
                    set: { if !$0 { clearEmulatorGamesID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Clear Games", role: .destructive) {
                    if let id = clearEmulatorGamesID {
                        removeAllGames(forEmulatorID: id)
                    }
                    clearEmulatorGamesID = nil
                }
                Button("Cancel", role: .cancel) {
                    clearEmulatorGamesID = nil
                }
            } message: {
                if let id = clearEmulatorGamesID,
                   let emu = emulators.first(where: { $0.id == id }) {
                    Text("Removes all library entries for “\(emu.name)”. Scan Paths can add them again.")
                }
            }
        } detail: {
            libraryDetailContent
        }
        .navigationSplitViewStyle(.balanced)
        .tabItem { Label("Library", systemImage: "square.grid.2x2") }
        .tag(MainSection.library)
    }

    public var body: some View {
        TabView(selection: $section) {
            libraryTab

            EmulatorsView()
                .tabItem { Label("Emulators", systemImage: "gearshape.2") }
                .tag(MainSection.emulators)

            PathsView()
                .tabItem { Label("Paths", systemImage: "folder") }
                .tag(MainSection.paths)

            StreamingView()
                .tabItem { Label("Streaming", systemImage: "dot.radiowaves.left.and.right") }
                .tag(MainSection.streaming)
        }
        .onChange(of: emulators.map(\.id)) { _, ids in
            if case .emulator(let selectedId) = sidebarSelection, !ids.contains(selectedId) {
                sidebarSelection = .all
            }
        }
        .onChange(of: filteredGames.map(\.id)) { _, ids in
            if let id = inspectorGameID, !ids.contains(id) {
                inspectorGameID = nil
            }
            if let id = actionOverlayGameID, !ids.contains(id) {
                actionOverlayGameID = nil
            }
        }
        .task {
            let removed = removeOrphanedGamesFromLibrary()
            if removed > 0 {
                cleanupFeedback = "Removed \(removed) orphan game(s) from the library. These entries referenced missing emulators and could appear as ghost games."
            }
            MetadataBackgroundFetcher.shared.startIfNeeded(container: modelContext.container)
        }
        .alert("Library Cleanup", isPresented: Binding(
            get: { cleanupFeedback != nil },
            set: { if !$0 { cleanupFeedback = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cleanupFeedback ?? "")
        }
        .sheet(isPresented: $showScreenScraperSettings, onDismiss: {
            screenScraperCredentialsRevision += 1
        }) {
            ScreenScraperSettingsSheet()
        }
        .sheet(isPresented: $showBlockedGames) {
            BlockedGamesSheet()
        }
        .confirmationDialog(
            "Download to which game folder?",
            isPresented: Binding(
                get: { pendingROMMDownload != nil },
                set: { if !$0 { pendingROMMDownload = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingROMMDownload
        ) { pending in
            ForEach(pending.folders, id: \.self) { folder in
                Button(folder.path) {
                    startROMMDownload(gameID: pending.gameID, folder: folder, launchAfter: pending.launchAfter)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("“\(pending.title)” is in ROMM but not on this Mac. Choose where to save it.")
        }
        .sheet(isPresented: $showScreenScraperDisambiguation) {
            ScreenScraperDisambiguationSheet(coordinator: ScreenScraperDisambiguationCoordinator.shared)
        }
        .onChange(of: screenScraperDisambiguationCoordinator.pending.count) { _, newCount in
            if newCount > 0, !showScreenScraperDisambiguation {
                showScreenScraperDisambiguation = true
            }
        }
    }

    private func runScreenScraperScrapeNow() {
        MetadataBackgroundFetcher.shared.startLibraryScrape(container: modelContext.container)
    }

    private func clearAllScrapedCovers() -> Int {
        (try? MetadataBackgroundFetcher.shared.clearAllScrapedMetadata(container: modelContext.container)) ?? 0
    }

    private func performScan() {
        let summary: GamePathScanner.ScanSummary
        do {
            summary = try GamePathScanner.scan(modelContext: modelContext)
        } catch {
            scanFeedback = "Scan failed: \(error.localizedDescription)"
            return
        }
        Task {
            let storefront = await StorefrontImporter.shared.importAll(modelContext: modelContext)
            let romm = await RommSync.shared.sync(modelContext: modelContext)
            var parts: [String] = []
            if summary.added > 0 {
                parts.append("Added \(summary.added) game(s)")
            }
            if summary.reassigned > 0 {
                parts.append("Re-linked \(summary.reassigned) existing game(s) to this emulator")
            }
            if summary.linkedCovers > 0 {
                parts.append("Linked \(summary.linkedCovers) cover image(s)")
            }
            if summary.autoLinkedDiscSets > 0 {
                parts.append("Auto-linked \(summary.autoLinkedDiscSets) multi-disc set(s)")
            }
            if summary.removedMissing > 0 {
                parts.append("Removed \(summary.removedMissing) missing game(s)")
            }
            if summary.removedNested > 0 {
                parts.append("Removed \(summary.removedNested) extra file(s) inside game folders")
            }
            parts.append(contentsOf: storefront.feedbackParts)
            parts.append(contentsOf: romm.feedbackParts)
            if summary.skippedBlocked > 0 {
                parts.append(blockedSkipNote(summary.skippedBlocked))
            }
            if summary.hasAnyChanges || storefront.hasChanges || romm.added > 0 || romm.removed > 0 {
                scanFeedback = parts.joined(separator: ". ") + "."
            } else if !parts.isEmpty {
                scanFeedback = "No new games found. " + parts.joined(separator: ". ") + "."
            } else {
                scanFeedback = "No new games found. Add folders in Paths or check that files use supported extensions."
            }
            if summary.added > 0 || storefront.added > 0 || romm.added > 0 {
                MetadataBackgroundFetcher.shared.scheduleExtraPass(container: modelContext.container)
            }
        }
    }

    private func syncROMM() {
        Task {
            let summary = await RommSync.shared.sync(modelContext: modelContext)
            if summary.added > 0 {
                MetadataBackgroundFetcher.shared.scheduleExtraPass(container: modelContext.container)
            }
        }
    }

    private func blockedSkipNote(_ count: Int) -> String {
        "Skipped \(count) blocked game(s) you removed (Manage Blocked List)"
    }

    private func importStorefrontGames() {
        Task {
            let summary = await StorefrontImporter.shared.importAll(modelContext: modelContext)
            let parts = summary.feedbackParts
            if StorefrontSettings.shared.enabled.isEmpty {
                scanFeedback = "No storefronts are checked. Turn one on under Storefront Manager."
            } else if parts.isEmpty {
                scanFeedback = "No storefront changes. Installed games are already in your library."
            } else {
                scanFeedback = parts.joined(separator: ". ") + "."
            }
            if summary.added > 0 {
                MetadataBackgroundFetcher.shared.scheduleExtraPass(container: modelContext.container)
            }
        }
    }

    private func play(_ game: LibraryGame) {
        let gameID = game.id
        var descriptor = FetchDescriptor<LibraryGame>(
            predicate: #Predicate { $0.id == gameID }
        )
        descriptor.fetchLimit = 1
        guard let fresh = try? modelContext.fetch(descriptor).first else {
            NSLog("Play: library game no longer in store (id: \(gameID))")
            return
        }
        if let emulatorID = fresh.emulatorUUID {
            var emuDescriptor = FetchDescriptor<EmulatorProfile>(
                predicate: #Predicate { $0.id == emulatorID }
            )
            emuDescriptor.fetchLimit = 1
            guard let recovered = try? modelContext.fetch(emuDescriptor).first else {
                scanFeedback = "The emulator for this game is missing. Recreate/import the emulator, then run Scan Paths."
                return
            }
            // Force a valid relationship object before launching to avoid stale SwiftData relationship traps.
            fresh.emulator = recovered
        } else {
            fresh.emulator = nil
        }
        if fresh.needsROMMDownload {
            downloadFromROMM(fresh, launchAfter: true)
            return
        }
        launch(fresh)
    }

    /// Downloads into the emulator's only game folder, or asks which one when there are several.
    private func downloadFromROMM(_ game: LibraryGame, launchAfter: Bool) {
        guard !RommSync.shared.downloading.contains(game.id) else { return }
        let emulator = game.emulatorUUID.flatMap { id in emulators.first { $0.id == id } }
        let folders = RommSync.downloadFolders(for: emulator)
        switch folders.count {
        case 0:
            scanFeedback = "Add a game folder for \(emulator?.name ?? "this emulator") in Paths, then download again."
        case 1:
            startROMMDownload(gameID: game.id, folder: folders[0], launchAfter: launchAfter)
        default:
            pendingROMMDownload = PendingROMMDownload(gameID: game.id, title: game.libraryListTitle, folders: folders, launchAfter: launchAfter)
        }
    }

    private func startROMMDownload(gameID: UUID, folder: URL, launchAfter: Bool) {
        guard let game = games.first(where: { $0.id == gameID }) else { return }
        Task {
            do {
                try await RommSync.shared.download(game, into: folder, modelContext: modelContext)
                if launchAfter { launch(game) }
            } catch {
                scanFeedback = "ROMM download failed: \(error.localizedDescription)"
            }
        }
    }

    private func launch(_ fresh: LibraryGame) {
        do {
            let override = fresh.launchEmulatorIDString
                .flatMap(UUID.init(uuidString:))
                .flatMap { id in emulators.first { $0.id == id } }
            try GameLauncher.launch(game: fresh, launchEmulator: override)
            fresh.lastPlayed = Date()
            try modelContext.save()
        } catch {
            scanFeedback = "Launch failed: \(error.localizedDescription)"
            NSLog("%@", error.localizedDescription)
        }
    }

    private func deleteGame(_ game: LibraryGame) {
        let storefrontIdentity = game.storefront.flatMap { store in
            game.storefrontGameID.map { store.blocklistIdentity(gameID: $0) }
        }
        let rommIdentity = game.rommImported == true ? game.rommRomID.map(RommSync.blocklistIdentity(romID:)) : nil
        LibraryBlocklist.add(
            path: game.romPath,
            title: game.libraryListTitle,
            sourceName: game.emulator?.name ?? game.storefront?.displayName,
            identity: storefrontIdentity ?? rommIdentity
        )
        modelContext.delete(game)
    }

    private func removeEveryGameFromLibrary() {
        let snapshot = games
        for game in snapshot {
            modelContext.delete(game)
        }
        try? modelContext.save()
    }

    private func removeAllGames(forEmulatorID emulatorID: UUID) {
        let emulatorRoots = gameRoots(forEmulatorID: emulatorID)
        let snapshot = games.filter { game in
            if game.emulatorUUID == emulatorID {
                return true
            }
            return isPath(game.romPath, insideAny: emulatorRoots)
        }
        for game in snapshot {
            modelContext.delete(game)
        }
        try? modelContext.save()
    }

    private func removeAllMacGames() {
        let snapshot = games.filter { $0.emulatorUUID == nil }
        for game in snapshot {
            modelContext.delete(game)
        }
        try? modelContext.save()
    }

    private func gameRoots(forEmulatorID emulatorID: UUID) -> [String] {
        guard let emulator = emulators.first(where: { $0.id == emulatorID }) else { return [] }
        return emulator.folderPaths
            .filter { $0.resolvedPurpose == .games }
            .map { normalizedPathForComparison($0.folderPath) }
            .sorted { $0.count > $1.count }
    }

    private func isPath(_ path: String, insideAny roots: [String]) -> Bool {
        let normalizedPath = normalizedPathForComparison(path)
        for root in roots {
            if normalizedPath == root { return true }
            if normalizedPath.hasPrefix(root + "/") { return true }
        }
        return false
    }

    private func normalizedPathForComparison(_ path: String) -> String {
        var normalized = (path as NSString).standardizingPath
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized.lowercased()
    }

    private func addManualMacGame() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a Mac game app or executable file."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let standardizedPath = (url.path as NSString).standardizingPath
            let normalized = normalizedPathForComparison(standardizedPath)
            DispatchQueue.main.async {
                if games.contains(where: { normalizedPathForComparison($0.romPath) == normalized }) {
                    scanFeedback = "That game is already in your library."
                    return
                }
                LibraryBlocklist.remove(path: standardizedPath)
                let baseTitle = URL(fileURLWithPath: standardizedPath).deletingPathExtension().lastPathComponent
                let title = baseTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Mac Game" : baseTitle
                let nextSort = (games.map(\.sortOrder).max() ?? -1) + 1
                let game = LibraryGame(
                    title: title,
                    romPath: standardizedPath,
                    emulatorIDString: nil,
                    emulator: nil,
                    sortOrder: nextSort
                )
                modelContext.insert(game)
                do {
                    try modelContext.save()
                } catch {
                    scanFeedback = "Could not add game: \(error.localizedDescription)"
                }
            }
        }
    }

    @discardableResult
    private func removeOrphanedGamesFromLibrary() -> Int {
        let validIDs = activeEmulatorIDs
        var removed = 0
        for game in games {
            guard let emulatorID = game.emulatorUUID, !validIDs.contains(emulatorID) else { continue }
            modelContext.delete(game)
            removed += 1
        }
        if removed > 0 {
            try? modelContext.save()
            DebugLog.log("Cleanup: removed orphaned library games count=\(removed)")
        }
        return removed
    }
}

// MARK: - Library grid (main column)

private struct LibraryGamesGridView: View {
    let games: [LibraryGame]
    let coverAspects: [UUID: CoverAspectRatio]
    @Binding var actionOverlayGameID: UUID?
    @Binding var inspectorGameID: UUID?
    let onPlay: (LibraryGame) -> Void
    let onDelete: (LibraryGame) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: LibraryGridMetrics.cardWidth, maximum: LibraryGridMetrics.cardWidth), spacing: LibraryGridMetrics.horizontalSpacing, alignment: .top)
    ]

    var body: some View {
        Group {
            if games.isEmpty {
                ContentUnavailableView(
                    "No games",
                    systemImage: "gamecontroller",
                    description: Text("Use Paths and Scan Paths to import games, or add a game manually.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: LibraryGridMetrics.verticalSpacing) {
                        ForEach(games) { game in
                            GameLibraryTile(
                                game: game,
                                coverAspect: game.emulatorUUID.flatMap { coverAspects[$0] } ?? .default,
                                showsActionOverlay: actionOverlayGameID == game.id,
                                onCardTap: {
                                    if actionOverlayGameID == game.id {
                                        actionOverlayGameID = nil
                                    } else {
                                        actionOverlayGameID = game.id
                                    }
                                },
                                onPlay: {
                                    actionOverlayGameID = nil
                                    onPlay(game)
                                },
                                onInfo: {
                                    actionOverlayGameID = nil
                                    inspectorGameID = game.id
                                }
                            )
                            .contextMenu {
                                Button("Play", systemImage: "play.fill") { onPlay(game) }
                                Button("Details…", systemImage: "info.circle") {
                                    inspectorGameID = game.id
                                }
                                Divider()
                                Button("Remove from Library", systemImage: "trash", role: .destructive) {
                                    onDelete(game)
                                }
                            }
                        }
                    }
                    .padding(LibraryGridMetrics.outerPadding)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum LibraryGridMetrics {
    static let cardWidth: CGFloat = 160
    static let titleHeight: CGFloat = 52 // reserve up to ~3 lines so rows align
    static let horizontalSpacing: CGFloat = 16
    static let verticalSpacing: CGFloat = 20
    static let outerPadding: CGFloat = 20
}

private struct GameLibraryTile: View {
    let game: LibraryGame
    let coverAspect: CoverAspectRatio
    let showsActionOverlay: Bool
    let onCardTap: () -> Void
    let onPlay: () -> Void
    let onInfo: () -> Void

    private var coverHeight: CGFloat {
        coverAspect.height(forWidth: LibraryGridMetrics.cardWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                CachedCoverThumbnail(urlString: game.coverImageURLString)
                    .frame(width: LibraryGridMetrics.cardWidth, height: coverHeight)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    }
                    .overlay(alignment: .topTrailing) {
                        if game.isInstalledStorefrontGame {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .green)
                                .shadow(color: .black.opacity(0.4), radius: 2)
                                .padding(6)
                                .help("Installed")
                        } else if let label = DiscGroupService.discLabel(for: game), game.discGroupIDString != nil {
                            Text(label)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.65), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(6)
                        }
                    }

                if RommSync.shared.downloading.contains(game.id) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.55))
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.regular)
                        Text("Downloading from ROMM…")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .allowsHitTesting(false)
                }

                if showsActionOverlay {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.45))
                        .allowsHitTesting(false)

                    HStack(spacing: 28) {
                        Button {
                            onPlay()
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 40))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor.opacity(0.95))
                        }
                        .buttonStyle(.plain)
                        .help("Play")

                        Button {
                            onInfo()
                        } label: {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 40))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Game details and cover")
                    }
                }
            }
            .frame(width: LibraryGridMetrics.cardWidth, height: coverHeight)

            Text(game.libraryListTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(width: LibraryGridMetrics.cardWidth, height: LibraryGridMetrics.titleHeight, alignment: .top)
        }
        .frame(width: LibraryGridMetrics.cardWidth, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onCardTap)
        .help("Show actions for \(game.libraryListTitle)")
    }
}

// MARK: - Inspector (cover + display name)

private struct LibraryGameInspectorView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var game: LibraryGame
    let allGames: [LibraryGame]
    let emulators: [EmulatorProfile]
    var coverAspect: CoverAspectRatio
    var onDismiss: () -> Void
    var onDownloadFromROMM: () -> Void

    @State private var showCoverSearch = false
    @State private var showDiscGroupLinkSheet = false

    var body: some View {
        Form {
            Section {
                TextField("Name in library", text: nameBinding, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Text("Renames how this game appears here only. The file on disk is not renamed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if game.emulatorUUID == nil {
                    TextField("Game path", text: pathBinding, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    Text("Edit the app/executable path for this Mac game, or choose a new target.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Choose Game…", systemImage: "folder") {
                            pickGamePath()
                        }
                        Spacer()
                    }
                } else {
                    LabeledContent("File") {
                        Text(URL(fileURLWithPath: game.romPath).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Path") {
                        if game.isFilePresent {
                            Button {
                                revealROMInFinder()
                            } label: {
                                Text((game.romPath as NSString).standardizingPath)
                                    .font(.caption)
                                    .foregroundStyle(Color(nsColor: .linkColor))
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .buttonStyle(.plain)
                            .help("Show in Finder")
                        } else {
                            Text("Not present")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    if game.needsROMMDownload {
                        HStack(spacing: 8) {
                            Spacer()
                            if RommSync.shared.downloading.contains(game.id) {
                                ProgressView().controlSize(.small)
                                Text("Downloading…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("Download From ROMM", systemImage: "arrow.down.circle") {
                                    onDownloadFromROMM()
                                }
                            }
                        }
                    }
                }
            }

            if let status = game.rommStatus {
                Section("ROMM") {
                    LabeledContent("Status") {
                        Text(status == RommStatus.inROMM ? "In ROMM" : "Missing")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(status == RommStatus.inROMM ? .green : .orange)
                    }
                    if let rommPath = game.rommPath {
                        LabeledContent("ROMM path") {
                            Button {
                                if let romID = game.rommRomID, let url = RommClient.webURL(romID: romID) {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Text(rommPath)
                                    .font(.caption)
                                    .foregroundStyle(Color(nsColor: .linkColor))
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .buttonStyle(.plain)
                            .help("Open in ROMM")
                        }
                    }
                    if status == RommStatus.missing {
                        Text("No game with a matching name is in the linked ROMM platform.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let libraryEmulatorID = game.emulatorUUID {
                Section("Launch with") {
                    Picker("Emulator", selection: launchEmulatorBinding(libraryEmulatorID: libraryEmulatorID)) {
                        Text("\(emulators.first { $0.id == libraryEmulatorID }?.name ?? "Library emulator") (default)")
                            .tag(UUID?.none)
                        Divider()
                        ForEach(emulators.filter { $0.id != libraryEmulatorID }, id: \.id) { emulator in
                            Text(emulator.name).tag(UUID?.some(emulator.id))
                        }
                    }
                    Text("Only changes which emulator opens this game. It stays in its current library section.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Multi-disc set") {
                let linked = DiscGroupService.linkedGames(for: game, context: modelContext)
                if linked.isEmpty {
                    Text("Link multiple disc files (e.g. Final Fantasy IX Disc 1–4) so cover art and ScreenScraper metadata stay in sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Link with other discs…", systemImage: "link") {
                        showDiscGroupLinkSheet = true
                    }
                    let suggestedCount = DiscGroupService.suggestedLinkCandidates(for: game, among: allGames).count
                    if suggestedCount > 0 {
                        Button("Link \(suggestedCount) suggested disc\(suggestedCount == 1 ? "" : "s")", systemImage: "sparkles") {
                            var toLink = [game]
                            toLink.append(contentsOf: DiscGroupService.suggestedLinkCandidates(for: game, among: allGames))
                            DiscGroupService.link(toLink, context: modelContext)
                        }
                    }
                } else {
                    Text("\(linked.count) discs share cover art and metadata.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Use the arrows to set disc order in the library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(Array(linked.enumerated()), id: \.element.id) { index, linkedGame in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(linkedGame.libraryListTitle)
                                Text(URL(fileURLWithPath: linkedGame.romPath).lastPathComponent)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let label = DiscGroupService.discLabel(for: linkedGame) {
                                Text(label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            VStack(spacing: 2) {
                                Button {
                                    moveLinkedDisc(at: index, direction: -1, in: linked)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.plain)
                                .disabled(index == 0)
                                .help("Move earlier in library")

                                Button {
                                    moveLinkedDisc(at: index, direction: 1, in: linked)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.plain)
                                .disabled(index >= linked.count - 1)
                                .help("Move later in library")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Button("Reset order from filenames", systemImage: "arrow.counterclockwise") {
                        guard game.discGroupIDString != nil else { return }
                        let discs = DiscGroupService.linkedGames(for: game, context: modelContext)
                        DiscGroupService.normalizeDiscOrderFromFilenames(discs, context: modelContext)
                    }
                    Button("Add or change linked discs…", systemImage: "link") {
                        showDiscGroupLinkSheet = true
                    }
                    Button("Unlink this disc", systemImage: "link.slash", role: .destructive) {
                        DiscGroupService.unlink(game, context: modelContext)
                    }
                }
            }

            Section("Cover art") {
                HStack(alignment: .top, spacing: 16) {
                    CachedCoverThumbnail(urlString: game.coverImageURLString)
                        .frame(
                            width: 120,
                            height: coverAspect.height(forWidth: 120)
                        )
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        }

                    VStack(alignment: .leading, spacing: 10) {
                        Button("Choose Image…", systemImage: "photo") {
                            pickCoverImage()
                        }
                        if !CoverProvider.configured.isEmpty {
                            Button("Search for Covers…", systemImage: "sparkle.magnifyingglass") {
                                showCoverSearch = true
                            }
                        }
                        if game.screenScraperSelectionSkipped {
                            Text("Automatic ScreenScraper matching skipped for this game.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Allow auto-match again", systemImage: "arrow.counterclockwise") {
                                game.screenScraperSelectionSkipped = false
                                try? modelContext.save()
                            }
                        }
                        if game.coverImageURLString != nil {
                            Button("Clear current cover", systemImage: "xmark.circle", role: .destructive) {
                                applyCoverMutation {
                                    game.coverImageURLString = nil
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !game.coverImageOptions.isEmpty {
                    Text("Detected covers")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 8) {
                        ForEach(Array(game.coverImageOptions.enumerated()), id: \.offset) { index, option in
                            HStack(spacing: 10) {
                                CachedCoverThumbnail(urlString: option)
                                    .frame(width: 42, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(URL(string: option)?.lastPathComponent ?? option)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .textSelection(.enabled)

                                Spacer()

                                Button {
                                    setPrimaryCover(index: index)
                                } label: {
                                    Image(systemName: game.coverImageURLString == option ? "checkmark.circle.fill" : "circle")
                                }
                                .buttonStyle(.plain)
                                .help("Use as current cover")

                                Button {
                                    moveCover(from: index, direction: -1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .buttonStyle(.plain)
                                .disabled(index == 0)
                                .help("Move up")

                                Button {
                                    moveCover(from: index, direction: 1)
                                } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .buttonStyle(.plain)
                                .disabled(index >= game.coverImageOptions.count - 1)
                                .help("Move down")

                                Button(role: .destructive) {
                                    removeCover(at: index)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .help("Remove from lineup")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(game.libraryListTitle)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    onDismiss()
                } label: {
                    Label("Done", systemImage: "sidebar.right")
                }
                .help("Hide game details")
            }
        }
        .sheet(isPresented: $showCoverSearch) {
            CoverSearchSheet(
                libraryGameId: game.id,
                initialTitle: game.libraryListTitle,
                initialSystemId: MetadataSystemResolver.systemId(
                    for: game,
                    emulator: EmulatorProfileLookup.resolve(for: game, context: modelContext)
                )
            )
        }
        .sheet(isPresented: $showDiscGroupLinkSheet) {
            DiscGroupLinkSheet(anchorGame: game, allGames: allGames)
        }
    }

    private func applyCoverMutation(_ mutation: () -> Void) {
        mutation()
        DiscGroupService.propagateSharedState(from: game, context: modelContext)
        try? modelContext.save()
    }

    private func moveLinkedDisc(at index: Int, direction: Int, in linked: [LibraryGame]) {
        guard let groupID = game.discGroupIDString else { return }
        DiscGroupService.moveDisc(in: groupID, from: index, direction: direction, context: modelContext)
    }

    private func revealROMInFinder() {
        let path = (game.romPath as NSString).standardizingPath
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            let parent = url.deletingLastPathComponent().path
            guard FileManager.default.fileExists(atPath: parent) else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: parent))
            return
        }
        if isDirectory.boolValue {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func launchEmulatorBinding(libraryEmulatorID: UUID) -> Binding<UUID?> {
        Binding(
            get: {
                game.launchEmulatorIDString
                    .flatMap(UUID.init(uuidString:))
                    .flatMap { id in emulators.contains { $0.id == id } && id != libraryEmulatorID ? id : nil }
            },
            set: { newValue in
                game.launchEmulatorIDString = newValue?.uuidString
                try? modelContext.save()
            }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: {
                game.libraryDisplayName ?? game.title
            },
            set: { new in
                let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    game.libraryDisplayName = nil
                } else if trimmed == game.title {
                    game.libraryDisplayName = nil
                } else {
                    game.libraryDisplayName = trimmed
                }
                try? modelContext.save()
            }
        )
    }

    private var pathBinding: Binding<String> {
        Binding(
            get: {
                game.romPath
            },
            set: { new in
                let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                game.romPath = (trimmed as NSString).standardizingPath
                try? modelContext.save()
            }
        )
    }

    private func pickCoverImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let path = (url.path as NSString).standardizingPath
            let fileURL = URL(fileURLWithPath: path)
            DispatchQueue.main.async {
                applyCoverMutation {
                    var options = game.coverImageOptions
                    let candidate = fileURL.absoluteString
                    if !options.contains(candidate) {
                        options.insert(candidate, at: 0)
                    }
                    game.coverImageOptions = options
                    game.coverImageURLString = candidate
                }
            }
        }
    }

    private func pickGamePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let path = (url.path as NSString).standardizingPath
            DispatchQueue.main.async {
                game.romPath = path
                try? modelContext.save()
            }
        }
    }

    private func setPrimaryCover(index: Int) {
        let options = game.coverImageOptions
        guard options.indices.contains(index) else { return }
        applyCoverMutation {
            game.coverImageURLString = options[index]
        }
    }

    private func removeCover(at index: Int) {
        var options = game.coverImageOptions
        guard options.indices.contains(index) else { return }
        applyCoverMutation {
            let removed = options.remove(at: index)
            game.coverImageOptions = options
            if game.coverImageURLString == removed {
                game.coverImageURLString = options.first
            }
        }
    }

    private func moveCover(from index: Int, direction: Int) {
        var options = game.coverImageOptions
        guard options.indices.contains(index) else { return }
        let target = index + direction
        guard options.indices.contains(target) else { return }
        applyCoverMutation {
            let item = options.remove(at: index)
            options.insert(item, at: target)
            game.coverImageOptions = options
        }
    }
}

extension LibraryGame: Hashable {
    public static func == (lhs: LibraryGame, rhs: LibraryGame) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

#Preview {
    RootView()
        .modelContainer(for: [EmulatorProfile.self, LibraryGame.self, GameFolderPath.self], inMemory: true)
}

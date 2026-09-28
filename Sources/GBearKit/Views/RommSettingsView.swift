import SwiftData
import SwiftUI

/// ROMM detail pane: server connection, platform → emulator links, and sync.
struct RommSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var sync: RommSync
    let emulators: [EmulatorProfile]
    let games: [LibraryGame]
    let onSync: () -> Void

    @State private var serverURL = RommCredentials.serverURL ?? ""
    @State private var username = RommCredentials.username ?? ""
    @State private var password = RommCredentials.password ?? ""
    @State private var revision = 0
    @State private var confirmClearSync = false
    @State private var clearResult: String?

    /// Keychain state is not observable; reading `revision` re-evaluates after connect / sign out.
    private var isConfigured: Bool { _ = revision; return RommCredentials.isConfigured }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                serverCard
                platformsCard
                syncCard
                helpText
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            if isConfigured, sync.platforms.isEmpty, !sync.isConnecting {
                await sync.connect()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ROMM")
                .font(.title3.weight(.semibold))
            Text(
                "Connect to your ROMM server and link each ROMM platform to an emulator. The emulator's collection then shows " +
                    "which games are in ROMM, and you can choose to add the ROMM games you don't have yet."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var serverCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: connected ? "server.rack" : "exclamationmark.icloud")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(connected ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connected ? "Connected" : (isConfigured ? "Not connected" : "Not set up"))
                            .font(.headline)
                        if connected, let version = sync.serverVersion {
                            Text("ROMM \(version) · \(sync.platforms.count) platform(s)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                TextField("Server address (e.g. http://192.168.1.20:8080)", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    if isConfigured {
                        Button("Sign Out", role: .destructive) {
                            sync.disconnect()
                            password = ""
                            revision += 1
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer(minLength: 8)
                    if sync.isConnecting {
                        ProgressView().controlSize(.small)
                    }
                    Button("Connect") {
                        RommCredentials.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        RommCredentials.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
                        RommCredentials.password = password
                        revision += 1
                        Task { await sync.connect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(serverURL.isEmpty || username.isEmpty || password.isEmpty || sync.isConnecting)
                }
                if let error = sync.connectionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Server", systemImage: "network")
        }
    }

    private var connected: Bool { isConfigured && !sync.platforms.isEmpty && sync.connectionError == nil }

    private var platformsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if sync.platforms.isEmpty {
                    Text("Connect to list your ROMM platforms.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        ForEach(sync.platforms) { platform in
                            GridRow {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(platform.name)
                                    Text("\(platform.romCount) game(s)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Picker("", selection: linkBinding(platform.id)) {
                                    Text("Not linked").tag(UUID?.none)
                                    ForEach(emulators, id: \.id) { emulator in
                                        Text(emulator.name).tag(UUID?.some(emulator.id))
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 280)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Link platforms to emulators", systemImage: "link")
        }
    }

    private func linkBinding(_ platformID: Int) -> Binding<UUID?> {
        Binding(
            get: { sync.links[platformID].flatMap { id in emulators.contains { $0.id == id } ? id : nil } },
            set: { sync.setLink(platformID: platformID, emulatorID: $0) }
        )
    }

    private var syncCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                let inROMM = games.filter(\.isInROMM).count
                let missing = games.filter { $0.rommStatus == RommStatus.missing }.count
                let notOnMac = games.filter { $0.rommImported == true }.count
                Text("\(inROMM) in ROMM, \(missing) missing from ROMM, \(notOnMac) in the library but not on this Mac")
                    .font(.subheadline)
                HStack(spacing: 10) {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { onSync() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isConfigured || sync.isSyncing || sync.links.isEmpty)
                    Toggle(
                        "Add games to library that are not on this Mac",
                        isOn: Binding(get: { sync.addGamesNotOnMac }, set: { sync.setAddGamesNotOnMac($0) })
                    )
                    .toggleStyle(.checkbox)
                    if sync.isSyncing {
                        ProgressView().controlSize(.small)
                        Text(sync.status ?? "Syncing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(
                    "Off by default: only games already on this Mac get a ROMM status. When on, ROMM games you don't have join " +
                        "the library with Path \"Not present\" and a Download From ROMM button. Hidden files (like .DS_Store and ._ files) " +
                        "and non-game files (text, images, saves, and anything the linked emulator can't open) are never added or counted."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let summary = sync.lastSummary, let at = sync.lastSyncAt, !sync.isSyncing {
                    let parts = summary.feedbackParts
                    Text(
                        "Last sync \(at.formatted(date: .omitted, time: .shortened)): " +
                            (parts.isEmpty ? "no linked games." : parts.joined(separator: ". ") + ".")
                    )
                    .font(.caption)
                    .foregroundStyle(summary.errors.isEmpty ? Color.secondary : Color.orange)
                }

                Divider()

                HStack(alignment: .top, spacing: 10) {
                    Button("Clear Sync", systemImage: "eraser", role: .destructive) {
                        confirmClearSync = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(sync.isSyncing)
                    Text(
                        "Clear Sync gives you a blank slate for the next sync. It removes every ROMM game that is not on this Mac " +
                            "from the library and clears the In ROMM / Missing status from all games. Games you downloaded from ROMM " +
                            "stay in the library, and no files are deleted. Your server login, platform links, and blocked list are kept."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let clearResult {
                    Text(clearResult)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Sync", systemImage: "arrow.down.circle")
        }
        .confirmationDialog("Clear ROMM sync?", isPresented: $confirmClearSync, titleVisibility: .visible) {
            Button("Clear Sync", role: .destructive) {
                let result = sync.clearSync(modelContext: modelContext)
                clearResult = "Cleared: removed \(result.removed) game(s) not on this Mac, reset the ROMM status on \(result.cleared) game(s)."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ROMM games that are not on this Mac leave the library and all ROMM statuses are reset. Downloaded games and files are kept.")
        }
    }

    private var helpText: some View {
        Text(
            "Games match by name, ignoring region tags like (USA) and file extensions. Scan Paths also syncs ROMM. " +
                "Download From ROMM in the info panel (or Play) saves a game to the emulator's game folder from Paths, " +
                "asking which one when there are several. " +
                "Your password is stored in your Keychain."
        )
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}

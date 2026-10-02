import AppKit
import SwiftData
import SwiftUI

/// Storefront Manager detail pane: which storefronts to use, a login card per storefront, and import.
struct StorefrontManagerView: View {
    @Bindable var settings: StorefrontSettings
    @Bindable var importer: StorefrontImporter
    let games: [LibraryGame]
    let onImport: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                storefrontsCard
                ForEach(Storefront.allCases) { store in
                    StorefrontLoginCard(store: store, settings: settings)
                }
                importCard
                helpText
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Storefront Manager")
                .font(.title3.weight(.semibold))
            Text(
                "Installed games from checked storefronts are imported automatically. Sign in to also add every game you own; " +
                    "installed games get a green check on their cover."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var storefrontsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Storefront.allCases) { store in
                    Toggle(
                        isOn: Binding(get: { settings.isEnabled(store) }, set: { settings.setEnabled(store, $0) })
                    ) {
                        Label(store.displayName, systemImage: store.systemImage)
                    }
                    .toggleStyle(.checkbox)
                }
                Text("Unchecked storefronts are not imported, and their games are hidden from the library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Storefronts", systemImage: "checklist")
        }
    }

    private var importCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Storefront.allCases) { store in
                    let storeGames = games.filter { $0.storefront == store }
                    let installed = storeGames.filter(\.isInstalledStorefrontGame).count
                    Text("\(store.displayName): \(storeGames.count) in the library, \(installed) installed")
                        .font(.subheadline)
                        .foregroundStyle(settings.isEnabled(store) ? .primary : .tertiary)
                }
                HStack(spacing: 10) {
                    Button("Import Storefront Installed Games", systemImage: "square.and.arrow.down") { onImport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(importer.isImporting || settings.enabled.isEmpty)
                    if importer.isImporting {
                        ProgressView().controlSize(.small)
                        Text(importer.status ?? "Importing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let summary = importer.lastSummary, let at = importer.lastImportAt, !importer.isImporting {
                    let parts = summary.feedbackParts
                    Text(
                        "Last import \(at.formatted(date: .omitted, time: .shortened)): " +
                            (parts.isEmpty ? "no changes." : parts.joined(separator: ". ") + ".")
                    )
                    .font(.caption)
                    .foregroundStyle(summary.errors.isEmpty ? Color.secondary : Color.orange)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Import", systemImage: "arrow.down.circle")
        }
    }

    private var helpText: some View {
        Text(
            "Import runs for every checked storefront, and Scan Paths runs it too. Without a sign-in only installed games are added, " +
                "and a game you uninstall leaves the library on the next import. Steam games open through Steam, Epic games through " +
                "the Epic Games Launcher, and GOG games directly (or in GOG Galaxy when not installed). " +
                "Sign-in tokens and the Steam key are stored in your Keychain."
        )
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}

/// Login card for one storefront, with its installed-only filter.
private struct StorefrontLoginCard: View {
    let store: Storefront
    @Bindable var settings: StorefrontSettings

    @State private var showLogin = false
    @State private var revision = 0
    @State private var steamAPIKey = StorefrontCredentials.steamAPIKey ?? ""
    @State private var statusMessage: String?
    @State private var statusIsError = false

    /// Keychain state is not observable; reading `revision` re-evaluates these after sign-in changes.
    private var signedIn: Bool { _ = revision; return StorefrontCredentials.isSignedIn(store) }

    private var hasAnySignIn: Bool {
        _ = revision
        switch store {
        case .steam: return !(StorefrontCredentials.steamID ?? "").isEmpty
        case .epic, .gog: return signedIn
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: signedIn ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle.badge.plus")
                        .font(.system(size: 32))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(signedIn ? .green : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(signedIn ? "Signed in" : "Not signed in")
                            .font(.headline)
                        if let name = StorefrontCredentials.accountName(for: store), hasAnySignIn {
                            Label(name, systemImage: "person")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 12)
                    Toggle(
                        "Only show installed games in library",
                        isOn: Binding(get: { settings.showsOnlyInstalled(store) }, set: { settings.setOnlyInstalled(store, $0) })
                    )
                    .toggleStyle(.checkbox)
                }

                HStack(spacing: 8) {
                    if hasAnySignIn {
                        Button("Sign Out", role: .destructive) {
                            StorefrontCredentials.signOut(store)
                            signInChanged("Signed out. The next import keeps only installed \(store.displayName) games.")
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer(minLength: 8)
                    Button(hasAnySignIn ? "Sign In Again…" : "Sign In…") {
                        showLogin = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                if store == .steam {
                    steamKeyFields
                }

                if let statusMessage {
                    Label(statusMessage, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(statusIsError ? .orange : .green)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 6) {
                Label("\(store.displayName) login", systemImage: store.systemImage)
                if !settings.isEnabled(store) {
                    Text("(unchecked — not imported)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $showLogin) {
            StorefrontLoginSheet(store: store) {
                signInChanged("Signed in to \(store.displayName). Import to add your whole library.")
            }
        }
    }

    private var steamKeyFields: some View {
        DisclosureGroup("Steam Web API key (optional)") {
            steamKeyForm
                .padding(.top, 6)
        }
        .font(.caption)
    }

    private var steamKeyForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "Not needed after signing in. If Steam ever refuses the sign-in token for your game list, " +
                    "GBear falls back to your own Web API key."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                SecureField("Steam Web API key", text: $steamAPIKey)
                    .textFieldStyle(.roundedBorder)
                Button("Save key") {
                    let trimmed = steamAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    StorefrontCredentials.steamAPIKey = trimmed
                    steamAPIKey = trimmed
                    Task {
                        if let name = await SteamClient.personaName() {
                            StorefrontCredentials.setAccountName(name, for: .steam)
                        }
                        signInChanged(trimmed.isEmpty ? "Steam key removed." : "Steam Web API key saved.")
                    }
                }
                .buttonStyle(.bordered)
            }
            Link("Get a Steam Web API key", destination: URL(string: "https://steamcommunity.com/dev/apikey")!)
                .font(.caption)
            if let steamID = StorefrontCredentials.steamID, hasAnySignIn {
                Text("SteamID: \(steamID)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private func signInChanged(_ message: String) {
        revision += 1
        setStatus(message, isError: false)
    }
}

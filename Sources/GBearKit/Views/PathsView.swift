import AppKit
import SwiftData
import SwiftUI

struct PathsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\EmulatorProfile.name, comparator: .localizedStandard)]) private var emulators: [EmulatorProfile]
    @Query(sort: \GameFolderPath.sortOrder) private var allFolderPaths: [GameFolderPath]

    @State private var selectedEmulatorID: UUID?
    @State private var pendingDeletePathIDs: [UUID] = []
    @State private var pendingDeleteSectionTitle: String = ""
    @State private var pasteFeedback: String?

    /// Resolved picker value when `emulators` is non-empty (avoids Picker tag/`nil` mismatch).
    private var effectiveEmulatorID: UUID {
        guard let first = emulators.first else {
            return UUID()
        }
        if let id = selectedEmulatorID, emulators.contains(where: { $0.id == id }) {
            return id
        }
        return first.id
    }

    private var gameFoldersForSelection: [GameFolderPath] {
        guard !emulators.isEmpty else { return [] }
        let id = effectiveEmulatorID
        return allFolderPaths.filter { $0.emulator?.id == id && $0.resolvedPurpose == .games }
    }

    private var coverFoldersForSelection: [GameFolderPath] {
        guard !emulators.isEmpty else { return [] }
        let id = effectiveEmulatorID
        return allFolderPaths.filter { $0.emulator?.id == id && $0.resolvedPurpose == .covers }
    }

    private var excludedFoldersForSelection: [GameFolderPath] {
        guard !emulators.isEmpty else { return [] }
        let id = effectiveEmulatorID
        return allFolderPaths.filter { $0.emulator?.id == id && $0.resolvedPurpose == .excludes }
    }

    private var selectedEmulator: EmulatorProfile? {
        guard !emulators.isEmpty else { return nil }
        return emulators.first(where: { $0.id == effectiveEmulatorID })
    }

    var body: some View {
        Group {
            if emulators.isEmpty {
                ContentUnavailableView(
                    "No emulators",
                    systemImage: "gearshape.2",
                    description: Text("Add an emulator in the Emulators tab first, then choose folders here.")
                )
            } else {
                Form {
                    Section {
                        Picker("Emulator", selection: Binding(
                            get: { effectiveEmulatorID },
                            set: { selectedEmulatorID = $0 }
                        )) {
                            ForEach(emulators) { emu in
                                Text(emu.name).tag(emu.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Section("Game folders for this emulator") {
                        Text("Scan looks only at this folder’s files and immediate subfolders. Each file and each subfolder is one game (bin/cue sets in a folder stay one title). Nested folders inside a game folder are not scanned.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if gameFoldersForSelection.isEmpty {
                            Text("No folders yet. Use “Add folder…” to pick a directory to scan.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(gameFoldersForSelection) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(entry.folderPath)
                                        .font(.body)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    Button(role: .destructive) {
                                        requestDelete(paths: [entry], sectionTitle: "game folder")
                                    } label: {
                                        Label("Delete game folder path", systemImage: "trash")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove this game folder path")
                                }
                                .padding(.vertical, 2)
                            }
                            .onDelete(perform: deleteGamePaths)
                        }

                        HStack(spacing: 10) {
                            Button("Add folder", systemImage: "folder.badge.plus") {
                                addGameFolder()
                            }
                            Button("Paste path", systemImage: "doc.on.clipboard") {
                                pasteGameFolder()
                            }
                        }
                        if let emulator = selectedEmulator {
                            Toggle("Auto-link multi-disc games on scan", isOn: Binding(
                                get: { emulator.autoLinkMultiDiscGames },
                                set: { newValue in
                                    emulator.autoLinkMultiDiscGames = newValue
                                    try? modelContext.save()
                                }
                            ))
                            Text("When enabled, scanning the library links discs with matching titles (e.g. Final Fantasy IX Disc 1–4) so cover art and ScreenScraper metadata stay in sync.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Covers for this emulator") {
                        Text("Add folders that contain cover images. On scan, a file whose name matches a ROM (same name before the extension) is used as that game’s cover.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let emulator = selectedEmulator {
                            Toggle("Prioritize ScreenScraper art over local covers", isOn: Binding(
                                get: { emulator.preferScreenScraperCovers },
                                set: { newValue in
                                    emulator.preferScreenScraperCovers = newValue
                                    try? modelContext.save()
                                }
                            ))
                            Text("If off, local cover folders are preferred as the auto-selected primary cover. All discovered covers are still saved in the game’s cover list.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if coverFoldersForSelection.isEmpty {
                            Text("No cover folders yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(coverFoldersForSelection) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(entry.folderPath)
                                        .font(.body)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    Button(role: .destructive) {
                                        requestDelete(paths: [entry], sectionTitle: "cover folder")
                                    } label: {
                                        Label("Delete cover folder path", systemImage: "trash")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove this cover folder path")
                                }
                                .padding(.vertical, 2)
                            }
                            .onDelete(perform: deleteCoverPaths)
                        }

                        HStack(spacing: 10) {
                            Button("Add cover folder", systemImage: "photo.on.rectangle.angled") {
                                addCoverFolder()
                            }
                            Button("Paste path", systemImage: "doc.on.clipboard") {
                                pasteCoverFolder()
                            }
                        }
                    }

                    Section("Exclude these folders from Scans") {
                        Text("Anything inside these folders is skipped when scanning game folders for this emulator.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if excludedFoldersForSelection.isEmpty {
                            Text("No excluded folders yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(excludedFoldersForSelection) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(entry.folderPath)
                                        .font(.body)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    Button(role: .destructive) {
                                        requestDelete(paths: [entry], sectionTitle: "excluded folder")
                                    } label: {
                                        Label("Delete excluded folder path", systemImage: "trash")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove this excluded folder path")
                                }
                                .padding(.vertical, 2)
                            }
                            .onDelete(perform: deleteExcludedPaths)
                        }

                        HStack(spacing: 10) {
                            Button("Add folder…", systemImage: "folder.badge.minus") {
                                addExcludedFolder()
                            }
                            Button("Paste path", systemImage: "doc.on.clipboard") {
                                pasteExcludedFolder()
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 360)
        .navigationTitle("Paths")
        .onAppear {
            if selectedEmulatorID == nil {
                selectedEmulatorID = emulators.first?.id
            } else if let id = selectedEmulatorID, !emulators.contains(where: { $0.id == id }) {
                selectedEmulatorID = emulators.first?.id
            }
        }
        .onChange(of: emulators.map(\.id)) { _, ids in
            if let id = selectedEmulatorID, !ids.contains(id) {
                selectedEmulatorID = emulators.first?.id
            }
        }
        .confirmationDialog(
            "Remove selected \(pendingDeleteSectionTitle) path\(pendingDeletePathIDs.count == 1 ? "" : "s")?",
            isPresented: Binding(
                get: { !pendingDeletePathIDs.isEmpty },
                set: { isPresented in
                    if !isPresented {
                        pendingDeletePathIDs = []
                        pendingDeleteSectionTitle = ""
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                confirmDeletePendingPaths()
            }
            Button("Cancel", role: .cancel) {
                pendingDeletePathIDs = []
                pendingDeleteSectionTitle = ""
            }
        } message: {
            Text("This only removes the saved path from GBear Mac. Files on disk are not deleted.")
        }
        .alert("Paste path", isPresented: Binding(
            get: { pasteFeedback != nil },
            set: { if !$0 { pasteFeedback = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pasteFeedback ?? "")
        }
    }

    private func addGameFolder() {
        addFolder(purpose: .games)
    }

    private func pasteGameFolder() {
        pasteFolder(purpose: .games)
    }

    private func addCoverFolder() {
        addFolder(purpose: .covers)
    }

    private func pasteCoverFolder() {
        pasteFolder(purpose: .covers)
    }

    private func addExcludedFolder() {
        addFolder(purpose: .excludes)
    }

    private func pasteExcludedFolder() {
        pasteFolder(purpose: .excludes)
    }

    private func addFolder(purpose: GameFolderPurpose) {
        let emuID = effectiveEmulatorID
        guard let emulator = emulators.first(where: { $0.id == emuID }) else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let path = (url.path as NSString).standardizingPath
            DispatchQueue.main.async {
                let desc = FetchDescriptor<GameFolderPath>()
                let existing = (try? modelContext.fetch(desc)) ?? []
                if existing.contains(where: {
                    ($0.folderPath as NSString).standardizingPath == path
                        && $0.emulator?.id == emuID
                        && $0.resolvedPurpose == purpose
                }) {
                    return
                }
                let nextOrder = existing
                    .filter { $0.emulator?.id == emuID && $0.resolvedPurpose == purpose }
                    .map(\.sortOrder)
                    .max()
                    .map { $0 + 1 } ?? 0
                insertPath(
                    path,
                    emulator: emulator,
                    purpose: purpose,
                    existing: existing,
                    nextOrder: nextOrder
                )
            }
        }
    }

    private func pasteFolder(purpose: GameFolderPurpose) {
        let emuID = effectiveEmulatorID
        guard let emulator = emulators.first(where: { $0.id == emuID }) else { return }
        guard let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            pasteFeedback = "Clipboard is empty. Copy a folder path first."
            return
        }

        let resolvedPath = normalizePastedPath(raw)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir), isDir.boolValue else {
            pasteFeedback = "The pasted value is not an existing folder path:\n\(resolvedPath)"
            return
        }

        let standardized = (resolvedPath as NSString).standardizingPath
        let desc = FetchDescriptor<GameFolderPath>()
        let existing = (try? modelContext.fetch(desc)) ?? []
        if existing.contains(where: {
            ($0.folderPath as NSString).standardizingPath == standardized
                && $0.emulator?.id == emuID
                && $0.resolvedPurpose == purpose
        }) {
            pasteFeedback = "That path is already added for this emulator."
            return
        }

        let nextOrder = existing
            .filter { $0.emulator?.id == emuID && $0.resolvedPurpose == purpose }
            .map(\.sortOrder)
            .max()
            .map { $0 + 1 } ?? 0
        insertPath(
            standardized,
            emulator: emulator,
            purpose: purpose,
            existing: existing,
            nextOrder: nextOrder
        )
    }

    private func insertPath(
        _ path: String,
        emulator: EmulatorProfile,
        purpose: GameFolderPurpose,
        existing: [GameFolderPath],
        nextOrder: Int
    ) {
        if existing.contains(where: {
            ($0.folderPath as NSString).standardizingPath == path
                && $0.emulator?.id == emulator.id
                && $0.resolvedPurpose == purpose
        }) {
            return
        }
        let entry = GameFolderPath(
            folderPath: path,
            emulator: emulator,
            sortOrder: nextOrder,
            folderPurpose: purpose.rawValue
        )
        modelContext.insert(entry)
    }

    private func normalizePastedPath(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value.removeFirst()
            value.removeLast()
        }

        if let fileURL = URL(string: value), fileURL.isFileURL {
            value = fileURL.path
        }

        value = (value as NSString).expandingTildeInPath
        return (value as NSString).standardizingPath
    }

    private func deleteGamePaths(at offsets: IndexSet) {
        let toDelete = offsets.map { gameFoldersForSelection[$0] }
        requestDelete(paths: toDelete, sectionTitle: "game folder")
    }

    private func deleteCoverPaths(at offsets: IndexSet) {
        let toDelete = offsets.map { coverFoldersForSelection[$0] }
        requestDelete(paths: toDelete, sectionTitle: "cover folder")
    }

    private func deleteExcludedPaths(at offsets: IndexSet) {
        let toDelete = offsets.map { excludedFoldersForSelection[$0] }
        requestDelete(paths: toDelete, sectionTitle: "excluded folder")
    }

    private func requestDelete(paths: [GameFolderPath], sectionTitle: String) {
        pendingDeletePathIDs = paths.map(\.id)
        pendingDeleteSectionTitle = sectionTitle
    }

    private func confirmDeletePendingPaths() {
        let ids = Set(pendingDeletePathIDs)
        let toDelete = allFolderPaths.filter { ids.contains($0.id) }
        for item in toDelete {
            modelContext.delete(item)
        }
        pendingDeletePathIDs = []
        pendingDeleteSectionTitle = ""
    }
}

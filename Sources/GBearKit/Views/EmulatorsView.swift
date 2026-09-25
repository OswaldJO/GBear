import AppKit
import SwiftData
import SwiftUI

/// One selectable row in the bundled catalog or a user-added “Default Launch Arguments” preset.
private enum LibraryProfileRow: Identifiable {
    case builtin(BuiltinEmulatorProfileRecord)
    case custom(CustomEmulatorLibraryEntry)

    var id: String {
        switch self {
        case .builtin(let r): return "builtin-\(r.catalogId)"
        case .custom(let e): return "custom-\(e.id.uuidString)"
        }
    }

    var sortTitle: String {
        switch self {
        case .builtin(let r): return r.displayTitle
        case .custom(let e): return e.displayTitle
        }
    }
}

private struct EmulatorTransferRecord: Codable {
    var name: String
    var executablePath: String
    var launchArgumentTemplate: String
    var supportedFileTypesCSV: String?
    var coverAspectRatioRaw: String?
}

private struct EmulatorImportConflict: Identifiable {
    var existingID: UUID
    var imported: EmulatorTransferRecord
    var id: UUID { existingID }
}

private enum ImportConflictChoice {
    case keepCurrent
    case useImport
    case compare
}

private enum CompareFieldSource: String, CaseIterable, Identifiable {
    case current
    case imported

    var id: String { rawValue }
}

struct EmulatorsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\EmulatorProfile.name, comparator: .localizedStandard)]) private var emulators: [EmulatorProfile]

    @State private var name: String = ""
    @State private var executablePath: String = ""
    @State private var argumentTemplate: String = "\"{ImagePath}\""
    @State private var supportedFileTypesInput: String = ""
    @State private var coverAspectRatio: CoverAspectRatio = .default
    /// Filter for the “Add emulator” catalog list only (independent from Default Launch Arguments).
    @State private var addEmulatorLibrarySearch: String = ""
    /// Filter for the Default Launch Arguments list.
    @State private var defaultLaunchArgumentsSearch: String = ""
    /// Bumped when bundled-catalog overrides change.
    @State private var catalogOverridesVersion: Int = 0
    /// Bumped when custom library entries change.
    @State private var customLibraryVersion: Int = 0
    /// `catalogId` of the bundled row being edited (list hidden while set).
    @State private var editingCatalogRecordId: Int?
    @State private var emulatorsLibraryEditDraft: String = ""
    @State private var emulatorsLibraryFileTypesDraft: String = ""
    @State private var editingCustomEntryId: UUID?
    @State private var customEditDraftTitle: String = ""
    @State private var customEditDraftArgs: String = ""
    @State private var customEditDraftFileTypes: String = ""
    @State private var showAddCustomLibraryEntrySheet = false
    @State private var showDefaultLaunchArgumentsInfo = false
    @State private var showRetroArchInfo = false
    @State private var showRPCS3Info = false
    @State private var importConflicts: [EmulatorImportConflict] = []
    @State private var currentImportConflict: EmulatorImportConflict?
    @State private var showImportConflictSheet = false
    @State private var showCompareImportSheet = false
    @State private var applyConflictChoiceToAll = false
    @State private var compareNameSource: CompareFieldSource = .current
    @State private var compareExecutableSource: CompareFieldSource = .current
    @State private var compareArgumentsSource: CompareFieldSource = .current
    @State private var compareFileTypesSource: CompareFieldSource = .current
    @State private var compareApplyToAll = false
    @State private var compareTemplate: (CompareFieldSource, CompareFieldSource, CompareFieldSource, CompareFieldSource)?
    @State private var importStatusMessage: String?
    /// Sheet uses a stable `Identifiable` token (not a managed object) to avoid SwiftData invalidation crashes.
    @State private var editingEmulator: EditingEmulatorToken?

    private func filteredCustomEntries(search: String) -> [CustomEmulatorLibraryEntry] {
        let all = CustomEmulatorLibraryStore.allEntries()
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return all.sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
        }
        return all.filter { entry in
            entry.displayTitle.lowercased().contains(q) || entry.startupArguments.lowercased().contains(q)
        }
        .sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }

    private func mergedLibraryRows(search: String) -> [LibraryProfileRow] {
        let builtins = BuiltinEmulatorCatalogCache.profiles
            .matchingCatalogSearch(search)
            .sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
        let customs = filteredCustomEntries(search: search)
        let rows = customs.map { LibraryProfileRow.custom($0) } + builtins.map { LibraryProfileRow.builtin($0) }
        return rows.sorted {
            $0.sortTitle.localizedCaseInsensitiveCompare($1.sortTitle) == .orderedAscending
        }
    }

    private var addEmulatorMergedRows: [LibraryProfileRow] {
        mergedLibraryRows(search: addEmulatorLibrarySearch)
    }

    private var defaultLaunchArgumentsMergedRows: [LibraryProfileRow] {
        mergedLibraryRows(search: defaultLaunchArgumentsSearch)
    }

    private func subtitle(for row: LibraryProfileRow) -> String {
        switch row {
        case .builtin(let r):
            return CatalogLaunchArgumentOverrides.effectiveStartupArguments(for: r)
        case .custom(let e):
            return e.startupArguments
        }
    }

    private func supportedFileTypesCSV(for row: LibraryProfileRow) -> String {
        switch row {
        case .builtin(let r):
            return r.supportedFileTypesCSV
        case .custom(let e):
            return e.supportedFileTypesCSV
        }
    }

    private func macPathWarning(for row: LibraryProfileRow) -> Bool {
        switch row {
        case .builtin(let r):
            return r.needsMacPathReview
        case .custom(let e):
            let a = e.startupArguments
            if a.contains(".dll") { return true }
            if a.contains("\\") { return true }
            return false
        }
    }

    private func normalizeFileTypesCSV(_ raw: String) -> String {
        raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var hasUnsavedAddEmulatorChanges: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || argumentTemplate.trimmingCharacters(in: .whitespacesAndNewlines) != "\"{ImagePath}\""
            || !supportedFileTypesInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || coverAspectRatio != .default
            || !addEmulatorLibrarySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Add emulator") {
                    TextField("Display name", text: $name)

                    TextField("Search Emulators Library", text: $addEmulatorLibrarySearch)
                        .textFieldStyle(.roundedBorder)

                    if addEmulatorLibrarySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Type an emulator or profile name to filter. Tap a row to set launch arguments (display name is filled only if empty).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        if addEmulatorMergedRows.isEmpty {
                            Text("No matches. Try another name (e.g. PCSX2, RetroArch, Dolphin).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(addEmulatorMergedRows) { row in
                                        Button {
                                            applyLibraryProfileRow(row)
                                        } label: {
                                            HStack(alignment: .top, spacing: 8) {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(row.sortTitle)
                                                        .font(.body.weight(.medium))
                                                        .foregroundStyle(.primary)
                                                        .multilineTextAlignment(.leading)
                                                    Text(subtitle(for: row))
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(2)
                                                        .id("\(row.id)-\(catalogOverridesVersion)-\(customLibraryVersion)")
                                                    Text("Supported File Types: \(supportedFileTypesCSV(for: row))")
                                                        .font(.caption2)
                                                        .foregroundStyle(.tertiary)
                                                        .lineLimit(2)
                                                }
                                                Spacer(minLength: 8)
                                                if macPathWarning(for: row) {
                                                    Image(systemName: "exclamationmark.triangle.fill")
                                                        .font(.caption)
                                                        .foregroundStyle(.orange)
                                                        .help("May need macOS path tweaks (e.g. RetroArch core .dylib).")
                                                }
                                            }
                                            .padding(.vertical, 8)
                                            .padding(.horizontal, 10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        Divider()
                                    }
                                }
                            }
                            .frame(maxHeight: 240)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                            )
                        }
                    }

                    TextField("Path to .app or executable", text: $executablePath)
                    TextField("Launch arguments (GBear: {ImagePath} for game file; {ROM} and {rom} also work)", text: $argumentTemplate)
                    TextField("Supported File Types (comma-separated: iso, cso, chd)", text: $supportedFileTypesInput)
                    CoverAspectRatioPicker(selection: $coverAspectRatio)
                    HStack {
                        Button("Reset") { resetAddEmulatorForm() }
                            .disabled(!hasUnsavedAddEmulatorChanges)
                        Spacer()
                        Button("Add") { addEmulator() }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || executablePath.isEmpty)
                    }
                }

                Section("Configured") {
                    HStack {
                        Button("Import") {
                            importConfiguredEmulators()
                        }
                        Button("Export") {
                            exportConfiguredEmulators()
                        }
                        Spacer()
                    }
                    if let importStatusMessage {
                        Text(importStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(emulators) { emu in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(emu.name).font(.headline)
                                Text(emu.executablePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text(emu.launchArgumentTemplate)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                                if let supported = emu.supportedFileTypesCSV, !supported.isEmpty {
                                    Text("Supported File Types: \(supported)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .textSelection(.enabled)
                                }
                                Text("Cover art: \(emu.coverAspectRatio.pickerLabel)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 8)
                            HStack(spacing: 2) {
                                Button {
                                    editingEmulator = EditingEmulatorToken(emulatorID: emu.id)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                                .help("Edit this emulator")

                                Button(role: .destructive) {
                                    deleteEmulator(emu)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove this emulator")
                            }
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button("Edit…") {
                                editingEmulator = EditingEmulatorToken(emulatorID: emu.id)
                            }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                deleteEmulator(emu)
                            }
                        }
                    }
                    .onDelete(perform: deleteEmulators)
                }

                Section {
                    if let catalogId = editingCatalogRecordId,
                       let record = BuiltinEmulatorCatalogCache.profiles.first(where: { $0.catalogId == catalogId }) {
                        EmulatorsLibraryEditPane(
                            record: record,
                            draftArguments: $emulatorsLibraryEditDraft,
                            draftFileTypes: $emulatorsLibraryFileTypesDraft,
                            onCancel: {
                                editingCatalogRecordId = nil
                            },
                            onSave: {
                                CatalogLaunchArgumentOverrides.setEffectiveStartupArguments(
                                    emulatorsLibraryEditDraft,
                                    catalogId: catalogId
                                )
                                catalogOverridesVersion += 1
                                editingCatalogRecordId = nil
                            }
                        )
                    } else if let customId = editingCustomEntryId,
                              CustomEmulatorLibraryStore.allEntries().contains(where: { $0.id == customId }) {
                        CustomLibraryEntryEditPane(
                            draftTitle: $customEditDraftTitle,
                            draftArguments: $customEditDraftArgs,
                            draftFileTypes: $customEditDraftFileTypes,
                            onCancel: {
                                editingCustomEntryId = nil
                            },
                            onSave: {
                                CustomEmulatorLibraryStore.update(
                                    id: customId,
                                    displayTitle: customEditDraftTitle,
                                    startupArguments: customEditDraftArgs,
                                    supportedFileTypesCSV: customEditDraftFileTypes
                                )
                                customLibraryVersion += 1
                                editingCustomEntryId = nil
                            },
                            onDelete: {
                                CustomEmulatorLibraryStore.remove(id: customId)
                                customLibraryVersion += 1
                                editingCustomEntryId = nil
                            }
                        )
                    } else {
                        Button {
                            showAddCustomLibraryEntrySheet = true
                        } label: {
                            Label("Add emulator", systemImage: "plus")
                        }

                        TextField("Search Default Launch Arguments", text: $defaultLaunchArgumentsSearch)
                            .textFieldStyle(.roundedBorder)

                        if defaultLaunchArgumentsMergedRows.isEmpty {
                            Text("No matches. Try another name (e.g. PCSX2, RetroArch, Dolphin).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(defaultLaunchArgumentsMergedRows) { row in
                                        Button {
                                            switch row {
                                            case .builtin(let record):
                                                editingCustomEntryId = nil
                                                editingCatalogRecordId = record.catalogId
                                                emulatorsLibraryEditDraft = CatalogLaunchArgumentOverrides
                                                    .effectiveStartupArguments(for: record)
                                                emulatorsLibraryFileTypesDraft = record.supportedFileTypesCSV
                                            case .custom(let entry):
                                                editingCatalogRecordId = nil
                                                editingCustomEntryId = entry.id
                                                customEditDraftTitle = entry.displayTitle
                                                customEditDraftArgs = entry.startupArguments
                                                customEditDraftFileTypes = entry.supportedFileTypesCSV
                                            }
                                        } label: {
                                            HStack(alignment: .top, spacing: 8) {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(row.sortTitle)
                                                        .font(.body.weight(.medium))
                                                        .foregroundStyle(.primary)
                                                        .multilineTextAlignment(.leading)
                                                    Text(subtitle(for: row))
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(2)
                                                        .id("\(row.id)-\(catalogOverridesVersion)-\(customLibraryVersion)")
                                                    Text("Supported File Types: \(supportedFileTypesCSV(for: row))")
                                                        .font(.caption2)
                                                        .foregroundStyle(.tertiary)
                                                        .lineLimit(2)
                                                }
                                                Spacer(minLength: 8)
                                                if macPathWarning(for: row) {
                                                    Image(systemName: "exclamationmark.triangle.fill")
                                                        .font(.caption)
                                                        .foregroundStyle(.orange)
                                                        .help("May need macOS path tweaks (e.g. RetroArch core .dylib).")
                                                }
                                            }
                                            .padding(.vertical, 8)
                                            .padding(.horizontal, 10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        Divider()
                                    }
                                }
                            }
                            .frame(maxHeight: 320)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                            )
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Default Launch Arguments")
                        Button {
                            showDefaultLaunchArgumentsInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Default launch argument guidance")
                        .popover(isPresented: $showDefaultLaunchArgumentsInfo, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Default Launch Arguments help")
                                    .font(.headline)

                                DisclosureGroup("RetroArch cores on macOS", isExpanded: $showRetroArchInfo) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("RetroArch cores on Mac are typically stored in the hidden folder `~/Library/Application Support/RetroArch/cores`.")
                                        Text("To access this folder: open Finder, choose Go in the menu bar, select Go to Folder, then paste `~/Library/Application Support/RetroArch/`.")
                                        Text("Paths can differ between standard and Steam installs.")
                                        Text("Example launch arguments:")
                                            .font(.subheadline.weight(.semibold))
                                        Text("-L \"/Users/{user_name}/Library/Application Support/RetroArch/cores/mgba_libretro.dylib\" --fullscreen \"{ImagePath}\"")
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                    .padding(.top, 4)
                                }

                                DisclosureGroup("RPCS3 edge case", isExpanded: $showRPCS3Info) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("If RPCS3 is already open, launching a different PS3 game from this library may not switch games reliably.")
                                        Text("Workaround: close RPCS3 first, then launch the other PS3 game from the library.")
                                    }
                                    .padding(.top, 4)
                                }
                            }
                            .padding(14)
                            .frame(width: 520)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .navigationTitle("Emulators")
        }
        .frame(minWidth: 480, minHeight: 360)
        .sheet(item: $editingEmulator) { token in
            EditEmulatorSheet(emulatorID: token.emulatorID) {
                editingEmulator = nil
            }
        }
        .sheet(isPresented: $showAddCustomLibraryEntrySheet) {
            AddCustomEmulatorLibraryEntrySheet { displayTitle, startupArguments, supportedFileTypesCSV in
                CustomEmulatorLibraryStore.add(
                    displayTitle: displayTitle,
                    startupArguments: startupArguments,
                    supportedFileTypesCSV: supportedFileTypesCSV
                )
                customLibraryVersion += 1
            }
        }
        .sheet(isPresented: $showImportConflictSheet) {
            importConflictSheet
        }
        .sheet(isPresented: $showCompareImportSheet) {
            compareConflictSheet
        }
    }

    private func applyLibraryProfileRow(_ row: LibraryProfileRow) {
        switch row {
        case .builtin(let record):
            applyCatalogProfile(record)
        case .custom(let entry):
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = entry.displayTitle
            }
            argumentTemplate = entry.startupArguments
            supportedFileTypesInput = entry.supportedFileTypesCSV
            coverAspectRatio = CoverAspectRatio.inferred(platforms: [], name: entry.displayTitle)
            addEmulatorLibrarySearch = ""
        }
    }

    private func applyCatalogProfile(_ record: BuiltinEmulatorProfileRecord) {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = record.displayTitle
        }
        argumentTemplate = CatalogLaunchArgumentOverrides.effectiveStartupArguments(for: record)
        supportedFileTypesInput = record.supportedFileTypesCSV
        coverAspectRatio = CoverAspectRatio.inferred(platforms: record.platforms, name: record.displayTitle)
        addEmulatorLibrarySearch = ""
    }

    private func addEmulator() {
        let profile = EmulatorProfile(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            executablePath: executablePath.trimmingCharacters(in: .whitespacesAndNewlines),
            launchArgumentTemplate: LaunchArgumentTemplate.normalizePCSX2StyleBootSeparator(
                LaunchArgumentTemplate.normalizeHomePaths(argumentTemplate)
            ),
            supportedFileTypesCSV: normalizeFileTypesCSV(supportedFileTypesInput),
            coverAspectRatioRaw: coverAspectRatio.rawValue,
            sortOrder: emulators.count
        )
        modelContext.insert(profile)
        resetAddEmulatorForm()
    }

    private func resetAddEmulatorForm() {
        name = ""
        executablePath = ""
        argumentTemplate = "\"{ImagePath}\""
        supportedFileTypesInput = ""
        coverAspectRatio = .default
        addEmulatorLibrarySearch = ""
    }

    private func exportConfiguredEmulators() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ConfiguredEmulators.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let records = emulators
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { emulator in
                EmulatorTransferRecord(
                    name: emulator.name,
                    executablePath: emulator.executablePath,
                    launchArgumentTemplate: emulator.launchArgumentTemplate,
                    supportedFileTypesCSV: emulator.supportedFileTypesCSV,
                    coverAspectRatioRaw: emulator.coverAspectRatio.rawValue
                )
            }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: url, options: .atomic)
            importStatusMessage = "Exported \(records.count) configured emulators."
        } catch {
            importStatusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importConfiguredEmulators() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let imported = try JSONDecoder().decode([EmulatorTransferRecord].self, from: data)
            runImport(records: imported)
        } catch {
            importStatusMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func runImport(records: [EmulatorTransferRecord]) {
        importStatusMessage = nil
        importConflicts = []
        currentImportConflict = nil
        applyConflictChoiceToAll = false
        compareApplyToAll = false
        compareTemplate = nil

        var insertedCount = 0
        for record in records {
            if let existing = emulators.first(where: { $0.name.caseInsensitiveCompare(record.name) == .orderedSame }) {
                importConflicts.append(EmulatorImportConflict(existingID: existing.id, imported: record))
            } else {
                let profile = EmulatorProfile(
                    name: record.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    executablePath: record.executablePath.trimmingCharacters(in: .whitespacesAndNewlines),
                    launchArgumentTemplate: LaunchArgumentTemplate.normalizeHomePaths(
                        record.launchArgumentTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    supportedFileTypesCSV: cleanOptionalCSV(record.supportedFileTypesCSV),
                    coverAspectRatioRaw: CoverAspectRatio.parse(record.coverAspectRatioRaw).rawValue,
                    sortOrder: emulators.count + insertedCount
                )
                modelContext.insert(profile)
                insertedCount += 1
            }
        }

        if importConflicts.isEmpty {
            try? modelContext.save()
            importStatusMessage = "Import complete. Added \(insertedCount) emulators. No conflicts."
            return
        }

        currentImportConflict = importConflicts.removeFirst()
        showImportConflictSheet = true
        importStatusMessage = "Import found conflicts. Resolve to continue."
    }

    private func resolveCurrentConflict(choice: ImportConflictChoice) {
        guard let conflict = currentImportConflict else { return }
        switch choice {
        case .keepCurrent:
            if applyConflictChoiceToAll {
                resolveRemainingConflictsKeepingCurrent()
            } else {
                advanceToNextConflict()
            }
        case .useImport:
            overwriteExisting(with: conflict.imported, existingID: conflict.existingID)
            if applyConflictChoiceToAll {
                resolveRemainingConflictsUsingImport()
            } else {
                advanceToNextConflict()
            }
        case .compare:
            prepareCompareSources(for: conflict)
            showImportConflictSheet = false
            showCompareImportSheet = true
        }
    }

    private func resolveRemainingConflictsKeepingCurrent() {
        importConflicts.removeAll()
        finishImportResolution()
    }

    private func resolveRemainingConflictsUsingImport() {
        for conflict in importConflicts {
            overwriteExisting(with: conflict.imported, existingID: conflict.existingID)
        }
        importConflicts.removeAll()
        finishImportResolution()
    }

    private func resolveCompareAndContinue() {
        guard let conflict = currentImportConflict else { return }
        let merged = mergedRecord(for: conflict)
        overwriteExisting(with: merged, existingID: conflict.existingID)

        let shouldApplyTemplateToAll = compareApplyToAll
        if shouldApplyTemplateToAll {
            let template = (compareNameSource, compareExecutableSource, compareArgumentsSource, compareFileTypesSource)
            compareTemplate = template
            for remaining in importConflicts {
                let mergedRemaining = mergedRecord(
                    current: emulators.first(where: { $0.id == remaining.existingID }),
                    imported: remaining.imported,
                    template: template
                )
                overwriteExisting(with: mergedRemaining, existingID: remaining.existingID)
            }
            importConflicts.removeAll()
            showCompareImportSheet = false
            finishImportResolution()
            return
        }

        showCompareImportSheet = false
        advanceToNextConflict()
    }

    private func advanceToNextConflict() {
        if importConflicts.isEmpty {
            finishImportResolution()
            return
        }
        currentImportConflict = importConflicts.removeFirst()
        showImportConflictSheet = true
        showCompareImportSheet = false
        applyConflictChoiceToAll = false
        compareApplyToAll = false
    }

    private func finishImportResolution() {
        showImportConflictSheet = false
        showCompareImportSheet = false
        applyConflictChoiceToAll = false
        compareApplyToAll = false
        currentImportConflict = nil
        try? modelContext.save()
        importStatusMessage = "Import complete. Conflicts resolved."
    }

    private func overwriteExisting(with record: EmulatorTransferRecord, existingID: UUID) {
        guard let existing = emulators.first(where: { $0.id == existingID }) else { return }
        existing.name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        existing.executablePath = record.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        existing.launchArgumentTemplate = LaunchArgumentTemplate.normalizeHomePaths(
            record.launchArgumentTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        existing.supportedFileTypesCSV = cleanOptionalCSV(record.supportedFileTypesCSV)
        if let raw = record.coverAspectRatioRaw {
            existing.coverAspectRatioRaw = CoverAspectRatio.parse(raw).rawValue
        }
    }

    private func cleanOptionalCSV(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func prepareCompareSources(for conflict: EmulatorImportConflict) {
        compareNameSource = .current
        compareExecutableSource = .current
        compareArgumentsSource = .current
        compareFileTypesSource = .current

        if let template = compareTemplate {
            compareNameSource = template.0
            compareExecutableSource = template.1
            compareArgumentsSource = template.2
            compareFileTypesSource = template.3
        }
    }

    private func mergedRecord(for conflict: EmulatorImportConflict) -> EmulatorTransferRecord {
        mergedRecord(
            current: emulators.first(where: { $0.id == conflict.existingID }),
            imported: conflict.imported,
            template: (compareNameSource, compareExecutableSource, compareArgumentsSource, compareFileTypesSource)
        )
    }

    private func mergedRecord(
        current: EmulatorProfile?,
        imported: EmulatorTransferRecord,
        template: (CompareFieldSource, CompareFieldSource, CompareFieldSource, CompareFieldSource)
    ) -> EmulatorTransferRecord {
        let currentName = current?.name ?? imported.name
        let currentExecutable = current?.executablePath ?? imported.executablePath
        let currentArguments = current?.launchArgumentTemplate ?? imported.launchArgumentTemplate
        let currentFileTypes = current?.supportedFileTypesCSV

        return EmulatorTransferRecord(
            name: template.0 == .current ? currentName : imported.name,
            executablePath: template.1 == .current ? currentExecutable : imported.executablePath,
            launchArgumentTemplate: template.2 == .current ? currentArguments : imported.launchArgumentTemplate,
            supportedFileTypesCSV: template.3 == .current ? currentFileTypes : imported.supportedFileTypesCSV,
            coverAspectRatioRaw: current?.coverAspectRatio.rawValue ?? imported.coverAspectRatioRaw
        )
    }

    @ViewBuilder
    private var importConflictSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let conflict = currentImportConflict,
                   let existing = emulators.first(where: { $0.id == conflict.existingID }) {
                    Text("Conflicting emulator: \(existing.name)")
                        .font(.headline)
                    Text("A configured emulator with this name already exists.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Toggle("Do for all remaining conflicts", isOn: $applyConflictChoiceToAll)

                    HStack {
                        Button("Keep current") {
                            resolveCurrentConflict(choice: .keepCurrent)
                        }
                        Button("Use the import") {
                            resolveCurrentConflict(choice: .useImport)
                        }
                        Button("Compare") {
                            resolveCurrentConflict(choice: .compare)
                        }
                    }

                    Spacer()
                } else {
                    Text("No conflict selected.")
                }
            }
            .padding()
            .navigationTitle("Import conflict")
        }
        .frame(minWidth: 520, minHeight: 220)
    }

    @ViewBuilder
    private var compareConflictSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                if let conflict = currentImportConflict,
                   let existing = emulators.first(where: { $0.id == conflict.existingID }) {
                    Text("Compare and merge")
                        .font(.headline)
                    Text("Choose which value to keep for each field.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    compareFieldRow(
                        title: "Display name",
                        currentValue: existing.name,
                        importedValue: conflict.imported.name,
                        source: $compareNameSource
                    )
                    compareFieldRow(
                        title: "Executable path",
                        currentValue: existing.executablePath,
                        importedValue: conflict.imported.executablePath,
                        source: $compareExecutableSource
                    )
                    compareFieldRow(
                        title: "Launch arguments",
                        currentValue: existing.launchArgumentTemplate,
                        importedValue: conflict.imported.launchArgumentTemplate,
                        source: $compareArgumentsSource
                    )
                    compareFieldRow(
                        title: "Supported File Types",
                        currentValue: existing.supportedFileTypesCSV ?? "",
                        importedValue: conflict.imported.supportedFileTypesCSV ?? "",
                        source: $compareFileTypesSource
                    )

                    Toggle("Do for all remaining conflicts", isOn: $compareApplyToAll)

                    HStack {
                        Button("Cancel", role: .cancel) {
                            showCompareImportSheet = false
                            showImportConflictSheet = true
                        }
                        Spacer()
                        Button("Keep merged result") {
                            resolveCompareAndContinue()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Text("No conflict selected.")
                }
            }
            .padding()
            .navigationTitle("Compare conflict")
        }
        .frame(minWidth: 760, minHeight: 420)
    }

    @ViewBuilder
    private func compareFieldRow(
        title: String,
        currentValue: String,
        importedValue: String,
        source: Binding<CompareFieldSource>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(currentValue.isEmpty ? "—" : currentValue)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Imported")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(importedValue.isEmpty ? "—" : importedValue)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            Picker("Keep", selection: source) {
                Text("Keep current").tag(CompareFieldSource.current)
                Text("Use import").tag(CompareFieldSource.imported)
            }
            .pickerStyle(.segmented)
        }
    }

    private func deleteEmulator(_ emu: EmulatorProfile) {
        if editingEmulator?.emulatorID == emu.id {
            editingEmulator = nil
        }
        modelContext.delete(emu)
    }

    private func deleteEmulators(at offsets: IndexSet) {
        for index in offsets {
            let emu = emulators[index]
            if editingEmulator?.emulatorID == emu.id {
                editingEmulator = nil
            }
            modelContext.delete(emu)
        }
    }
}

// MARK: - Default Launch Arguments (custom entry editor)

private struct CustomLibraryEntryEditPane: View {
    @Binding var draftTitle: String
    @Binding var draftArguments: String
    @Binding var draftFileTypes: String
    let onCancel: () -> Void
    let onSave: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom preset")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("Display name", text: $draftTitle)
                .textFieldStyle(.roundedBorder)

            Text("Default launch arguments")
                .font(.subheadline.weight(.semibold))
            Text("Used when you choose this preset under “Add emulator”. Use `{ImagePath}` for the game file; `{ROM}` and `{rom}` also work.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Launch arguments", text: $draftArguments, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(5...12)
            TextField("Supported File Types (comma-separated)", text: $draftFileTypes)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Delete", role: .destructive) {
                    onDelete()
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draftArguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AddCustomEmulatorLibraryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var displayTitle: String = ""
    @State private var startupArguments: String = "\"{ImagePath}\""
    @State private var supportedFileTypesCSV: String = ""
    let onCommit: (String, String, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display name", text: $displayTitle)
                    TextField("Default launch arguments", text: $startupArguments, axis: .vertical)
                        .lineLimit(4...12)
                    TextField("Supported File Types (comma-separated)", text: $supportedFileTypesCSV)
                } footer: {
                    Text("This preset appears in both lists here and under “Add emulator”. Use `{ImagePath}` for the game file.")
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .padding()
            .navigationTitle("Add emulator")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let t = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        let a = startupArguments.trimmingCharacters(in: .whitespacesAndNewlines)
                        let f = supportedFileTypesCSV.trimmingCharacters(in: .whitespacesAndNewlines)
                        onCommit(t, a, f)
                        dismiss()
                    }
                    .disabled(
                        displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || startupArguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
        .frame(minWidth: 420, minHeight: 260)
    }
}

// MARK: - Bundled catalog defaults editor

private struct EmulatorsLibraryEditPane: View {
    let record: BuiltinEmulatorProfileRecord
    @Binding var draftArguments: String
    @Binding var draftFileTypes: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(record.displayTitle)
                .font(.title3.weight(.semibold))

            Text("Catalog default (from bundled library)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(record.startupArguments)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("Default launch arguments")
                .font(.subheadline.weight(.semibold))
            Text("This text is used when you choose this profile under “Add emulator”. Use `{ImagePath}` for the game file; `{ROM}` and `{rom}` also work.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Launch arguments", text: $draftArguments, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(5...12)

            Text("Supported File Types")
                .font(.subheadline.weight(.semibold))
            TextField("Supported File Types", text: $draftFileTypes)
                .textFieldStyle(.roundedBorder)
                .disabled(true)

            HStack {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draftArguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EditingEmulatorToken: Identifiable {
    let emulatorID: UUID
    var id: UUID { emulatorID }
}

// MARK: - Edit sheet

private struct EditEmulatorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let emulatorID: UUID
    var onFinished: () -> Void

    @State private var name: String = ""
    @State private var executablePath: String = ""
    @State private var launchArgumentTemplate: String = ""
    @State private var supportedFileTypesCSV: String = ""
    @State private var coverAspectRatio: CoverAspectRatio = .default
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if loadFailed {
                    ContentUnavailableView(
                        "Emulator unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("This entry was removed or the library was reset. Close and try again.")
                    )
                } else {
                    Form {
                        Section("Emulator") {
                            TextField("Display name", text: $name)
                            TextField("Path to .app or executable", text: $executablePath)
                            TextField("Launch arguments (GBear: {ImagePath}; {ROM} and {rom} also work)", text: $launchArgumentTemplate)
                            TextField("Supported File Types (comma-separated)", text: $supportedFileTypesCSV)
                            CoverAspectRatioPicker(selection: $coverAspectRatio)
                        }
                    }
                    .formStyle(.grouped)
                    .padding()
                }
            }
            .navigationTitle("Edit emulator")
            .task(id: emulatorID) {
                await loadFromStore()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onFinished()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveIfPossible()
                    }
                    .disabled(loadFailed || name.trimmingCharacters(in: .whitespaces).isEmpty
                        || executablePath.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 340)
    }

    @MainActor
    private func loadFromStore() async {
        let uid = emulatorID
        let descriptor = FetchDescriptor<EmulatorProfile>(
            predicate: #Predicate { $0.id == uid }
        )
        guard let profile = try? modelContext.fetch(descriptor).first else {
            loadFailed = true
            return
        }
        name = profile.name
        executablePath = profile.executablePath
        launchArgumentTemplate = profile.launchArgumentTemplate
        supportedFileTypesCSV = profile.supportedFileTypesCSV ?? ""
        coverAspectRatio = profile.coverAspectRatio
        loadFailed = false
    }

    @MainActor
    private func saveIfPossible() {
        let uid = emulatorID
        let descriptor = FetchDescriptor<EmulatorProfile>(
            predicate: #Predicate { $0.id == uid }
        )
        guard let profile = try? modelContext.fetch(descriptor).first else {
            loadFailed = true
            return
        }
        profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.executablePath = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.launchArgumentTemplate = LaunchArgumentTemplate.normalizePCSX2StyleBootSeparator(
            LaunchArgumentTemplate.normalizeHomePaths(launchArgumentTemplate)
        )
        let normalized = supportedFileTypesCSV.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.supportedFileTypesCSV = normalized.isEmpty ? nil : normalized
        profile.coverAspectRatio = coverAspectRatio
        try? modelContext.save()
        onFinished()
        dismiss()
    }
}

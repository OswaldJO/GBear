import SwiftData
import SwiftUI

/// Links emulator profiles that share a platform into one library section, and picks which one opens the games.
struct LinkEmulatorsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\EmulatorProfile.name, comparator: .localizedStandard)]) private var emulators: [EmulatorProfile]

    let emulatorID: UUID

    @State private var selectedIDs: Set<UUID> = []
    @State private var defaultEmulatorID: UUID?
    @State private var errorMessage: String?
    @State private var loaded = false

    private var emulator: EmulatorProfile? {
        emulators.first { $0.id == emulatorID }
    }

    private var systemId: Int? {
        emulator.flatMap(EmulatorLinkService.platformSystemId(for:))
    }

    private var platformName: String {
        systemId.map(ScreenScraperPlatformMap.displayName(forSystemId:)) ?? "Not set"
    }

    /// Profiles with the same platform, this one first.
    private var candidates: [EmulatorProfile] {
        guard let systemId else { return [] }
        let matching = emulators.filter { EmulatorLinkService.platformSystemId(for: $0) == systemId }
        return matching.filter { $0.id == emulatorID } + matching.filter { $0.id != emulatorID }
    }

    private var existingGroup: EmulatorLinkService.Group? {
        EmulatorLinkService.group(containing: emulatorID, in: emulators)
    }

    private var selectedEmulators: [EmulatorProfile] {
        candidates.filter { selectedIDs.contains($0.id) }
    }

    private var canLink: Bool {
        selectedEmulators.count >= 2 && defaultEmulatorID.map(selectedIDs.contains) == true
    }

    var body: some View {
        NavigationStack {
            Form {
                if let emulator {
                    Section {
                        LabeledContent("Platform", value: platformName)
                        Text(
                            "Linked emulators share one library section named after their platform, and a game in a folder " +
                                "they both scan shows up once. Only emulators with the same platform can be linked."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if systemId == nil {
                        Section {
                            Text("Set a platform for \(emulator.name) first (Edit → Platform).")
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Section("Emulators") {
                            ForEach(candidates, id: \.id) { candidate in
                                Toggle(isOn: selectionBinding(for: candidate.id)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.name)
                                        if let note = otherGroupNote(for: candidate) {
                                            Text(note)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .disabled(candidate.id == emulatorID)
                            }
                            if candidates.count < 2 {
                                Text("No other emulator is set to \(platformName). Set another emulator's platform to \(platformName) to link it.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Section("Default emulator") {
                            Picker("Opens games", selection: $defaultEmulatorID) {
                                Text("Choose…").tag(UUID?.none)
                                ForEach(selectedEmulators, id: \.id) { member in
                                    Text(member.name).tag(UUID?.some(member.id))
                                }
                            }
                            Text("Games in the \(platformName) section open with this emulator. You can pick another for one game under Launch with in its info panel.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.orange)
                        }
                    }
                } else {
                    ContentUnavailableView("Emulator unavailable", systemImage: "exclamationmark.triangle")
                }
            }
            .formStyle(.grouped)
            .padding()
            .navigationTitle(existingGroup == nil ? "Link emulators" : "Linked emulators")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if existingGroup != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Unlink", role: .destructive) { unlink() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existingGroup == nil ? "Link" : "Save") { save() }
                        .disabled(!canLink)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 420)
        .onAppear(perform: loadSelection)
    }

    private func loadSelection() {
        guard !loaded else { return }
        loaded = true
        if let group = existingGroup {
            selectedIDs = group.memberIDs
            defaultEmulatorID = group.defaultEmulator.id
        } else {
            selectedIDs = [emulatorID]
            defaultEmulatorID = nil
        }
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { isOn in
                if isOn {
                    selectedIDs.insert(id)
                } else {
                    selectedIDs.remove(id)
                    if defaultEmulatorID == id { defaultEmulatorID = nil }
                }
            }
        )
    }

    /// Joining here moves an emulator out of a different group.
    private func otherGroupNote(for candidate: EmulatorProfile) -> String? {
        guard candidate.id != emulatorID,
              let other = EmulatorLinkService.group(containing: candidate.id, in: emulators),
              other.id != existingGroup?.id else { return nil }
        let partners = other.members.filter { $0.id != candidate.id }.map(\.name).joined(separator: ", ")
        return "Linked with \(partners); linking here moves it to this group."
    }

    private func save() {
        guard let defaultEmulatorID, let defaultEmulator = emulators.first(where: { $0.id == defaultEmulatorID }) else {
            errorMessage = EmulatorLinkService.LinkError.defaultNotInGroup.localizedDescription
            return
        }
        do {
            try EmulatorLinkService.link(
                selectedEmulators,
                defaultEmulator: defaultEmulator,
                groupID: existingGroup?.id,
                all: emulators
            )
            try modelContext.save()
            refreshLibrary()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlink() {
        guard let group = existingGroup else { return }
        for member in group.members {
            EmulatorLinkService.unlink(member, all: emulators)
        }
        try? modelContext.save()
        refreshLibrary()
        dismiss()
    }

    private func refreshLibrary() {
        let context = modelContext
        Task { @MainActor in
            await EmulatorLinkService.refreshLibraryAfterLinkChange(modelContext: context)
        }
    }
}

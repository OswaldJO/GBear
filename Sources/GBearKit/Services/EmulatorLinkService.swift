import Foundation
import SwiftData

/// Linked emulator profiles share one library section named after their platform (for example Flycast + Redream → Dreamcast).
/// Only profiles with the same platform can be linked, and one of them is the default that opens the group's games.
enum EmulatorLinkService {
    struct Group: Identifiable {
        let id: UUID
        /// Sorted by name.
        let members: [EmulatorProfile]
        let defaultEmulator: EmulatorProfile
        let systemId: Int
        let name: String

        var memberIDs: Set<UUID> { Set(members.map(\.id)) }

        func contains(_ emulatorID: UUID) -> Bool {
            members.contains { $0.id == emulatorID }
        }
    }

    enum LinkError: Error, LocalizedError {
        case needsTwoEmulators
        case platformNotSet(String)
        case platformMismatch
        case defaultNotInGroup

        var errorDescription: String? {
            switch self {
            case .needsTwoEmulators:
                return "Choose at least two emulators to link."
            case .platformNotSet(let name):
                return "Set a platform for \(name) first (Edit → Platform)."
            case .platformMismatch:
                return "Only emulators with the same platform can be linked."
            case .defaultNotInGroup:
                return "Choose which linked emulator opens the games by default."
            }
        }
    }

    /// The platform shown in Emulators: the one the user picked, else the one inferred from the emulator.
    static func platformSystemId(for emulator: EmulatorProfile) -> Int? {
        emulator.screenScraperSystemId ?? EmulatorPlatformResolver.resolve(emulator: emulator)?.primarySystemId
    }

    static func platformName(for emulator: EmulatorProfile) -> String? {
        platformSystemId(for: emulator).map(ScreenScraperPlatformMap.displayName(forSystemId:))
    }

    /// Groups with at least two members, sorted by name.
    static func groups(in emulators: [EmulatorProfile]) -> [Group] {
        let linked = emulators.compactMap { emulator in
            emulator.linkGroupIDString.flatMap(UUID.init(uuidString:)).map { ($0, emulator) }
        }
        return Dictionary(grouping: linked, by: \.0)
            .compactMap { id, pairs -> Group? in
                let members = pairs.map(\.1).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                guard members.count >= 2 else { return nil }
                let defaultEmulator = members.first(where: \.isLinkGroupDefault) ?? members[0]
                guard let systemId = platformSystemId(for: defaultEmulator) else { return nil }
                return Group(
                    id: id,
                    members: members,
                    defaultEmulator: defaultEmulator,
                    systemId: systemId,
                    name: ScreenScraperPlatformMap.displayName(forSystemId: systemId)
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func group(containing emulatorID: UUID, in emulators: [EmulatorProfile]) -> Group? {
        groups(in: emulators).first { $0.contains(emulatorID) }
    }

    /// Emulator that opens a game when it has no **Launch with** choice: the group default for linked profiles.
    static func defaultLaunchEmulator(for game: LibraryGame, in emulators: [EmulatorProfile]) -> EmulatorProfile? {
        guard let emulatorID = game.emulatorUUID else { return nil }
        if let group = group(containing: emulatorID, in: emulators) {
            return group.defaultEmulator
        }
        return emulators.first { $0.id == emulatorID }
    }

    /// Links `members` into `groupID` (a new group when nil). Members of that group left out are unlinked; members taken
    /// from other groups leave them.
    static func link(
        _ members: [EmulatorProfile],
        defaultEmulator: EmulatorProfile,
        groupID existingGroupID: UUID?,
        all: [EmulatorProfile]
    ) throws {
        guard members.count >= 2 else { throw LinkError.needsTwoEmulators }
        guard members.contains(where: { $0.id == defaultEmulator.id }) else { throw LinkError.defaultNotInGroup }
        guard let systemId = platformSystemId(for: defaultEmulator) else {
            throw LinkError.platformNotSet(defaultEmulator.name)
        }
        if let unset = members.first(where: { platformSystemId(for: $0) == nil }) {
            throw LinkError.platformNotSet(unset.name)
        }
        guard members.allSatisfy({ platformSystemId(for: $0) == systemId }) else { throw LinkError.platformMismatch }

        let groupID = (existingGroupID ?? UUID()).uuidString
        let memberIDs = Set(members.map(\.id))
        for emulator in all where emulator.linkGroupIDString == groupID && !memberIDs.contains(emulator.id) {
            clear(emulator)
        }
        for emulator in members {
            emulator.linkGroupIDString = groupID
            emulator.isLinkGroupDefault = emulator.id == defaultEmulator.id
        }
        normalize(all)
    }

    static func unlink(_ emulator: EmulatorProfile, all: [EmulatorProfile]) {
        clear(emulator)
        normalize(all)
    }

    /// Repairs groups after edits or deletes: drops members whose platform no longer matches the default's,
    /// dissolves groups with fewer than two members, and keeps exactly one default.
    @discardableResult
    static func normalize(_ all: [EmulatorProfile]) -> Bool {
        var changed = false
        let byGroup = Dictionary(grouping: all.filter { $0.linkGroupIDString != nil }, by: { $0.linkGroupIDString! })
        for (_, members) in byGroup {
            let sorted = members.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let defaultEmulator = sorted.first(where: \.isLinkGroupDefault) ?? sorted[0]
            let systemId = platformSystemId(for: defaultEmulator)
            let kept = sorted.filter { systemId != nil && platformSystemId(for: $0) == systemId }
            for emulator in sorted where !kept.contains(where: { $0.id == emulator.id }) {
                clear(emulator)
                changed = true
            }
            guard kept.count >= 2 else {
                for emulator in kept {
                    clear(emulator)
                    changed = true
                }
                continue
            }
            let defaultID = kept.contains(where: { $0.id == defaultEmulator.id }) ? defaultEmulator.id : kept[0].id
            for emulator in kept where emulator.isLinkGroupDefault != (emulator.id == defaultID) {
                emulator.isLinkGroupDefault = emulator.id == defaultID
                changed = true
            }
        }
        return changed
    }

    /// Re-runs the path scan and ROMM sync so a link change merges (or splits) the library right away:
    /// shared rows settle on the linked emulators and ROMM-only duplicates of local games are removed.
    @MainActor
    static func refreshLibraryAfterLinkChange(modelContext: ModelContext) async {
        try? modelContext.save()
        let scan = try? GamePathScanner.scan(modelContext: modelContext)
        let romm = await RommSync.shared.sync(modelContext: modelContext)
        if (scan?.added ?? 0) > 0 || romm.added > 0 {
            MetadataBackgroundFetcher.shared.scheduleExtraPass(container: modelContext.container)
        }
    }

    private static func clear(_ emulator: EmulatorProfile) {
        emulator.linkGroupIDString = nil
        emulator.isLinkGroupDefault = false
    }
}

import Foundation

/// One emulator profile from GBear’s built-in `emulator.yaml` definitions.
/// Source data: [GBear](https://github.com/JosefNemec/GBear) (MIT). Startup arguments use GBear’s `{ImagePath}` placeholder for the game file.
public struct BuiltinEmulatorProfileRecord: Codable, Sendable, Hashable, Identifiable {
    public let catalogId: Int
    public let emulatorId: String
    public let emulatorName: String
    public let website: String?
    public let profileName: String
    public let startupArguments: String
    public let platforms: [String]
    public let imageExtensions: [String]
    public let startupExecutableHint: String?

    public var id: Int { catalogId }

    /// True when the template still looks Windows-specific (`.dll`, backslash paths) and may need manual edits on macOS.
    public var needsMacPathReview: Bool {
        let a = startupArguments
        if a.contains(".dll") { return true }
        if a.contains("\\") { return true }
        return false
    }

    public var displayTitle: String {
        "\(emulatorName) — \(profileName)"
    }

    public var supportedFileTypesCSV: String {
        imageExtensions.joined(separator: ", ")
    }
}

public enum BuiltinEmulatorCatalogLoader {
    public static func loadProfiles() -> [BuiltinEmulatorProfileRecord] {
        guard let url = Bundle.module.url(forResource: "BuiltinEmulatorCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        return (try? JSONDecoder().decode([BuiltinEmulatorProfileRecord].self, from: data)) ?? []
    }
}

/// Cached once for UI filtering (catalog is static in the bundle).
public enum BuiltinEmulatorCatalogCache {
    public static let profiles: [BuiltinEmulatorProfileRecord] = BuiltinEmulatorCatalogLoader.loadProfiles()
}

extension [BuiltinEmulatorProfileRecord] {
    func filteredForSearch(_ query: String) -> [BuiltinEmulatorProfileRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return filter { row in
            if row.emulatorName.lowercased().contains(q) { return true }
            if row.emulatorId.lowercased().contains(q) { return true }
            if row.profileName.lowercased().contains(q) { return true }
            if row.startupArguments.lowercased().contains(q) { return true }
            if row.platforms.joined(separator: " ").lowercased().contains(q) { return true }
            return false
        }
    }

    /// Full list when the search string is empty; otherwise the same matching rules as ``filteredForSearch``.
    func matchingCatalogSearch(_ query: String) -> [BuiltinEmulatorProfileRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return self
        }
        return filteredForSearch(query)
    }
}

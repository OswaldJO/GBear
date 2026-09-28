import Foundation

/// Games the user removed from the library. Scan Paths and storefront import skip these so removed games stay gone.
/// Bulk "Clear…" actions do not add entries; they are meant to be re-imported by the next scan.
public enum LibraryBlocklist {
    public struct Entry: Codable, Sendable, Identifiable, Hashable {
        public var id: String { key }
        /// Lowercased standardized path, matching `GamePathScanner` path comparison.
        public var key: String
        public var path: String
        public var title: String
        /// Emulator name at removal time, or nil for Mac / Epic games.
        public var sourceName: String?
        public var removedAt: Date
    }

    private static let defaultsKey = "Library.BlockedGames"

    public static var entries: [Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Normalized keys for a fast lookup during a scan.
    public static var blockedKeys: Set<String> {
        Set(entries.map(\.key))
    }

    /// `identity` overrides the path as the match key (storefront games keep one identity across install locations).
    public static func add(path: String, title: String, sourceName: String?, identity: String? = nil) {
        let standardized = (path as NSString).standardizingPath
        let key = comparisonKey(identity ?? standardized)
        var current = entries.filter { $0.key != key }
        current.append(Entry(key: key, path: standardized, title: title, sourceName: sourceName, removedAt: Date()))
        save(current)
    }

    public static func remove(key: String) {
        save(entries.filter { $0.key != key })
    }

    public static func remove(path: String) {
        remove(key: comparisonKey(path))
    }

    public static func removeAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    public static func comparisonKey(_ path: String) -> String {
        var normalized = (path as NSString).standardizingPath
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized.lowercased()
    }

    private static func save(_ list: [Entry]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

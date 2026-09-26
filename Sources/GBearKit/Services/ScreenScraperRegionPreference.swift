import Foundation

/// ScreenScraper media/title region short codes (see `regionsListe.php`).
enum ScreenScraperRegionPreference {
    static let defaultRegionCode = "us"

    /// Default cover-region rank (RetroHrai-style): US → Europe → World → Japan, then other locales.
    static let selectableRegions: [(code: String, label: String)] = [
        ("us", "United States"),
        ("eu", "Europe"),
        ("wor", "World"),
        ("jp", "Japan"),
        ("fr", "France"),
        ("de", "Germany"),
        ("es", "Spain"),
        ("kr", "Korea"),
        ("it", "Italy"),
        ("pt", "Portugal"),
        ("au", "Australia"),
        ("ss", "ScreenScraper default"),
    ]

    static var defaultPriorityOrder: [String] {
        selectableRegions.map(\.code)
    }

    static func label(forCode code: String) -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return selectableRegions.first { $0.code == normalized }?.label ?? code
    }

    static func isKnownCode(_ code: String) -> Bool {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return selectableRegions.contains { $0.code == normalized }
    }

    /// Unique known codes in the given order, then any missing defaults appended.
    static func normalizedPriority(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for raw in codes {
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard isKnownCode(code), !seen.contains(code) else { continue }
            seen.insert(code)
            order.append(code)
        }
        for code in defaultPriorityOrder where !seen.contains(code) {
            order.append(code)
        }
        return order
    }

    /// Cover/title fallback: optional per-search or filename boost, then the user’s ranked list.
    static func mediaRegionOrder(preferredCode: String?) -> [String] {
        let preferred = preferredCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var order: [String] = []
        if let preferred, !preferred.isEmpty {
            order.append(preferred)
        }
        for code in MetadataCredentials.screenScraperRegionPriority where !order.contains(code) {
            order.append(code)
        }
        return order
    }
}

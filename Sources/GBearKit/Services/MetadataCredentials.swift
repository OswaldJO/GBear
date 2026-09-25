import Foundation

/// Stores ScreenScraper API credentials.
enum MetadataCredentials {
    private static let devIDKey = "Metadata.ScreenScraper.DevID"
    private static let devPasswordKey = "Metadata.ScreenScraper.DevPassword"
    private static let userIDKey = "Metadata.ScreenScraper.UserID"
    private static let userPasswordKey = "Metadata.ScreenScraper.UserPassword"
    private static let preferredRegionKey = "Metadata.ScreenScraper.PreferredRegion"
    private static let autoSelectAmbiguityKey = "Metadata.ScreenScraper.AutoSelectAmbiguity"
    private static let onlyScanMissingKey = "Metadata.ScreenScraper.OnlyScanMissing"

    /// Effective developer id for API calls (UserDefaults override, else obfuscated built-in).
    static var screenScraperDevID: String? {
        screenScraperDevIDOverride ?? ScreenScraperBuiltInCredentials.devID
    }

    /// Effective developer password for API calls (UserDefaults override, else obfuscated built-in).
    static var screenScraperDevPassword: String? {
        screenScraperDevPasswordOverride ?? ScreenScraperBuiltInCredentials.devPassword
    }

    /// User-entered developer id in Settings (nil when relying on built-in credentials).
    static var screenScraperDevIDOverride: String? {
        get { storedCredential(forKey: devIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: devIDKey) }
    }

    /// User-entered developer password in Settings (nil when relying on built-in credentials).
    static var screenScraperDevPasswordOverride: String? {
        get { storedCredential(forKey: devPasswordKey) }
        set { UserDefaults.standard.set(newValue, forKey: devPasswordKey) }
    }

    static var screenScraperUserID: String? {
        get { UserDefaults.standard.string(forKey: userIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        set { UserDefaults.standard.set(newValue, forKey: userIDKey) }
    }

    static var screenScraperUserPassword: String? {
        get { UserDefaults.standard.string(forKey: userPasswordKey)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        set { UserDefaults.standard.set(newValue, forKey: userPasswordKey) }
    }

    static var isConfigured: Bool {
        screenScraperDevID != nil && screenScraperDevPassword != nil
    }

    static var hasUserCredentials: Bool {
        screenScraperUserID != nil && screenScraperUserPassword != nil
    }

    /// When true, ambiguous multi-platform matches are resolved by the algorithm instead of prompting the user.
    static var screenScraperAutoSelectAmbiguousMatches: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoSelectAmbiguityKey) == nil {
                return false
            }
            return UserDefaults.standard.bool(forKey: autoSelectAmbiguityKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoSelectAmbiguityKey)
        }
    }

    /// When true (default), full library scrapes skip games that already have ScreenScraper cover art.
    static var screenScraperOnlyScanMissing: Bool {
        get {
            if UserDefaults.standard.object(forKey: onlyScanMissingKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: onlyScanMissingKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: onlyScanMissingKey)
        }
    }

    /// Preferred ScreenScraper region short code for covers/titles (`us`, `eu`, `jp`, `wor`, …).
    static var screenScraperPreferredRegion: String {
        get {
            let stored = UserDefaults.standard.string(forKey: preferredRegionKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if let stored, !stored.isEmpty {
                return stored
            }
            return ScreenScraperRegionPreference.defaultRegionCode
        }
        set {
            UserDefaults.standard.set(newValue.lowercased(), forKey: preferredRegionKey)
        }
    }

    private static func storedCredential(forKey key: String) -> String? {
        UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

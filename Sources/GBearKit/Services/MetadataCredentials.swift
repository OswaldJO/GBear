import Foundation

/// Stores ScreenScraper API credentials.
enum MetadataCredentials {
    private static let devIDKey = "Metadata.ScreenScraper.DevID"
    private static let devPasswordKey = "Metadata.ScreenScraper.DevPassword"
    private static let userIDKey = "Metadata.ScreenScraper.UserID"
    private static let userPasswordKey = "Metadata.ScreenScraper.UserPassword"
    private static let preferredRegionKey = "Metadata.ScreenScraper.PreferredRegion"
    private static let regionPriorityKey = "Metadata.ScreenScraper.RegionPriority"
    private static let autoSelectAmbiguityKey = "Metadata.ScreenScraper.AutoSelectAmbiguity"
    private static let onlyScanMissingKey = "Metadata.ScreenScraper.OnlyScanMissing"
    private static let theGamesDBAPIKeyKey = "Metadata.TheGamesDB.APIKey"
    private static let igdbClientIDKey = "Metadata.IGDB.ClientID"
    private static let igdbClientSecretKey = "Metadata.IGDB.ClientSecret"

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

    /// Personal TheGamesDB API key. Covers are fetched only when this is set.
    static var theGamesDBAPIKey: String? {
        get { UserDefaults.standard.string(forKey: theGamesDBAPIKeyKey)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        set { UserDefaults.standard.set(newValue, forKey: theGamesDBAPIKeyKey) }
    }

    static var hasTheGamesDBAPIKey: Bool {
        theGamesDBAPIKey != nil
    }

    /// Twitch application Client ID for IGDB.
    static var igdbClientID: String? {
        get { storedCredential(forKey: igdbClientIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: igdbClientIDKey) }
    }

    /// Twitch application Client Secret for IGDB.
    static var igdbClientSecret: String? {
        get { storedCredential(forKey: igdbClientSecretKey) }
        set { UserDefaults.standard.set(newValue, forKey: igdbClientSecretKey) }
    }

    static var hasIGDBCredentials: Bool {
        igdbClientID != nil && igdbClientSecret != nil
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

    /// Ranked ScreenScraper region codes for covers/titles. First entry is the primary preference.
    static var screenScraperRegionPriority: [String] {
        get {
            if let stored = UserDefaults.standard.stringArray(forKey: regionPriorityKey), !stored.isEmpty {
                return ScreenScraperRegionPreference.normalizedPriority(stored)
            }
            let legacy = UserDefaults.standard.string(forKey: preferredRegionKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if let legacy, !legacy.isEmpty {
                return ScreenScraperRegionPreference.normalizedPriority([legacy])
            }
            return ScreenScraperRegionPreference.defaultPriorityOrder
        }
        set {
            let normalized = ScreenScraperRegionPreference.normalizedPriority(newValue)
            UserDefaults.standard.set(normalized, forKey: regionPriorityKey)
            if let first = normalized.first {
                UserDefaults.standard.set(first, forKey: preferredRegionKey)
            }
        }
    }

    /// First region in `screenScraperRegionPriority` (manual search default, scrape log).
    static var screenScraperPreferredRegion: String {
        get {
            screenScraperRegionPriority.first ?? ScreenScraperRegionPreference.defaultRegionCode
        }
        set {
            screenScraperRegionPriority = ScreenScraperRegionPreference.normalizedPriority([newValue])
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

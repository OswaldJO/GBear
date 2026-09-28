import Foundation

/// Remote cover sources, in scrape fallback order. Raw values match `LibraryGame.remoteCoverSource`.
/// TheGamesDB is last because its monthly allowance is small.
enum CoverProvider: String, CaseIterable, Sendable {
    case screenScraper = "screenscraper"
    case igdb
    case theGamesDB = "thegamesdb"

    var displayName: String {
        switch self {
        case .screenScraper: return "ScreenScraper"
        case .theGamesDB: return "TheGamesDB"
        case .igdb: return "IGDB"
        }
    }

    /// Manual search uses ScreenScraper whenever the build has developer credentials; the backups need the user's keys.
    var isConfigured: Bool {
        switch self {
        case .screenScraper: return MetadataCredentials.isConfigured
        case .theGamesDB: return MetadataCredentials.hasTheGamesDBAPIKey
        case .igdb: return MetadataCredentials.hasIGDBCredentials
        }
    }

    static var configured: [CoverProvider] {
        allCases.filter(\.isConfigured)
    }
}

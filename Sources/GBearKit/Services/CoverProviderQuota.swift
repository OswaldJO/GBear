import Foundation
import Observation

/// API limits for the cover providers. A provider that hits its limit is blocked until the limit resets, so scrapes skip it
/// and never send requests that would fail. Saved in `UserDefaults` so a relaunch doesn't retry a used-up provider.
///
/// - ScreenScraper: daily request and "unrecognized rom" quotas from `ssuser` in every reply, HTTP 430 / 431 (quota),
///   429 (too fast), 401 / 423 (API closed). Daily quotas reset at midnight, Paris time.
/// - TheGamesDB: `remaining_monthly_allowance` + `extra_allowance` in every reply, HTTP 403 when used up.
///   Resets after `allowance_refresh_timer` seconds, or at the start of next month.
/// - IGDB: no daily quota, only 4 requests per second; repeated HTTP 429 blocks it briefly.
/// - SteamGridDB: no published quota; HTTP 429 blocks it for `Retry-After` seconds (60 s when absent).
@Observable
@MainActor
final class CoverProviderQuota {
    static let shared = CoverProviderQuota()

    struct Status: Codable, Sendable {
        var blockedUntil: Date?
        var reason: String?
        var used: Int?
        var limit: Int?
        var remaining: Int?
        var updatedAt: Date?
    }

    private(set) var statuses: [String: Status]

    private static let defaultsKey = "CoverProviders.QuotaStatus"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Status].self, from: data) {
            statuses = decoded
        } else {
            statuses = [:]
        }
    }

    func status(_ provider: CoverProvider) -> Status {
        statuses[provider.rawValue] ?? Status()
    }

    func isAvailable(_ provider: CoverProvider) -> Bool {
        guard let until = statuses[provider.rawValue]?.blockedUntil else { return true }
        return until <= Date()
    }

    /// Providers a library scrape would call: ScreenScraper only with a user login, the others with the user's keys.
    static var scrapeProviders: [CoverProvider] {
        CoverProvider.allCases.filter { provider in
            switch provider {
            case .screenScraper: return MetadataCredentials.hasUserCredentials && MetadataCredentials.isConfigured
            case .igdb: return MetadataCredentials.hasIGDBCredentials
            case .steamGridDB: return MetadataCredentials.hasSteamGridDBAPIKey
            case .theGamesDB: return MetadataCredentials.hasTheGamesDBAPIKey
            }
        }
    }

    /// True when every provider the scrape would use is at its limit (false when none is set up).
    var allScrapeProvidersBlocked: Bool {
        let providers = Self.scrapeProviders
        return !providers.isEmpty && providers.allSatisfy { !isAvailable($0) }
    }

    /// Earliest time a blocked scrape provider comes back.
    var nextScrapeProviderReset: Date? {
        Self.scrapeProviders.compactMap { isAvailable($0) ? nil : status($0).blockedUntil }.min()
    }

    func block(_ provider: CoverProvider, until: Date, reason: String) {
        update(provider) { status in
            if let current = status.blockedUntil, current > until, current > Date() { return }
            status.blockedUntil = until
            status.reason = reason
        }
        DebugLog.log("Cover provider \(provider.rawValue) blocked until \(until): \(reason)")
    }

    func recordCounts(_ provider: CoverProvider, used: Int?, limit: Int?, remaining: Int?) {
        update(provider) { status in
            if let used { status.used = used }
            if let limit { status.limit = limit }
            if let remaining { status.remaining = remaining }
        }
    }

    /// A new key or login starts with a clean slate.
    func reset(_ provider: CoverProvider) {
        statuses[provider.rawValue] = nil
        save()
    }

    private func update(_ provider: CoverProvider, _ change: (inout Status) -> Void) {
        var status = statuses[provider.rawValue] ?? Status()
        change(&status)
        status.updatedAt = Date()
        statuses[provider.rawValue] = status
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(statuses) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: Reset times

    /// ScreenScraper quotas reset at midnight in France.
    nonisolated static func nextScreenScraperReset(after date: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .gmt
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? date.addingTimeInterval(24 * 3600)
    }

    nonisolated static func startOfNextMonthUTC(after date: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = calendar.dateComponents([.year, .month], from: date)
        let startOfMonth = calendar.date(from: components) ?? date
        return calendar.date(byAdding: .month, value: 1, to: startOfMonth) ?? date.addingTimeInterval(30 * 24 * 3600)
    }

    /// "until 12:00 AM" today/tomorrow, or a date further out.
    nonisolated static func describe(_ date: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: Date()) || date.timeIntervalSinceNow < 36 * 3600 {
            return date.formatted(date: .omitted, time: .shortened) +
                (Calendar.current.isDateInTomorrow(date) ? " tomorrow" : "")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

import Foundation

/// TheGamesDB public API client. Name search plus front box art. No ROM hash lookup.
enum TheGamesDBClient {
    struct CoverMatch: Sendable {
        var gameId: Int
        var title: String
        var coverURL: URL
        /// ScreenScraper-style region code for the edition that supplied the cover (`us`, `jp`, …).
        var regionCode: String?
        /// False when the cover came from another region's edition, so the library keeps its current title.
        var replacesLibraryTitle: Bool
    }

    struct SearchResult: Sendable {
        var match: CoverMatch?
        var remainingMonthlyAllowance: Int?
        /// API calls spent on this search (each one counts against the monthly allowance).
        var requests: Int = 0
    }

    enum TheGamesDBError: Error, LocalizedError {
        case missingAPIKey
        case invalidURL
        case http(Int)
        case quota
        case decoding

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "TheGamesDB API key is missing."
            case .invalidURL:
                return "TheGamesDB URL is invalid."
            case .http(let code):
                return "TheGamesDB HTTP \(code)"
            case .quota:
                return "TheGamesDB monthly allowance is used up; it is paused until the allowance refreshes."
            case .decoding:
                return "TheGamesDB response could not be decoded."
            }
        }
    }

    private static let searchURL = "https://api.thegamesdb.net/v1.1/Games/ByGameName"

    /// First page of `ByGameName` on one platform.
    /// A compatible title is chosen by `regionPriority` (first region that has a front cover).
    /// When the full name has no cover, one follow-up search uses the title through the sequel number so another region's edition can match.
    static func searchFrontCover(
        name: String,
        platformFilter: String,
        regionPriority: [String]
    ) async throws -> SearchResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchResult(match: nil, remainingMonthlyAllowance: nil) }

        let primary = try await fetchGames(name: trimmed, platformFilter: platformFilter)
        if let match = pickCover(from: primary.games, query: trimmed, regionPriority: regionPriority, replacesLibraryTitle: true) {
            return SearchResult(match: match, remainingMonthlyAllowance: primary.allowance, requests: 1)
        }

        if let allowance = primary.allowance, allowance <= 0 {
            return SearchResult(match: nil, remainingMonthlyAllowance: allowance, requests: 1)
        }
        guard let core = RomTitleNormalizer.titleThroughSequelNumber(trimmed),
              core.compare(trimmed, options: .caseInsensitive) != .orderedSame else {
            return SearchResult(match: nil, remainingMonthlyAllowance: primary.allowance, requests: 1)
        }

        let secondary = try await fetchGames(name: core, platformFilter: platformFilter)
        let match = pickCover(from: secondary.games, query: core, regionPriority: regionPriority, replacesLibraryTitle: false)
        return SearchResult(match: match, remainingMonthlyAllowance: secondary.allowance ?? primary.allowance, requests: 2)
    }

    struct ListResult: Sendable {
        var gameId: Int
        var title: String
        var platformName: String?
        var regionCode: String?
        var coverURL: URL?
    }

    /// Every hit on the first page, for manual cover search. No title filtering; `platformFilter` nil searches all consoles.
    static func searchCoverList(name: String, platformFilter: String?) async throws -> [ListResult] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let payload = try await fetchGames(name: trimmed, platformFilter: platformFilter, includePlatformNames: true)
        return payload.games.map { game in
            ListResult(
                gameId: game.id,
                title: game.title,
                platformName: game.platformName,
                regionCode: game.regionId.flatMap { screenScraperRegionCode(forRegionId: $0) },
                coverURL: game.coverURL
            )
        }
    }

    private struct ParsedGame {
        var id: Int
        var title: String
        var regionId: Int?
        var platformName: String?
        var coverURL: URL?
    }

    private struct FetchPayload {
        var games: [ParsedGame]
        var allowance: Int?
    }

    private static func fetchGames(
        name: String,
        platformFilter: String?,
        includePlatformNames: Bool = false
    ) async throws -> FetchPayload {
        guard let apiKey = MetadataCredentials.theGamesDBAPIKey else { throw TheGamesDBError.missingAPIKey }
        var components = URLComponents(string: searchURL)
        var items = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "include", value: includePlatformNames ? "boxart,platform" : "boxart"),
        ]
        if let platformFilter {
            items.append(URLQueryItem(name: "filter[platform]", value: platformFilter))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw TheGamesDBError.invalidURL }
        guard await CoverProviderQuota.shared.isAvailable(.theGamesDB) else { throw TheGamesDBError.quota }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw TheGamesDBError.http(-1) }
        if http.statusCode == 403 {
            await blockForQuota(refreshSeconds: nil)
            throw TheGamesDBError.quota
        }
        guard (200 ... 299).contains(http.statusCode) else { throw TheGamesDBError.http(http.statusCode) }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw TheGamesDBError.decoding
        }
        guard let root = jsonObject as? [String: Any] else { throw TheGamesDBError.decoding }
        let refreshSeconds = intValue(root["allowance_refresh_timer"])
        if intValue(root["code"]) == 403 {
            await blockForQuota(refreshSeconds: refreshSeconds)
            throw TheGamesDBError.quota
        }
        let monthly = intValue(root["remaining_monthly_allowance"])
        let allowance = monthly.map { $0 + (intValue(root["extra_allowance"]) ?? 0) }
        if let allowance {
            await CoverProviderQuota.shared.recordCounts(.theGamesDB, used: nil, limit: nil, remaining: allowance)
            if allowance <= 0 { await blockForQuota(refreshSeconds: refreshSeconds) }
        }
        return FetchPayload(games: parseGames(root), allowance: allowance)
    }

    private static func blockForQuota(refreshSeconds: Int?) async {
        let until = refreshSeconds.flatMap { $0 > 0 ? Date().addingTimeInterval(TimeInterval($0)) : nil }
            ?? CoverProviderQuota.startOfNextMonthUTC()
        await CoverProviderQuota.shared.recordCounts(.theGamesDB, used: nil, limit: nil, remaining: 0)
        await CoverProviderQuota.shared.block(.theGamesDB, until: until, reason: "monthly allowance used up")
    }

    /// TheGamesDB `region_id` → the same short codes as Screen Scrapper region priority.
    private static func screenScraperRegionCode(forRegionId regionId: Int) -> String? {
        switch regionId {
        case 1, 2, 3: return "us" // NTSC, NTSC-U, NTSC-C
        case 4: return "jp" // NTSC-J
        case 5: return "kr" // NTSC-K
        case 6, 8: return "eu" // PAL, PAL-B
        case 7: return "au" // PAL-A
        case 9: return "wor" // Other
        default: return nil
        }
    }

    private static func regionRank(regionId: Int?, priority: [String]) -> Int {
        guard let regionId,
              let code = screenScraperRegionCode(forRegionId: regionId),
              let index = priority.firstIndex(of: code) else {
            return priority.count + 1
        }
        return index
    }

    private static func parseGames(_ root: [String: Any]) -> [ParsedGame] {
        guard let data = root["data"] as? [String: Any] else { return [] }
        let rawGames = data["games"] as? [[String: Any]] ?? []
        let boxart = (root["include"] as? [String: Any])?["boxart"] as? [String: Any]
        let base = ((boxart?["base_url"] as? [String: Any])?["original"] as? String) ?? ""
        let imagesByGame = boxart?["data"] as? [String: Any] ?? [:]
        let platforms = (((root["include"] as? [String: Any])?["platform"] as? [String: Any])?["data"] as? [String: Any]) ?? [:]

        return rawGames.compactMap { game in
            guard let id = intValue(game["id"]) else { return nil }
            let title = (game["game_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            let cover = frontCoverURL(gameId: id, base: base, imagesByGame: imagesByGame)
            let platformName = intValue(game["platform"]).flatMap { platformId in
                (platforms[String(platformId)] as? [String: Any])?["name"] as? String
            }
            return ParsedGame(
                id: id,
                title: title,
                regionId: intValue(game["region_id"]),
                platformName: platformName,
                coverURL: cover
            )
        }
    }

    private static func frontCoverURL(gameId: Int, base: String, imagesByGame: [String: Any]) -> URL? {
        guard !base.isEmpty else { return nil }
        let images = imagesByGame[String(gameId)] as? [[String: Any]] ?? []
        guard let front = images.first(where: { image in
            (image["type"] as? String)?.lowercased() == "boxart"
                && (image["side"] as? String)?.lowercased() == "front"
        }), let filename = front["filename"] as? String, !filename.isEmpty else {
            return nil
        }
        return URL(string: base + filename)
    }

    private static func pickCover(
        from games: [ParsedGame],
        query: String,
        regionPriority: [String],
        replacesLibraryTitle: Bool
    ) -> CoverMatch? {
        let usable: [ParsedGame] = games.filter { game in
            guard game.coverURL != nil else { return false }
            return MetadataService.backupTitleMatches(searchQuery: query, candidate: game.title)
        }
        guard let chosen = usable.min(by: { lhs, rhs in
            let leftRank = regionRank(regionId: lhs.regionId, priority: regionPriority)
            let rightRank = regionRank(regionId: rhs.regionId, priority: regionPriority)
            if leftRank != rightRank { return leftRank < rightRank }
            let leftExact = lhs.title.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            let rightExact = rhs.title.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            if leftExact != rightExact { return leftExact }
            return lhs.title.count < rhs.title.count
        }) else { return nil }
        guard let coverURL = chosen.coverURL else { return nil }
        let regionCode = chosen.regionId.flatMap { screenScraperRegionCode(forRegionId: $0) }
        return CoverMatch(
            gameId: chosen.id,
            title: chosen.title,
            coverURL: coverURL,
            regionCode: regionCode,
            replacesLibraryTitle: replacesLibraryTitle
        )
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? NSNumber { return value.intValue }
        if let value = any as? String { return Int(value) }
        return nil
    }
}

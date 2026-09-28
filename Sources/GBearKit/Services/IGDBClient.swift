import Foundation

/// IGDB API v4 client. Uses the user's Twitch Client ID + Client Secret (app access token). Name search plus cover art.
enum IGDBClient {
    struct CoverMatch: Sendable {
        var gameId: Int
        var title: String
        var coverURL: URL
        /// ScreenScraper-style region code when the cover came from a regional localization (`jp`, `eu`, …).
        var regionCode: String?
        /// False when the match came from an alternative or regional name, so the library keeps its current title.
        var replacesLibraryTitle: Bool
    }

    enum IGDBError: Error, LocalizedError {
        case missingCredentials
        case invalidURL
        case credentialsRejected
        case http(Int)
        case rateLimited
        case decoding

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "IGDB Client ID or Client Secret is missing."
            case .invalidURL:
                return "IGDB URL is invalid."
            case .credentialsRejected:
                return "Twitch rejected the IGDB Client ID or Client Secret."
            case .http(let code):
                return "IGDB HTTP \(code)"
            case .rateLimited:
                return "IGDB rate limit reached (4 requests per second)."
            case .decoding:
                return "IGDB response could not be decoded."
            }
        }
    }

    private static let gamesURL = "https://api.igdb.com/v4/games"
    private static let coverSize = "t_cover_big_2x"

    /// Requests a fresh app access token so Settings can confirm the keys work.
    static func verifyCredentials() async throws {
        let credentials = try currentCredentials()
        await IGDBTokenStore.shared.clear()
        _ = try await IGDBTokenStore.shared.accessToken(clientID: credentials.id, clientSecret: credentials.secret)
    }

    /// Searches one platform. When the full name has no cover, one follow-up search uses the title through the sequel number.
    static func searchFrontCover(
        name: String,
        platformFilter: String,
        regionPriority: [String]
    ) async throws -> CoverMatch? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let primary = try await searchGames(name: trimmed, platformFilter: platformFilter)
        if let match = pickCover(from: primary, query: trimmed, regionPriority: regionPriority, allowTitleReplacement: true) {
            return match
        }

        guard let core = RomTitleNormalizer.titleThroughSequelNumber(trimmed),
              core.compare(trimmed, options: .caseInsensitive) != .orderedSame else {
            return nil
        }
        let secondary = try await searchGames(name: core, platformFilter: platformFilter)
        return pickCover(from: secondary, query: core, regionPriority: regionPriority, allowTitleReplacement: false)
    }

    struct ListResult: Sendable {
        var gameId: Int
        var title: String
        var platformName: String?
        var regionCode: String?
        var coverURL: URL?
    }

    /// Every hit on the first page, for manual cover search. No title filtering; `platformFilter` nil searches all platforms.
    static func searchCoverList(
        name: String,
        platformFilter: String?,
        regionPriority: [String]
    ) async throws -> [ListResult] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let games = try await searchGames(name: trimmed, platformFilter: platformFilter)
        return games.map { game in
            let cover = preferredCover(for: game, regionPriority: regionPriority)
            return ListResult(
                gameId: game.id,
                title: game.name,
                platformName: game.platformNames.first,
                regionCode: cover?.regionCode,
                coverURL: cover?.url
            )
        }
    }

    // MARK: - Request

    private static func currentCredentials() throws -> (id: String, secret: String) {
        guard let id = MetadataCredentials.igdbClientID,
              let secret = MetadataCredentials.igdbClientSecret else {
            throw IGDBError.missingCredentials
        }
        return (id, secret)
    }

    private static func searchGames(name: String, platformFilter: String?) async throws -> [ParsedGame] {
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var lines = [
            "search \"\(escaped)\";",
            "fields name,platforms.name,cover.image_id,alternative_names.name,game_localizations.name," +
                "game_localizations.region.identifier,game_localizations.cover.image_id;",
        ]
        if let platformFilter {
            lines.append("where platforms = (\(platformFilter));")
        }
        lines.append("limit 20;")
        let body = lines.joined(separator: "\n")
        let data = try await post(body: body)
        guard let array = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] else {
            throw IGDBError.decoding
        }
        return array.compactMap(parseGame)
    }

    private static func post(body: String) async throws -> Data {
        let credentials = try currentCredentials()
        guard let url = URL(string: gamesURL) else { throw IGDBError.invalidURL }

        var refreshedToken = false
        var retriedRateLimit = false
        while true {
            let token = try await IGDBTokenStore.shared.accessToken(clientID: credentials.id, clientSecret: credentials.secret)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(credentials.id, forHTTPHeaderField: "Client-ID")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = Data(body.utf8)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw IGDBError.http(-1) }
            switch http.statusCode {
            case 200 ... 299:
                return data
            case 401, 403:
                guard !refreshedToken else { throw IGDBError.credentialsRejected }
                refreshedToken = true
                await IGDBTokenStore.shared.clear()
            case 429:
                guard !retriedRateLimit else { throw IGDBError.rateLimited }
                retriedRateLimit = true
                try? await Task.sleep(for: .seconds(1))
            default:
                throw IGDBError.http(http.statusCode)
            }
        }
    }

    // MARK: - Parsing

    private struct Localization {
        var name: String?
        var regionCode: String?
        var coverURL: URL?
    }

    private struct ParsedGame {
        var id: Int
        var name: String
        var coverURL: URL?
        var alternativeNames: [String]
        var localizations: [Localization]
        var platformNames: [String]
    }

    private static func parseGame(_ raw: [String: Any]) -> ParsedGame? {
        guard let id = intValue(raw["id"]),
              let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        let alternatives = (raw["alternative_names"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let localizations = (raw["game_localizations"] as? [[String: Any]] ?? []).map { item in
            Localization(
                name: item["name"] as? String,
                regionCode: ((item["region"] as? [String: Any])?["identifier"] as? String).flatMap(regionCode(forIdentifier:)),
                coverURL: coverURL(from: item["cover"])
            )
        }
        return ParsedGame(
            id: id,
            name: name,
            coverURL: coverURL(from: raw["cover"]),
            alternativeNames: alternatives,
            localizations: localizations,
            platformNames: (raw["platforms"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        )
    }

    private static func coverURL(from any: Any?) -> URL? {
        guard let cover = any as? [String: Any],
              let imageId = cover["image_id"] as? String,
              !imageId.isEmpty else { return nil }
        return URL(string: "https://images.igdb.com/igdb/image/upload/\(coverSize)/\(imageId).jpg")
    }

    /// IGDB region `identifier` → the same short codes as Screen Scrapper region priority.
    private static func regionCode(forIdentifier identifier: String) -> String? {
        switch identifier.lowercased() {
        case "north_america": return "us"
        case "europe": return "eu"
        case "worldwide": return "wor"
        case "japan": return "jp"
        case "korea": return "kr"
        case "australia", "new_zealand": return "au"
        default: return nil
        }
    }

    // MARK: - Selection

    private static func pickCover(
        from games: [ParsedGame],
        query: String,
        regionPriority: [String],
        allowTitleReplacement: Bool
    ) -> CoverMatch? {
        let compatible: (String) -> Bool = { MetadataService.backupTitleMatches(searchQuery: query, candidate: $0) }

        let ordered = games.sorted { lhs, rhs in
            let leftExact = lhs.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            let rightExact = rhs.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            return leftExact && !rightExact
        }

        for game in ordered {
            let nameMatches = compatible(game.name)
            let otherNameMatches = game.alternativeNames.contains(where: compatible)
                || game.localizations.contains { $0.name.map(compatible) ?? false }
            guard nameMatches || otherNameMatches else { continue }
            guard let cover = preferredCover(for: game, regionPriority: regionPriority) else { continue }
            return CoverMatch(
                gameId: game.id,
                title: game.name,
                coverURL: cover.url,
                regionCode: cover.regionCode,
                replacesLibraryTitle: allowTitleReplacement && nameMatches
            )
        }
        return nil
    }

    /// A regional cover wins only when its region is the user's first choice. Otherwise the main cover is used, then the best-ranked regional cover.
    private static func preferredCover(for game: ParsedGame, regionPriority: [String]) -> (url: URL, regionCode: String?)? {
        let regional = game.localizations
            .compactMap { item -> (url: URL, regionCode: String, rank: Int)? in
                guard let url = item.coverURL, let code = item.regionCode,
                      let rank = regionPriority.firstIndex(of: code) else { return nil }
                return (url, code, rank)
            }
            .sorted { $0.rank < $1.rank }

        if let best = regional.first, best.rank == 0 {
            return (best.url, best.regionCode)
        }
        if let main = game.coverURL {
            return (main, nil)
        }
        if let best = regional.first {
            return (best.url, best.regionCode)
        }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? NSNumber { return value.intValue }
        if let value = any as? String { return Int(value) }
        return nil
    }
}

/// Caches the Twitch app access token for IGDB until shortly before it expires.
actor IGDBTokenStore {
    static let shared = IGDBTokenStore()

    private var token: String?
    private var expiresAt: Date?
    private var clientID: String?

    func clear() {
        token = nil
        expiresAt = nil
        clientID = nil
    }

    func accessToken(clientID: String, clientSecret: String) async throws -> String {
        if let token, let expiresAt, self.clientID == clientID, expiresAt > Date() {
            return token
        }

        var components = URLComponents(string: "https://id.twitch.tv/oauth2/token")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "grant_type", value: "client_credentials"),
        ]
        guard let url = components?.url else { throw IGDBClient.IGDBError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw IGDBClient.IGDBError.http(-1) }
        if (400 ... 403).contains(http.statusCode) { throw IGDBClient.IGDBError.credentialsRejected }
        guard (200 ... 299).contains(http.statusCode) else { throw IGDBClient.IGDBError.http(http.statusCode) }

        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw IGDBClient.IGDBError.decoding
        }
        let lifetime = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        token = accessToken
        expiresAt = Date().addingTimeInterval(max(60, lifetime - 300))
        self.clientID = clientID
        return accessToken
    }
}

import Foundation

/// SteamGridDB API v2 client. Uses the user's API key (Bearer token). Name search plus portrait grids (box-art shaped covers).
/// SteamGridDB games are not tied to a console, so automatic matches rely on the strict backup title check.
enum SteamGridDBClient {
    struct CoverMatch: Sendable {
        var gameId: Int
        var title: String?
        var coverURL: URL
        /// False when the match came from a shortened title or a Steam app id, so the library keeps its current title.
        var replacesLibraryTitle: Bool
    }

    struct ListResult: Sendable {
        /// Grid id, unique per image, so one game can offer several covers.
        var gridId: Int
        var gameId: Int
        var title: String
        var coverURL: URL
    }

    enum SteamGridDBError: Error, LocalizedError {
        case missingAPIKey
        case invalidURL
        case keyRejected
        case rateLimited
        case http(Int)
        case decoding

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "SteamGridDB API key is missing."
            case .invalidURL:
                return "SteamGridDB URL is invalid."
            case .keyRejected:
                return "SteamGridDB rejected the API key."
            case .rateLimited:
                return "SteamGridDB rate limit reached; it is paused briefly."
            case .http(let code):
                return "SteamGridDB HTTP \(code)"
            case .decoding:
                return "SteamGridDB response could not be decoded."
            }
        }
    }

    private static let baseURL = "https://www.steamgriddb.com/api/v2"
    /// Portrait sizes only; the square and wide sizes are Steam library banners, not box art.
    private static let portraitDimensions = "600x900,342x482,660x930"
    private static let manualSearchGameLimit = 6
    private static let manualSearchGridsPerGame = 3

    /// One search so Settings can confirm the key works.
    static func verifyKey() async throws {
        _ = try await searchGames(term: "mario")
    }

    /// Steam games use their app id first. Otherwise searches by name, then once more with the title through the sequel number.
    static func searchFrontCover(name: String, steamAppID: String? = nil) async throws -> CoverMatch? {
        if let steamAppID = steamAppID?.trimmingCharacters(in: .whitespacesAndNewlines), !steamAppID.isEmpty,
           let grid = try await grids(path: "/grids/steam/\(steamAppID)", limit: 1).first {
            return CoverMatch(gameId: grid.id, title: nil, coverURL: grid.url, replacesLibraryTitle: false)
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let match = try await pickCover(query: trimmed, replacesLibraryTitle: true) {
            return match
        }
        guard let core = RomTitleNormalizer.titleThroughSequelNumber(trimmed),
              core.compare(trimmed, options: .caseInsensitive) != .orderedSame else {
            return nil
        }
        return try await pickCover(query: core, replacesLibraryTitle: false)
    }

    /// Top search hits with a few covers each, for manual cover search. No title filtering.
    static func searchCoverList(name: String) async throws -> [ListResult] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let games = Array(try await searchGames(term: trimmed).prefix(manualSearchGameLimit))

        let perGame = try await withThrowingTaskGroup(of: (Int, [ListResult]).self) { group in
            for (index, game) in games.enumerated() {
                group.addTask {
                    let found = try await grids(path: "/grids/game/\(game.id)", limit: manualSearchGridsPerGame)
                    return (index, found.map { ListResult(gridId: $0.id, gameId: game.id, title: game.name, coverURL: $0.url) })
                }
            }
            var collected: [(Int, [ListResult])] = []
            for try await entry in group {
                collected.append(entry)
            }
            return collected
        }
        return perGame.sorted { $0.0 < $1.0 }.flatMap(\.1)
    }

    // MARK: - Matching

    private static func pickCover(query: String, replacesLibraryTitle: Bool) async throws -> CoverMatch? {
        let compatible = try await searchGames(term: query)
            .filter { MetadataService.backupTitleMatches(searchQuery: query, candidate: $0.name) }
            .enumerated()
            .sorted { lhs, rhs in
                let leftExact = lhs.element.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                let rightExact = rhs.element.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                return leftExact != rightExact ? leftExact : lhs.offset < rhs.offset
            }
            .map(\.element)

        for game in compatible.prefix(2) {
            if let grid = try await grids(path: "/grids/game/\(game.id)", limit: 1).first {
                return CoverMatch(gameId: game.id, title: game.name, coverURL: grid.url, replacesLibraryTitle: replacesLibraryTitle)
            }
        }
        return nil
    }

    // MARK: - Requests

    private struct Game {
        var id: Int
        var name: String
    }

    private struct Grid {
        var id: Int
        var url: URL
        var score: Int
    }

    private static func searchGames(term: String) async throws -> [Game] {
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) else {
            throw SteamGridDBError.invalidURL
        }
        guard let data = try await get(path: "/search/autocomplete/\(encoded)", query: []) else { return [] }
        return data.compactMap { item in
            guard let id = intValue(item["id"]),
                  let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return Game(id: id, name: name)
        }
    }

    /// Static portrait grids, safe-for-work and non-humor, best score first.
    private static func grids(path: String, limit: Int) async throws -> [Grid] {
        let query = [
            URLQueryItem(name: "dimensions", value: portraitDimensions),
            URLQueryItem(name: "types", value: "static"),
            URLQueryItem(name: "nsfw", value: "false"),
            URLQueryItem(name: "humor", value: "false"),
            URLQueryItem(name: "limit", value: String(max(limit, 1) + 2)),
        ]
        guard let data = try await get(path: path, query: query) else { return [] }
        let parsed: [Grid] = data.compactMap { item in
            guard let id = intValue(item["id"]),
                  let urlString = item["url"] as? String,
                  let url = URL(string: urlString) else { return nil }
            return Grid(id: id, url: url, score: intValue(item["score"]) ?? 0)
        }
        return Array(parsed.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
            .prefix(limit))
    }

    /// `data` array of a successful reply, or nil when the game or term is unknown (404).
    private static func get(path: String, query: [URLQueryItem]) async throws -> [[String: Any]]? {
        guard let apiKey = MetadataCredentials.steamGridDBAPIKey else { throw SteamGridDBError.missingAPIKey }
        guard var components = URLComponents(string: baseURL) else { throw SteamGridDBError.invalidURL }
        components.percentEncodedPath += path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SteamGridDBError.invalidURL }
        guard await CoverProviderQuota.shared.isAvailable(.steamGridDB) else { throw SteamGridDBError.rateLimited }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SteamGridDBError.http(-1) }
        switch http.statusCode {
        case 200 ... 299:
            break
        case 401, 403:
            throw SteamGridDBError.keyRejected
        case 404:
            return nil
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init) ?? 60
            await CoverProviderQuota.shared.block(
                .steamGridDB,
                until: Date().addingTimeInterval(max(retryAfter, 5)),
                reason: "rate limit"
            )
            throw SteamGridDBError.rateLimited
        default:
            throw SteamGridDBError.http(http.statusCode)
        }

        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            throw SteamGridDBError.decoding
        }
        guard (root["success"] as? Bool) ?? true else { return nil }
        return root["data"] as? [[String: Any]] ?? []
    }

    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#%")
        return set
    }()

    private static func intValue(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? NSNumber { return value.intValue }
        if let value = any as? String { return Int(value) }
        return nil
    }
}

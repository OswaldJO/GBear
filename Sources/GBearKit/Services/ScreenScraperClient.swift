import Foundation

struct ScreenScraperGameMatch: Sendable, Identifiable, Hashable {
    var id: Int { gameId }
    let gameId: Int
    let systemId: Int
    let systemName: String
    let title: String
    let coverURL: URL?
}

/// ScreenScraper API v2 client (https://www.screenscraper.fr/webapi2.php).
enum ScreenScraperClient {
    enum ScreenScraperError: Error, LocalizedError {
        case missingCredentials
        case invalidURL
        case http(Int)
        case decoding
        case noResults

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "ScreenScraper credentials are missing."
            case .invalidURL:
                return "ScreenScraper URL is invalid."
            case .http(let code):
                return "ScreenScraper HTTP \(code)"
            case .decoding:
                return "ScreenScraper response could not be decoded."
            case .noResults:
                return "No ScreenScraper match for this title."
            }
        }
    }

    private static let searchURL = "https://api.screenscraper.fr/api2/jeuRecherche.php"
    private static let gameInfoURL = "https://api.screenscraper.fr/api2/jeuInfos.php"
    private static let softName = "GBearMac"

    static func searchGames(
        searchQuery: String,
        systemId: Int? = nil,
        coverRegion: String? = nil
    ) async throws -> [ScreenScraperGameMatch] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ScreenScraperError.noResults }

        let jsonObject = try await requestJSON(
            baseURL: searchURL,
            extraQueryItems: {
                var items = [URLQueryItem(name: "recherche", value: trimmed)]
                if let systemId {
                    items.append(URLQueryItem(name: "systemeid", value: String(systemId)))
                }
                return items
            }()
        )
        let games = allGames(in: jsonObject)
        guard !games.isEmpty else { throw ScreenScraperError.noResults }
        let preferredRegion = effectiveCoverRegion(coverRegion)
        let matches = games.compactMap { game -> ScreenScraperGameMatch? in
            guard !isNotGame(game) else { return nil }
            return parseGameMatch(from: game, preferredRegion: preferredRegion)
        }
        guard !matches.isEmpty else { throw ScreenScraperError.noResults }
        return matches
    }

    /// Checksum / exact-filename lookup via `jeuInfos.php` (highest-accuracy ScreenScraper match path).
    static func lookupByRom(
        fingerprint: RomFingerprint,
        systemId: Int,
        coverRegion: String? = nil
    ) async throws -> ScreenScraperGameMatch? {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "systemeid", value: String(systemId)),
            URLQueryItem(name: "romnom", value: fingerprint.romFileName),
            URLQueryItem(name: "romtaille", value: String(fingerprint.fileSize)),
            URLQueryItem(name: "romtype", value: fingerprint.romType),
        ]
        if let md5 = fingerprint.md5Hash {
            items.append(URLQueryItem(name: "md5", value: md5))
        }
        if let crc32 = fingerprint.crc32Hash {
            items.append(URLQueryItem(name: "crc", value: crc32))
        }
        if let sha1 = fingerprint.sha1Hash {
            items.append(URLQueryItem(name: "sha1", value: sha1))
        }

        let jsonObject = try await requestJSON(baseURL: gameInfoURL, extraQueryItems: items)
        let preferredRegion = effectiveCoverRegion(coverRegion)
        for game in allGames(in: jsonObject) {
            guard !isNotGame(game), let match = parseGameMatch(from: game, preferredRegion: preferredRegion) else { continue }
            return match
        }
        return nil
    }

    static func fetchGame(
        gameId: Int,
        systemId: Int,
        fallbackTitle: String,
        coverRegion: String? = nil
    ) async throws -> ScreenScraperGameMatch {
        let jsonObject = try await requestJSON(
            baseURL: gameInfoURL,
            extraQueryItems: [
                URLQueryItem(name: "gameid", value: String(gameId)),
                URLQueryItem(name: "systemeid", value: String(systemId)),
            ]
        )
        guard let game = firstGame(in: jsonObject) else { throw ScreenScraperError.noResults }
        let preferredRegion = effectiveCoverRegion(coverRegion)
        if let match = parseGameMatch(from: game, preferredRegion: preferredRegion) {
            return match
        }
        let title = extractedTitle(from: game, preferredRegion: preferredRegion) ?? fallbackTitle
        let cover = extractedCoverURL(from: game, preferredRegion: preferredRegion)
        return ScreenScraperGameMatch(
            gameId: gameId,
            systemId: systemId,
            systemName: ScreenScraperPlatformMap.displayName(forSystemId: systemId),
            title: title,
            coverURL: cover
        )
    }

    static func fetchCoverAndTitle(
        searchQuery: String,
        systemId: Int? = nil
    ) async throws -> (title: String, coverURL: URL?) {
        let matches = try await searchGames(searchQuery: searchQuery, systemId: systemId)
        guard let first = matches.first else { throw ScreenScraperError.noResults }
        return (first.title, first.coverURL)
    }

    private static func effectiveCoverRegion(_ override: String?) -> String {
        let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return MetadataCredentials.screenScraperPreferredRegion
    }

    // MARK: - Networking

    private static func requestJSON(
        baseURL: String,
        extraQueryItems: [URLQueryItem]
    ) async throws -> Any {
        guard let devID = MetadataCredentials.screenScraperDevID,
              let devPassword = MetadataCredentials.screenScraperDevPassword else {
            throw ScreenScraperError.missingCredentials
        }

        var components = URLComponents(string: baseURL)
        var queryItems = buildBaseQueryItems(devID: devID, devPassword: devPassword)
        queryItems.append(contentsOf: extraQueryItems)
        components?.queryItems = queryItems
        guard let url = components?.url else { throw ScreenScraperError.invalidURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw ScreenScraperError.http(-1) }
        guard (200 ... 299).contains(http.statusCode) else { throw ScreenScraperError.http(http.statusCode) }

        do {
            return try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ScreenScraperError.decoding
        }
    }

    private static func buildBaseQueryItems(devID: String, devPassword: String) -> [URLQueryItem] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "devid", value: devID),
            URLQueryItem(name: "devpassword", value: devPassword),
            URLQueryItem(name: "softname", value: softName),
            URLQueryItem(name: "output", value: "json"),
        ]
        if let userID = MetadataCredentials.screenScraperUserID?.trimmingCharacters(in: .whitespacesAndNewlines), !userID.isEmpty {
            queryItems.append(URLQueryItem(name: "ssid", value: userID))
        }
        if let userPassword = MetadataCredentials.screenScraperUserPassword?.trimmingCharacters(in: .whitespacesAndNewlines), !userPassword.isEmpty {
            queryItems.append(URLQueryItem(name: "sspassword", value: userPassword))
        }
        return queryItems
    }

    // MARK: - Parsing

    private static func isNotGame(_ game: [String: Any]) -> Bool {
        if let flag = game["notgame"] as? Bool, flag { return true }
        if let flag = game["notgame"] as? String, flag.lowercased() == "true" { return true }
        let candidates = [
            game["nom"] as? String,
            extractedTitle(from: game, preferredRegion: nil),
        ]
        for raw in candidates {
            guard let raw else { continue }
            let upper = raw.uppercased()
            if upper.contains("ZZZ(NOTGAME)") || upper.contains("ZZZNOTGAME") {
                return true
            }
        }
        return false
    }

    private static func parseGameMatch(from game: [String: Any], preferredRegion: String?) -> ScreenScraperGameMatch? {
        let gameId = extractGameId(from: game)
        let systemId = extractSystemId(from: game)
        guard let gameId, let systemId else { return nil }
        let title = decodeHTMLEntities(extractedTitle(from: game, preferredRegion: preferredRegion) ?? "Unknown")
        let cover = extractedCoverURL(from: game, preferredRegion: preferredRegion)
        return ScreenScraperGameMatch(
            gameId: gameId,
            systemId: systemId,
            systemName: ScreenScraperPlatformMap.displayName(forSystemId: systemId),
            title: title,
            coverURL: cover
        )
    }

    private static func extractGameId(from game: [String: Any]) -> Int? {
        intValue(game["id"]) ?? intValue(game["jeuid"]) ?? intValue(game["gameid"])
    }

    private static func extractSystemId(from game: [String: Any]) -> Int? {
        if let direct = intValue(game["systemeid"]) { return direct }
        if let systeme = game["systeme"] as? [String: Any] {
            return intValue(systeme["id"])
        }
        return intValue(game["systeme"])
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func allGames(in json: Any) -> [[String: Any]] {
        guard let root = json as? [String: Any] else { return [] }
        if let response = root["response"] as? [String: Any] {
            if let jeux = response["jeux"] as? [[String: Any]], !jeux.isEmpty {
                return jeux
            }
            if let jeu = response["jeu"] as? [String: Any] {
                return [jeu]
            }
        }
        if let jeux = root["jeux"] as? [[String: Any]], !jeux.isEmpty {
            return jeux
        }
        if let jeu = root["jeu"] as? [String: Any] {
            return [jeu]
        }
        return []
    }

    private static func firstGame(in json: Any) -> [String: Any]? {
        allGames(in: json).first
    }

    private static func extractedTitle(from game: [String: Any], preferredRegion: String?) -> String? {
        let regionOrder = ScreenScraperRegionPreference.mediaRegionOrder(preferredCode: preferredRegion)

        if let nameEntries = game["noms"] as? [[String: Any]] {
            for region in regionOrder {
                if let entry = nameEntries.first(where: { nameRegion($0) == region }),
                   let text = nameText(entry), !text.isEmpty {
                    return text
                }
            }
            for entry in nameEntries {
                if let text = nameText(entry), !text.isEmpty { return text }
            }
        }

        if let names = game["noms"] as? [String: Any] {
            for region in regionOrder {
                let key = "nom_\(region)"
                if let value = names[key] as? String, !value.isEmpty { return value }
            }
            for value in names.values {
                if let text = value as? String, !text.isEmpty { return text }
            }
        }

        if let nom = game["nom"] as? String, !nom.isEmpty { return nom }
        return nil
    }

    private static func nameRegion(_ entry: [String: Any]) -> String? {
        (entry["region"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func nameText(_ entry: [String: Any]) -> String? {
        if let text = entry["text"] as? String { return text }
        if let text = entry["nom"] as? String { return text }
        return nil
    }

    private static func extractedCoverURL(from game: [String: Any], preferredRegion: String?) -> URL? {
        guard let medias = game["medias"] else { return nil }
        let regionOrder = ScreenScraperRegionPreference.mediaRegionOrder(preferredCode: preferredRegion)
        var ranked: [(regionRank: Int, typeRank: Int, url: URL)] = []

        if let mediaEntries = medias as? [[String: Any]] {
            for entry in mediaEntries {
                guard let type = (entry["type"] as? String)?.lowercased(),
                      let url = valueAsURL(entry["url"]) else { continue }
                let typeRank = coverTypeRank(forKey: type)
                guard typeRank < 90 else { continue }
                let region = (entry["region"] as? String)?.lowercased() ?? ""
                let regionRank = regionOrder.firstIndex(of: region) ?? regionOrder.count
                ranked.append((regionRank, typeRank, url))
            }
        } else {
            collectNestedCoverCandidates(from: medias, regionOrder: regionOrder, ranked: &ranked)
        }

        return ranked.sorted {
            if $0.regionRank != $1.regionRank { return $0.regionRank < $1.regionRank }
            return $0.typeRank < $1.typeRank
        }.first?.url
    }

    private static func collectNestedCoverCandidates(
        from object: Any,
        regionOrder: [String],
        ranked: inout [(regionRank: Int, typeRank: Int, url: URL)]
    ) {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                let lower = key.lowercased()
                if let url = valueAsURL(value) {
                    let typeRank = coverTypeRank(forKey: lower)
                    guard typeRank < 90 else { continue }
                    let regionRank = coverRegionRank(forKey: lower, regionOrder: regionOrder)
                    ranked.append((regionRank, typeRank, url))
                } else {
                    collectNestedCoverCandidates(from: value, regionOrder: regionOrder, ranked: &ranked)
                }
            }
        } else if let list = object as? [Any] {
            for item in list {
                collectNestedCoverCandidates(from: item, regionOrder: regionOrder, ranked: &ranked)
            }
        }
    }

    private static func coverTypeRank(forKey key: String) -> Int {
        if key == "box-2d" || key.contains("boitier_2d") || key.contains("box2d") { return 0 }
        if key.contains("wheel") && !key.contains("carbon") && !key.contains("steel") { return 1 }
        if key.contains("marquee") || key.contains("screenmarquee") { return 2 }
        if key == "ss" || key == "sstitle" { return 3 }
        if key.contains("fanart") { return 4 }
        if key.contains("screenshot") { return 5 }
        return 90
    }

    private static func coverRegionRank(forKey key: String, regionOrder: [String]) -> Int {
        for (index, region) in regionOrder.enumerated() where key.hasSuffix("_\(region)") || key.contains("_\(region)") {
            return index
        }
        return regionOrder.count
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private static func valueAsURL(_ value: Any?) -> URL? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") {
            return URL(string: "https:" + trimmed)
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        return nil
    }
}

import Foundation

/// Steam: installed games from local app manifests, owned games from the Steam Web API (user's own key + SteamID from Steam sign-in).
enum SteamClient {
    static let openIDReturnURL = "https://gbear.invalid/steam/openid"

    /// Steam OpenID sign-in page. Returns to `openIDReturnURL` with `openid.claimed_id` holding the SteamID64.
    static var openIDLoginURL: URL {
        var components = URLComponents(string: "https://steamcommunity.com/openid/login")!
        components.queryItems = [
            URLQueryItem(name: "openid.ns", value: "http://specs.openid.net/auth/2.0"),
            URLQueryItem(name: "openid.mode", value: "checkid_setup"),
            URLQueryItem(name: "openid.return_to", value: openIDReturnURL),
            URLQueryItem(name: "openid.realm", value: "https://gbear.invalid"),
            URLQueryItem(name: "openid.identity", value: "http://specs.openid.net/auth/2.0/identifier_select"),
            URLQueryItem(name: "openid.claimed_id", value: "http://specs.openid.net/auth/2.0/identifier_select"),
        ]
        return components.url!
    }

    static func steamID(fromOpenIDReturn url: URL) -> String? {
        guard url.absoluteString.hasPrefix(openIDReturnURL) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let claimed = items.first(where: { $0.name == "openid.claimed_id" })?.value else { return nil }
        let id = claimed.split(separator: "/").last.map(String.init) ?? ""
        return id.allSatisfy(\.isNumber) && !id.isEmpty ? id : nil
    }

    // MARK: Owned

    static func ownedGames() async throws -> [StorefrontGame] {
        guard let key = StorefrontCredentials.steamAPIKey, let steamID = StorefrontCredentials.steamID else {
            throw StorefrontError.notSignedIn
        }
        var components = URLComponents(string: "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/")!
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "steamid", value: steamID),
            URLQueryItem(name: "include_appinfo", value: "1"),
            URLQueryItem(name: "include_played_free_games", value: "1"),
            URLQueryItem(name: "format", value: "json"),
        ]
        let root = try await StorefrontHTTP.json(URLRequest(url: components.url!), store: "Steam")
        let games = (root["response"] as? [String: Any])?["games"] as? [[String: Any]] ?? []
        return games.compactMap { game in
            guard let appID = (game["appid"] as? NSNumber)?.stringValue,
                  let name = game["name"] as? String, !name.isEmpty else { return nil }
            return StorefrontGame(store: .steam, gameID: appID, title: name, installed: false, coverURL: coverURL(appID: appID))
        }
    }

    static func personaName() async -> String? {
        guard let key = StorefrontCredentials.steamAPIKey, let steamID = StorefrontCredentials.steamID else { return nil }
        var components = URLComponents(string: "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/")!
        components.queryItems = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "steamids", value: steamID)]
        guard let root = try? await StorefrontHTTP.json(URLRequest(url: components.url!), store: "Steam") else { return nil }
        let players = (root["response"] as? [String: Any])?["players"] as? [[String: Any]]
        return players?.first?["personaname"] as? String
    }

    /// Portrait library art; `fallbackCoverURL` covers older apps that never got one.
    static func coverURL(appID: String) -> URL? {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/library_600x900_2x.jpg")
    }

    static func fallbackCoverURL(appID: String) -> URL? {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg")
    }

    // MARK: Installed

    /// Steamworks Common Redistributables and similar non-games.
    private static let ignoredAppIDs: Set<String> = ["228980"]

    static func installedGames() -> [StorefrontGame] {
        let steamRoot = ("~/Library/Application Support/Steam" as NSString).expandingTildeInPath
        var libraries = [steamRoot]
        let foldersFile = (steamRoot as NSString).appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOfFile: foldersFile, encoding: .utf8) {
            let root = VDF.parse(text)
            if let folders = root["libraryfolders"] as? [String: Any] {
                for value in folders.values {
                    if let folder = value as? [String: Any], let path = folder["path"] as? String {
                        libraries.append(path)
                    }
                }
            }
        }

        var seen = Set<String>()
        var games: [StorefrontGame] = []
        for library in Set(libraries.map { ($0 as NSString).standardizingPath }) {
            let steamapps = (library as NSString).appendingPathComponent("steamapps")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: steamapps)) ?? []
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                let path = (steamapps as NSString).appendingPathComponent(file)
                guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                      let state = VDF.parse(text)["AppState"] as? [String: Any],
                      let appID = state["appid"] as? String,
                      !ignoredAppIDs.contains(appID),
                      seen.insert(appID).inserted else { continue }
                let flags = Int(state["StateFlags"] as? String ?? "") ?? 0
                guard flags & 4 != 0 else { continue }
                let name = (state["name"] as? String) ?? "Steam app \(appID)"
                let installDir = (state["installdir"] as? String).map {
                    ((steamapps as NSString).appendingPathComponent("common") as NSString).appendingPathComponent($0)
                }
                games.append(StorefrontGame(
                    store: .steam,
                    gameID: appID,
                    title: name,
                    installed: true,
                    installPath: installDir,
                    coverURL: coverURL(appID: appID)
                ))
            }
        }
        return games
    }
}

/// Minimal Valve KeyValues (VDF / ACF) parser: quoted keys, quoted values, and nested braces.
enum VDF {
    static func parse(_ text: String) -> [String: Any] {
        var tokens: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "\"" {
                var value = ""
                index = text.index(after: index)
                while index < text.endIndex, text[index] != "\"" {
                    if text[index] == "\\", text.index(after: index) < text.endIndex {
                        index = text.index(after: index)
                    }
                    value.append(text[index])
                    index = text.index(after: index)
                }
                tokens.append(value)
            } else if char == "{" || char == "}" {
                tokens.append(String(char))
            }
            if index < text.endIndex { index = text.index(after: index) }
        }
        var position = 0
        return parseObject(tokens, &position)
    }

    private static func parseObject(_ tokens: [String], _ position: inout Int) -> [String: Any] {
        var object: [String: Any] = [:]
        while position < tokens.count {
            let key = tokens[position]
            position += 1
            if key == "}" { break }
            guard position < tokens.count else { break }
            if tokens[position] == "{" {
                position += 1
                object[key] = parseObject(tokens, &position)
            } else {
                object[key] = tokens[position]
                position += 1
            }
        }
        return object
    }
}

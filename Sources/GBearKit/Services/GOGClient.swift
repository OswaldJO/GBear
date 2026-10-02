import Foundation

/// GOG: sign-in with the GOG Galaxy OAuth client (same flow open-source launchers use), owned games from the account API,
/// installed games from `goggame-<id>.info` files in app bundles.
enum GOGClient {
    private static let clientID = "46899977096215655"
    private static let clientSecret = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"
    static let redirectURI = "https://embed.gog.com/on_login_success?origin=client"

    static var loginURL: URL {
        var components = URLComponents(string: "https://auth.gog.com/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "layout", value: "client2"),
        ]
        return components.url!
    }

    /// Authorization code from the redirect after the user signs in.
    static func authorizationCode(fromRedirect url: URL) -> String? {
        guard url.host == "embed.gog.com", url.path.hasPrefix("/on_login_success") else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
    }

    /// Code from a pasted `on_login_success` address (signed in through the browser), or a bare pasted code.
    static func authorizationCode(fromPastedText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.host != nil {
            return authorizationCode(fromRedirect: url)
        }
        if !trimmed.isEmpty, trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
            return trimmed
        }
        return nil
    }

    static func signIn(code: String) async throws {
        let token = try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
        ])
        if let name = await username(accessToken: token) {
            StorefrontCredentials.setAccountName(name, for: .gog)
        }
    }

    /// Fresh access token; the rotated refresh token is saved back to the Keychain.
    private static func accessToken() async throws -> String {
        guard let refresh = StorefrontCredentials.refreshToken(for: .gog) else { throw StorefrontError.notSignedIn }
        return try await requestToken(["grant_type": "refresh_token", "refresh_token": refresh])
    }

    private static func requestToken(_ fields: [String: String]) async throws -> String {
        var components = URLComponents(string: "https://auth.gog.com/token")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
        ] + fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        let root: [String: Any]
        do {
            root = try await StorefrontHTTP.json(URLRequest(url: components.url!), store: "GOG")
        } catch StorefrontError.http(_, let code) where code == 400 || code == 401 {
            throw StorefrontError.signInFailed("GOG sign-in expired. Sign in again.")
        }
        guard let access = root["access_token"] as? String else { throw StorefrontError.decoding("GOG") }
        if let refresh = root["refresh_token"] as? String {
            StorefrontCredentials.setRefreshToken(refresh, for: .gog)
        }
        return access
    }

    private static func username(accessToken: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://embed.gog.com/userData.json")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return (try? await StorefrontHTTP.json(request, store: "GOG"))?["username"] as? String
    }

    // MARK: Owned

    static func ownedGames() async throws -> [StorefrontGame] {
        let token = try await accessToken()
        var games: [StorefrontGame] = []
        var page = 1
        var totalPages = 1
        repeat {
            var request = URLRequest(url: URL(string: "https://embed.gog.com/account/getFilteredProducts?mediaType=1&page=\(page)")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let root = try await StorefrontHTTP.json(request, store: "GOG")
            totalPages = (root["totalPages"] as? NSNumber)?.intValue ?? 1
            for product in root["products"] as? [[String: Any]] ?? [] {
                guard let id = (product["id"] as? NSNumber)?.stringValue,
                      let title = product["title"] as? String, !title.isEmpty else { continue }
                let image = (product["image"] as? String).flatMap { URL(string: "https:\($0).jpg") }
                games.append(StorefrontGame(store: .gog, gameID: id, title: title, installed: false, coverURL: image))
            }
            page += 1
        } while page <= totalPages
        return games
    }

    /// Portrait box art from GOG's games database; nil when GOG has none.
    static func verticalCoverURL(productID: String) async -> URL? {
        guard let url = URL(string: "https://gamesdb.gog.com/platforms/gog/external_releases/\(productID)"),
              let root = try? await StorefrontHTTP.json(URLRequest(url: url), store: "GOG"),
              let game = root["game"] as? [String: Any],
              let cover = game["vertical_cover"] as? [String: Any],
              let format = cover["url_format"] as? String else { return nil }
        let resolved = format
            .replacingOccurrences(of: "{formatter}", with: "")
            .replacingOccurrences(of: "{ext}", with: "jpg")
        return URL(string: resolved)
    }

    // MARK: Installed

    static func installedGames() -> [StorefrontGame] {
        let roots = [
            "/Applications",
            ("~/Applications" as NSString).expandingTildeInPath,
            ("~/GOG Games" as NSString).expandingTildeInPath,
            "/Applications/GOG Games",
        ]
        var seen = Set<String>()
        var games: [StorefrontGame] = []
        let fm = FileManager.default
        for root in roots {
            for item in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let itemPath = (root as NSString).appendingPathComponent(item)
                let infoDirs = item.hasSuffix(".app")
                    ? [(itemPath as NSString).appendingPathComponent("Contents/Resources")]
                    : [itemPath]
                for dir in infoDirs {
                    for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? []
                    where file.hasPrefix("goggame-") && file.hasSuffix(".info") {
                        let infoPath = (dir as NSString).appendingPathComponent(file)
                        guard let data = fm.contents(atPath: infoPath),
                              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        let id = (info["gameId"] as? String) ?? String(file.dropFirst(8).dropLast(5))
                        // DLC ship their own info file whose rootGameId points at the base game.
                        if let rootID = info["rootGameId"] as? String, rootID != id { continue }
                        guard seen.insert(id).inserted else { continue }
                        let name = (info["name"] as? String) ?? (item as NSString).deletingPathExtension
                        games.append(StorefrontGame(store: .gog, gameID: id, title: name, installed: true, installPath: itemPath))
                    }
                }
            }
        }
        return games
    }
}

import Foundation

/// Epic Games: sign-in with the Epic Games Launcher OAuth client (same flow open-source launchers use),
/// owned games from the library service + catalog, installed games from launcher manifests.
enum EpicClient {
    private static let basicAuth = Data("34a02cf8f4414e29b15921876da36f9a:daafbccc737745039dffe53d94fc76cf".utf8).base64EncodedString()
    private static let tokenURL = URL(string: "https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/token")!

    /// Epic sign-in page. After login it lands on a JSON page containing `authorizationCode`.
    static let loginURL = URL(
        string: "https://www.epicgames.com/id/login?redirectUrl=https%3A%2F%2Fwww.epicgames.com%2Fid%2Fapi%2Fredirect%3FclientId%3D34a02cf8f4414e29b15921876da36f9a%26responseType%3Dcode"
    )!

    static func isAuthorizationCodePage(_ url: URL) -> Bool {
        url.host?.hasSuffix("epicgames.com") == true && url.path.hasPrefix("/id/api/redirect")
    }

    /// Parses the redirect page body (`{"authorizationCode": "…"}`), or accepts a bare pasted code.
    static func authorizationCode(fromPageText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object["authorizationCode"] as? String
        }
        if !trimmed.isEmpty, trimmed.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return trimmed
        }
        return nil
    }

    static func signIn(code: String) async throws {
        let root = try await requestToken(["grant_type": "authorization_code", "code": code, "token_type": "eg1"])
        StorefrontCredentials.setAccountName(root["displayName"] as? String, for: .epic)
    }

    private static func accessToken() async throws -> String {
        guard let refresh = StorefrontCredentials.refreshToken(for: .epic) else { throw StorefrontError.notSignedIn }
        let root = try await requestToken(["grant_type": "refresh_token", "refresh_token": refresh, "token_type": "eg1"])
        guard let access = root["access_token"] as? String else { throw StorefrontError.decoding("Epic") }
        return access
    }

    private static func requestToken(_ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("basic \(basicAuth)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = StorefrontHTTP.formBody(fields)
        let root: [String: Any]
        do {
            root = try await StorefrontHTTP.json(request, store: "Epic")
        } catch StorefrontError.http(_, let code) where code == 400 || code == 401 {
            throw StorefrontError.signInFailed("Epic sign-in expired. Sign in again.")
        }
        if let refresh = root["refresh_token"] as? String {
            StorefrontCredentials.setRefreshToken(refresh, for: .epic)
        }
        return root
    }

    // MARK: Owned

    private struct LibraryRecord: Sendable {
        var namespace: String
        var catalogItemID: String
        var appName: String
    }

    private enum CatalogResult: Sendable {
        case game(StorefrontGame)
        case notGame(appName: String)
        case unavailable
    }

    /// App names the catalog showed are not games (DLC, add-ons, Unreal / Fab marketplace content); skipped without a lookup.
    private static var nonGameAppNames: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "Storefronts.Epic.NonGameAppNames") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "Storefronts.Epic.NonGameAppNames") }
    }

    /// Bumped when the game filter changes so rows already in the library get re-checked once.
    private static let gameFilterVersion = 2
    private static let gameFilterVersionKey = "Storefronts.Epic.GameFilterVersion"

    /// Owned games. `knownAppNames` are already in the library and skip the per-item catalog lookup
    /// (except once after the game filter changes). `ownedAppNames` leaves out non-games, so their rows are removed.
    static func ownedGames(knownAppNames: Set<String>) async throws -> (games: [StorefrontGame], ownedAppNames: Set<String>) {
        let recheckKnown = UserDefaults.standard.integer(forKey: gameFilterVersionKey) < gameFilterVersion
        let token = try await accessToken()
        var records: [LibraryRecord] = []
        var cursor: String?
        repeat {
            var components = URLComponents(string: "https://library-service.live.use1a.on.epicgames.com/library/api/public/items")!
            components.queryItems = [URLQueryItem(name: "includeMetadata", value: "true")]
            if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
            var request = URLRequest(url: components.url!)
            request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
            let root = try await StorefrontHTTP.json(request, store: "Epic")
            for record in root["records"] as? [[String: Any]] ?? [] {
                guard let namespace = record["namespace"] as? String, namespace != "ue",
                      (record["sandboxType"] as? String)?.lowercased() != "private",
                      let catalogItemID = record["catalogItemId"] as? String,
                      let appName = record["appName"] as? String, !appName.isEmpty else { continue }
                records.append(LibraryRecord(namespace: namespace, catalogItemID: catalogItemID, appName: appName))
            }
            cursor = (root["responseMetadata"] as? [String: Any])?["nextCursor"] as? String
        } while cursor != nil

        var nonGames = recheckKnown ? [] : nonGameAppNames
        records.removeAll { nonGames.contains($0.appName) }
        let toLookUp = records.filter { recheckKnown || !knownAppNames.contains($0.appName) }
        let results = await withTaskGroup(of: CatalogResult.self) { group in
            var results: [CatalogResult] = []
            var iterator = toLookUp.makeIterator()
            for _ in 0 ..< 8 {
                guard let record = iterator.next() else { break }
                group.addTask { await catalogGame(record, token: token) }
            }
            while let result = await group.next() {
                results.append(result)
                if let record = iterator.next() {
                    group.addTask { await catalogGame(record, token: token) }
                }
            }
            return results
        }

        var games: [StorefrontGame] = []
        for result in results {
            switch result {
            case .game(let game): games.append(game)
            case .notGame(let appName): nonGames.insert(appName)
            case .unavailable: break
            }
        }
        nonGameAppNames = nonGames
        UserDefaults.standard.set(gameFilterVersion, forKey: gameFilterVersionKey)
        let ownedAppNames = Set(records.map(\.appName)).subtracting(nonGames)
        return (games, ownedAppNames)
    }

    /// Catalog paths on items that are not playable games: DLC / add-ons, engines, and Unreal / Fab marketplace
    /// content (assets, plugins, projects, "asset-format/…", "type/format-item").
    private static let nonGameCategoryPrefixes = [
        "addons", "digitalextras", "engines", "assets", "asset-format", "plugins", "projects", "type/format-item",
    ]

    /// Title and tall box art, `.notGame` for DLC, add-ons, engine and marketplace content.
    private static func catalogGame(_ record: LibraryRecord, token: String) async -> CatalogResult {
        var components = URLComponents(
            string: "https://catalog-public-service-prod06.ol.epicgames.com/catalog/api/shared/namespace/\(record.namespace)/bulk/items"
        )!
        components.queryItems = [
            URLQueryItem(name: "id", value: record.catalogItemID),
            URLQueryItem(name: "includeDLCDetails", value: "true"),
            URLQueryItem(name: "includeMainGameDetails", value: "true"),
            URLQueryItem(name: "country", value: "US"),
            URLQueryItem(name: "locale", value: "en-US"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let root = try? await StorefrontHTTP.json(request, store: "Epic"),
              let item = root[record.catalogItemID] as? [String: Any],
              let title = item["title"] as? String else { return .unavailable }
        if item["mainGameItem"] != nil { return .notGame(appName: record.appName) }
        let categories = (item["categories"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        if categories.contains(where: { path in nonGameCategoryPrefixes.contains { path.hasPrefix($0) } }) {
            return .notGame(appName: record.appName)
        }
        let images = item["keyImages"] as? [[String: Any]] ?? []
        let cover = ["DieselGameBoxTall", "OfferImageTall", "DieselGameBox", "Thumbnail"].lazy
            .compactMap { type in images.first { $0["type"] as? String == type }?["url"] as? String }
            .first
            .flatMap(URL.init(string:))
        return .game(StorefrontGame(store: .epic, gameID: record.appName, title: title, installed: false, coverURL: cover))
    }

    // MARK: Installed

    private struct Manifest: Decodable {
        var displayName: String?
        var installLocation: String?
        var launchExecutable: String?
        var appName: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "DisplayName"
            case installLocation = "InstallLocation"
            case launchExecutable = "LaunchExecutable"
            case appName = "AppName"
        }
    }

    static func installedGames() -> [StorefrontGame] {
        let base = ("~/Library/Application Support/Epic/EpicGamesLauncher/Data/Manifests" as NSString).expandingTildeInPath
        let files = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        return files.filter { $0.lowercased().hasSuffix(".item") }.compactMap { file in
            guard let data = FileManager.default.contents(atPath: (base as NSString).appendingPathComponent(file)),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                  let appName = manifest.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty,
                  let launchPath = resolvedLaunchPath(from: manifest) else { return nil }
            let display = manifest.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = display.isEmpty ? URL(fileURLWithPath: launchPath).deletingPathExtension().lastPathComponent : display
            return StorefrontGame(store: .epic, gameID: appName, title: title, installed: true, installPath: launchPath)
        }
    }

    private static func resolvedLaunchPath(from manifest: Manifest) -> String? {
        let install = manifest.installLocation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !install.isEmpty else { return nil }
        let rawLaunch = manifest.launchExecutable?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rawLaunch.isEmpty {
            if rawLaunch.hasPrefix("/") {
                let absolute = (rawLaunch as NSString).standardizingPath
                if FileManager.default.fileExists(atPath: absolute) { return absolute }
            }
            let joined = ((install as NSString).appendingPathComponent(rawLaunch) as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: joined) { return joined }
        }
        let installPath = (install as NSString).standardizingPath
        if installPath.lowercased().hasSuffix(".app") { return installPath }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: installPath)) ?? []
        return items.first { $0.lowercased().hasSuffix(".app") }.map { (installPath as NSString).appendingPathComponent($0) }
    }
}

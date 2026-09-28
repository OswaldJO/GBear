import Foundation
import Observation

public enum RommStatus {
    public static let inROMM = "in_romm"
    public static let missing = "missing"
}

/// Connection details for the user's ROMM server. Password lives in the Keychain.
enum RommCredentials {
    private static let keychainService = "com.gbear.romm"

    static var serverURL: String? {
        get { UserDefaults.standard.string(forKey: "ROMM.ServerURL") }
        set { UserDefaults.standard.set(newValue, forKey: "ROMM.ServerURL") }
    }

    static var username: String? {
        get { UserDefaults.standard.string(forKey: "ROMM.Username") }
        set { UserDefaults.standard.set(newValue, forKey: "ROMM.Username") }
    }

    static var password: String? {
        get { KeychainStore.string(service: keychainService, account: "password") }
        set { KeychainStore.set(newValue, service: keychainService, account: "password") }
    }

    static var isConfigured: Bool {
        baseURL != nil && !(username ?? "").isEmpty && !(password ?? "").isEmpty
    }

    /// Server root without a trailing slash; `http://` is assumed when no scheme is typed.
    static var baseURL: URL? {
        guard var raw = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "http://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        return URL(string: raw)
    }

    static func signOut() {
        password = nil
    }
}

/// ROMM REST API (`/api/...`) with HTTP Basic auth.
enum RommClient {
    struct Platform: Sendable, Identifiable, Hashable {
        var id: Int
        var name: String
        var slug: String
        var romCount: Int
    }

    struct Rom: Sendable {
        var id: Int
        var name: String
        var fileName: String
        var fileNameNoTags: String
        var fullPath: String
        var coverURL: URL?
        var hasMultipleFiles: Bool
        var platformID: Int?
        var platformSlug: String
    }

    enum RommError: Error, LocalizedError {
        case notConfigured
        case unauthorized
        case http(Int)
        case decoding
        case unzipFailed
        case folderUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "ROMM server, username, or password is missing."
            case .unauthorized: return "ROMM rejected the username or password."
            case .http(let code): return "ROMM HTTP \(code)"
            case .decoding: return "ROMM response could not be read. Check the server address."
            case .unzipFailed: return "The ROMM download could not be unzipped."
            case .folderUnavailable(let path): return "The game folder \(path) is not available. Connect the drive or pick another folder in Paths."
            }
        }
    }

    static func serverVersion() async throws -> String? {
        let object = try await getJSON("/api/heartbeat")
        let system = (object as? [String: Any])?["SYSTEM"] as? [String: Any]
        return system?["VERSION"] as? String
    }

    static func platforms() async throws -> [Platform] {
        guard let list = try await getJSON("/api/platforms") as? [[String: Any]] else { throw RommError.decoding }
        return list.compactMap { item in
            guard let id = (item["id"] as? NSNumber)?.intValue else { return nil }
            let name = [item["custom_name"], item["display_name"], item["name"]]
                .compactMap { $0 as? String }
                .first { !$0.isEmpty } ?? "Platform \(id)"
            return Platform(
                id: id,
                name: name,
                slug: (item["fs_slug"] as? String) ?? (item["slug"] as? String) ?? "\(id)",
                romCount: (item["rom_count"] as? NSNumber)?.intValue ?? 0
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func roms(platformID: Int) async throws -> [Rom] {
        let pageSize = 1000
        var offset = 0
        var roms: [Rom] = []
        while true {
            // ROMM 4 filters on `platform_ids` and ignores `platform_id`; older servers only know `platform_id`.
            let path = "/api/roms?platform_ids=\(platformID)&platform_id=\(platformID)&limit=\(pageSize)&offset=\(offset)" +
                "&with_char_index=false&with_filter_values=false&with_rom_id_index=false"
            let object = try await getJSON(path)
            let items: [[String: Any]]
            var total: Int?
            if let page = object as? [String: Any] {
                items = page["items"] as? [[String: Any]] ?? []
                total = (page["total"] as? NSNumber)?.intValue
            } else if let list = object as? [[String: Any]] {
                items = list
                total = list.count
            } else {
                throw RommError.decoding
            }
            roms.append(contentsOf: items.compactMap(parseRom).filter { $0.platformID == nil || $0.platformID == platformID })
            offset += items.count
            if items.count < pageSize || (total.map { offset >= $0 } ?? false) || items.isEmpty { break }
        }
        return roms
    }

    private static func parseRom(_ item: [String: Any]) -> Rom? {
        guard let id = (item["id"] as? NSNumber)?.intValue,
              let fileName = item["fs_name"] as? String else { return nil }
        let noTags = (item["fs_name_no_tags"] as? String) ?? fileName
        let name = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? noTags
        var cover: URL?
        if let url = item["url_cover"] as? String, !url.isEmpty {
            cover = URL(string: url.hasPrefix("//") ? "https:" + url : url)
        } else if let path = item["path_cover_large"] as? String, !path.isEmpty, let base = RommCredentials.baseURL {
            cover = URL(string: base.absoluteString + (path.hasPrefix("/") ? path : "/assets/romm/resources/" + path))
        }
        let fullPath = (item["full_path"] as? String)
            ?? [item["fs_path"] as? String, fileName].compactMap { $0 }.joined(separator: "/")
        return Rom(
            id: id,
            name: name,
            fileName: fileName,
            fileNameNoTags: noTags,
            fullPath: fullPath,
            coverURL: cover,
            hasMultipleFiles: (item["has_multiple_files"] as? Bool) ?? (item["multi"] as? Bool) ?? false,
            platformID: (item["platform_id"] as? NSNumber)?.intValue,
            platformSlug: (item["platform_fs_slug"] as? String) ?? (item["platform_slug"] as? String) ?? "romm"
        )
    }

    /// Browser page for a rom in the ROMM web UI.
    static func webURL(romID: Int) -> URL? {
        RommCredentials.baseURL.map { $0.appendingPathComponent("rom").appendingPathComponent(String(romID)) }
    }

    /// Downloads a rom's content to a temporary file the caller must move or delete. Multi-file roms arrive as a zip.
    static func download(romID: Int, fileName: String) async throws -> URL {
        let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        var request = try authorizedRequest("/api/roms/\(romID)/content/\(encoded)")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        let (temp, response) = try await URLSession.shared.download(for: request)
        try check(response)
        let kept = FileManager.default.temporaryDirectory.appending(path: "gbear-romm-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: temp, to: kept)
        return kept
    }

    // MARK: HTTP

    private static func authorizedRequest(_ path: String) throws -> URLRequest {
        guard let base = RommCredentials.baseURL,
              let username = RommCredentials.username,
              let password = RommCredentials.password,
              let url = URL(string: base.absoluteString + path) else { throw RommError.notConfigured }
        var request = URLRequest(url: url)
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }

    private static func check(_ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if code == 401 || code == 403 { throw RommError.unauthorized }
        guard (200 ... 299).contains(code) else { throw RommError.http(code) }
    }

    private static func getJSON(_ path: String) async throws -> Any {
        let (data, response) = try await URLSession.shared.data(for: authorizedRequest(path))
        try check(response)
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw RommError.decoding }
        return object
    }
}

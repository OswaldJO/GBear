import Foundation

/// One game reported by a storefront, either found installed on disk or listed in the signed-in owned library.
struct StorefrontGame: Sendable {
    var store: Storefront
    /// Epic app name, Steam app id, or GOG product id.
    var gameID: String
    var title: String
    var installed: Bool
    /// App bundle, executable, or install folder when installed.
    var installPath: String?
    var coverURL: URL?
}

enum StorefrontError: Error, LocalizedError {
    case notSignedIn
    case http(String, Int)
    case decoding(String)
    case signInFailed(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in."
        case .http(let store, let code): return "\(store) HTTP \(code)"
        case .decoding(let store): return "\(store) response could not be read."
        case .signInFailed(let message): return message
        }
    }
}

enum StorefrontHTTP {
    static func json(_ request: URLRequest, store: String) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ... 299).contains(code) else { throw StorefrontError.http(store, code) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StorefrontError.decoding(store)
        }
        return object
    }

    static func formBody(_ fields: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)
    }
}

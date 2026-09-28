import Foundation

/// Storefront sign-in state. Tokens and the Steam Web API key live in the Keychain; display names in `UserDefaults`.
enum StorefrontCredentials {
    private static let service = "com.gbear.storefronts"

    // MARK: Steam

    static var steamID: String? {
        get { UserDefaults.standard.string(forKey: "Storefronts.Steam.SteamID") }
        set { UserDefaults.standard.set(newValue, forKey: "Storefronts.Steam.SteamID") }
    }

    static var steamAPIKey: String? {
        get { keychainString("steam.apiKey") }
        set { setKeychainString(newValue, for: "steam.apiKey") }
    }

    // MARK: Epic / GOG

    static func refreshToken(for store: Storefront) -> String? {
        keychainString("\(store.rawValue).refreshToken")
    }

    static func setRefreshToken(_ token: String?, for store: Storefront) {
        setKeychainString(token, for: "\(store.rawValue).refreshToken")
    }

    // MARK: Shared

    static func accountName(for store: Storefront) -> String? {
        UserDefaults.standard.string(forKey: "Storefronts.\(store.rawValue).AccountName")
    }

    static func setAccountName(_ name: String?, for store: Storefront) {
        UserDefaults.standard.set(name, forKey: "Storefronts.\(store.rawValue).AccountName")
    }

    /// Signed in far enough to list owned games.
    static func isSignedIn(_ store: Storefront) -> Bool {
        switch store {
        case .steam:
            return !(steamID ?? "").isEmpty && !(steamAPIKey ?? "").isEmpty
        case .epic, .gog:
            return !(refreshToken(for: store) ?? "").isEmpty
        }
    }

    static func signOut(_ store: Storefront) {
        switch store {
        case .steam:
            steamID = nil
        case .epic, .gog:
            setRefreshToken(nil, for: store)
        }
        setAccountName(nil, for: store)
    }

    // MARK: Keychain

    private static func keychainString(_ account: String) -> String? {
        KeychainStore.string(service: service, account: account)
    }

    private static func setKeychainString(_ value: String?, for account: String) {
        KeychainStore.set(value, service: service, account: account)
    }
}

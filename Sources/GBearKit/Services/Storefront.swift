import Foundation
import Observation

/// PC game storefronts GBear imports from. Raw values are stored in `LibraryGame.librarySourceID`.
public enum Storefront: String, CaseIterable, Identifiable, Sendable {
    case epic
    case steam
    case gog

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .epic: return "Epic Games"
        case .steam: return "Steam"
        case .gog: return "GOG"
        }
    }

    var systemImage: String {
        switch self {
        case .epic: return "shippingbox"
        case .steam: return "cloud"
        case .gog: return "opticaldisc"
        }
    }

    /// Stable identity for the blocked list, independent of install location.
    func blocklistIdentity(gameID: String) -> String {
        "storefront/\(rawValue)/\(gameID)"
    }
}

/// Operating systems a storefront game has builds for.
public enum GamePlatform: String, CaseIterable, Sendable {
    case mac
    case windows
    case linux

    public var displayName: String {
        switch self {
        case .mac: return "macOS"
        case .windows: return "Windows"
        case .linux: return "Linux"
        }
    }
}

/// Per-storefront toggles from the Storefront Manager sidebar. Backed by `UserDefaults`.
@Observable
@MainActor
final class StorefrontSettings {
    static let shared = StorefrontSettings()

    private(set) var enabled: Set<Storefront>
    private(set) var onlyInstalled: Set<Storefront>
    private(set) var onlyMac: Set<Storefront>

    private static let enabledKey = "Storefronts.Enabled"
    private static let onlyInstalledKey = "Storefronts.OnlyInstalled"
    private static let onlyMacKey = "Storefronts.OnlyMac"

    private init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.array(forKey: Self.enabledKey) as? [String] {
            enabled = Set(stored.compactMap(Storefront.init(rawValue:)))
        } else {
            enabled = [.epic]
        }
        let installedOnly = defaults.array(forKey: Self.onlyInstalledKey) as? [String] ?? []
        onlyInstalled = Set(installedOnly.compactMap(Storefront.init(rawValue:)))
        let macOnly = defaults.array(forKey: Self.onlyMacKey) as? [String] ?? []
        onlyMac = Set(macOnly.compactMap(Storefront.init(rawValue:)))
    }

    func isEnabled(_ store: Storefront) -> Bool { enabled.contains(store) }

    func setEnabled(_ store: Storefront, _ on: Bool) {
        if on { enabled.insert(store) } else { enabled.remove(store) }
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: Self.enabledKey)
    }

    func showsOnlyInstalled(_ store: Storefront) -> Bool { onlyInstalled.contains(store) }

    func setOnlyInstalled(_ store: Storefront, _ on: Bool) {
        if on { onlyInstalled.insert(store) } else { onlyInstalled.remove(store) }
        UserDefaults.standard.set(onlyInstalled.map(\.rawValue), forKey: Self.onlyInstalledKey)
    }

    func showsOnlyMac(_ store: Storefront) -> Bool { onlyMac.contains(store) }

    func setOnlyMac(_ store: Storefront, _ on: Bool) {
        if on { onlyMac.insert(store) } else { onlyMac.remove(store) }
        UserDefaults.standard.set(onlyMac.map(\.rawValue), forKey: Self.onlyMacKey)
    }

    /// Library grid filter: hides disabled storefronts and, when asked, games that are not installed
    /// or that have no Mac version (games whose systems are still unknown stay visible).
    func isVisible(_ game: LibraryGame) -> Bool {
        guard let store = game.storefront else { return true }
        guard isEnabled(store) else { return false }
        if showsOnlyInstalled(store), !game.isInstalledStorefrontGame { return false }
        if showsOnlyMac(store), !game.isInstalledStorefrontGame, let platforms = game.platforms, !platforms.contains(.mac) {
            return false
        }
        return true
    }
}

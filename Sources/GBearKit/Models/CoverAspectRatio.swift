import CoreGraphics
import Foundation

/// Library cover crop (width:height). Scraped art is not rewritten; tiles clip to this shape.
public enum CoverAspectRatio: String, CaseIterable, Identifiable, Sendable, Codable {
    case steamGrid = "2:3"
    case standardTV = "4:3"
    case square = "1:1"
    case classicBox = "3:4"
    case nintendoHandheld = "8:7"
    case widePortrait = "3:5"
    case banner = "16:9"

    public var id: String { rawValue }

    public var pickerLabel: String {
        switch self {
        case .steamGrid: return "2:3 (SteamGridDB)"
        case .standardTV: return "4:3 (SNES)"
        case .square: return "1:1 (GBA, PSX)"
        case .classicBox: return "3:4 (PS2, GC, WII, NES)"
        case .nintendoHandheld: return "8:7 (NDS, 3DS)"
        case .widePortrait: return "3:5 (PSP, SWITCH)"
        case .banner: return "16:9 (Screen / Banner)"
        }
    }

    /// Width ÷ height for SwiftUI `aspectRatio`.
    public var widthOverHeight: CGFloat {
        CGFloat(widthUnits) / CGFloat(heightUnits)
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        width * CGFloat(heightUnits) / CGFloat(widthUnits)
    }

    public func width(forHeight height: CGFloat) -> CGFloat {
        height * CGFloat(widthUnits) / CGFloat(heightUnits)
    }

    public static let `default`: CoverAspectRatio = .steamGrid

    public static func parse(_ raw: String?) -> CoverAspectRatio {
        guard let raw, let value = CoverAspectRatio(rawValue: raw) else { return .default }
        return value
    }

    /// Best-effort default when adding from the bundled catalog.
    public static func inferred(platforms: [String], name: String) -> CoverAspectRatio {
        let slugs = Set(platforms.map { $0.lowercased() })
        let nameLower = name.lowercased()
        func hasSlug(_ values: String...) -> Bool {
            values.contains { slugs.contains($0) }
        }
        func nameHas(_ values: String...) -> Bool {
            values.contains { nameLower.contains($0) }
        }

        if hasSlug("nintendo_3ds", "nintendo_ds", "nintendo_dsi", "nds", "3ds")
            || nameHas("3ds", "nintendo ds") {
            return .nintendoHandheld
        }
        if hasSlug("nintendo_switch", "sony_psp", "sony_vita", "psp", "psvita")
            || nameHas("switch", " psp", "vita") {
            return .widePortrait
        }
        if hasSlug("nintendo_gameboyadvance", "nintendo_gameboy", "nintendo_gameboycolor", "gba", "gb", "gbc")
            || nameHas("game boy", "gba", "gbc") {
            return .square
        }
        if hasSlug("sony_playstation")
            || (nameHas("psx", "ps1", "playstation") && !nameHas("ps2", "ps3", "ps4", "psp")) {
            return .square
        }
        if hasSlug("nintendo_super_nes", "snes", "sega_genesis", "sega_mastersystem", "sega_32x")
            || nameHas("snes", "super nintendo", "genesis", "mega drive") {
            return .standardTV
        }
        if hasSlug(
            "sony_playstation2", "sony_playstation3", "nintendo_gamecube", "nintendo_wii", "nintendo_wiiu",
            "nintendo_nes", "nintendo_64", "n64", "nes", "sega_saturn", "sega_dreamcast", "sega_cd"
        ) || nameHas("n64", "gamecube", "game cube", "wii", "dreamcast", "saturn", "ps2", "ps3") {
            return .classicBox
        }
        if hasSlug("pc_windows", "pc_dos") || nameHas("windows", "steam") {
            return .steamGrid
        }
        return .default
    }

    private var widthUnits: Int {
        switch self {
        case .steamGrid: return 2
        case .standardTV: return 4
        case .square: return 1
        case .classicBox: return 3
        case .nintendoHandheld: return 8
        case .widePortrait: return 3
        case .banner: return 16
        }
    }

    private var heightUnits: Int {
        switch self {
        case .steamGrid: return 3
        case .standardTV: return 3
        case .square: return 1
        case .classicBox: return 4
        case .nintendoHandheld: return 7
        case .widePortrait: return 5
        case .banner: return 9
        }
    }
}

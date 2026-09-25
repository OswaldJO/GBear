import Foundation

/// Maps GBear-style platform slugs (from `BuiltinEmulatorCatalog.json`) to ScreenScraper `systemeid` values.
enum ScreenScraperPlatformMap {
    private static let slugToSystemId: [String: Int] = [
        "3do": 29,
        "amstrad_cpc": 65,
        "apple_2": 86,
        "arcade": 75,
        "atari_2600": 26,
        "atari_5200": 40,
        "atari_7800": 41,
        "atari_8bit": 26,
        "atari_falcon030": 43,
        "atari_jaguar": 27,
        "atari_lynx": 28,
        "atari_st": 42,
        "bandai_wonderswan": 45,
        "bandai_wonderswan_color": 46,
        "coleco_vision": 48,
        "commodore_64": 66,
        "commodore_amiga": 64,
        "commodore_amiga_cd32": 130,
        "commodore_cbm2": 66,
        "commodore_cbm5x0": 66,
        "commodore_pet": 66,
        "commodore_plus4": 66,
        "commodore_vci20": 66,
        "fairchild_channelf": 80,
        "magnavox_odyssey_2": 104,
        "mattel_intellivision": 115,
        "megaduck": 90,
        "microsoft_msx": 113,
        "microsoft_msx2": 116,
        "nec_pc88": 117,
        "nec_pc98": 118,
        "nec_pcfx": 72,
        "nec_supergrafx": 105,
        "nec_turbografx_16": 31,
        "nec_turbografx_cd": 114,
        "nintendo_3ds": 17,
        "nintendo_64": 14,
        "nintendo_ds": 15,
        "nintendo_dsi": 15,
        "nintendo_famicom_disk": 106,
        "nintendo_gameandwatch": 52,
        "nintendo_gameboy": 9,
        "nintendo_gameboyadvance": 12,
        "nintendo_gameboycolor": 10,
        "nintendo_gamecube": 13,
        "nintendo_nes": 3,
        "nintendo_super_nes": 4,
        "nintendo_switch": 225,
        "nintendo_virtualboy": 11,
        "nintendo_wii": 16,
        "nintendo_wiiu": 18,
        "pc_dos": 135,
        "pc_windows": 135,
        "pokemon_mini": 211,
        "sega_32x": 19,
        "sega_cd": 20,
        "sega_dreamcast": 23,
        "sega_gamegear": 21,
        "sega_genesis": 1,
        "sega_mastersystem": 2,
        "sega_saturn": 22,
        "sega_sg1000": 109,
        "sharp_x68000": 79,
        "sinclair_zx81": 77,
        "sinclair_zxspectrum": 76,
        "sinclair_zxspectrum3": 76,
        "snk_neogeo_aes": 142,
        "snk_neogeo_cd": 70,
        "snk_neogeopocket": 25,
        "snk_neogeopocket_color": 82,
        "sony_playstation": 57,
        "sony_playstation2": 58,
        "sony_playstation3": 59,
        "sony_playstation4": 60,
        "sony_psp": 61,
        "sony_vita": 62,
        "thomson_mo5": 141,
        "thomson_to7": 141,
        "ti_83": 221,
        "uzebox": 216,
        "vectrex": 102,
        "watara_supervision": 207,
        "xbox": 32,
        "xbox360": 33,
    ]

    private static let systemIdToDisplayName: [Int: String] = [
        1: "Sega Mega Drive",
        2: "Sega Master System",
        3: "Nintendo NES",
        4: "Super Nintendo",
        9: "Game Boy",
        10: "Game Boy Color",
        11: "Virtual Boy",
        12: "Game Boy Advance",
        13: "Nintendo GameCube",
        14: "Nintendo 64",
        15: "Nintendo DS",
        16: "Nintendo Wii",
        17: "Nintendo 3DS",
        18: "Wii U",
        19: "Sega 32X",
        20: "Sega CD",
        21: "Sega Game Gear",
        22: "Sega Saturn",
        23: "Dreamcast",
        25: "Neo Geo Pocket",
        26: "Atari 2600",
        27: "Atari Jaguar",
        28: "Atari Lynx",
        29: "3DO",
        31: "PC Engine / TurboGrafx-16",
        32: "Xbox",
        33: "Xbox 360",
        40: "Atari 5200",
        41: "Atari 7800",
        42: "Atari ST",
        43: "Atari Falcon",
        45: "WonderSwan",
        46: "WonderSwan Color",
        48: "ColecoVision",
        57: "PlayStation",
        58: "PlayStation 2",
        59: "PlayStation 3",
        60: "PlayStation 4",
        61: "PSP",
        62: "PS Vita",
        64: "Amiga",
        65: "Amstrad CPC",
        66: "Commodore 64",
        70: "Neo Geo CD",
        72: "PC-FX",
        75: "Arcade",
        76: "ZX Spectrum",
        77: "ZX81",
        79: "Sharp X68000",
        80: "Fairchild Channel F",
        86: "Apple II",
        90: "Mega Duck",
        102: "Vectrex",
        104: "Magnavox Odyssey²",
        105: "PC Engine SuperGrafx",
        106: "Famicom Disk System",
        109: "Sega SG-1000",
        113: "MSX",
        114: "PC Engine CD",
        115: "Intellivision",
        130: "Amiga CD32",
        135: "PC",
        142: "Neo Geo",
        207: "Watara Supervision",
        211: "Pokémon Mini",
        216: "Uzebox",
        225: "Nintendo Switch",
    ]

    static func systemId(forGBearSlug slug: String) -> Int? {
        slugToSystemId[slug.lowercased()]
    }

    static func displayName(forSystemId systemId: Int) -> String {
        systemIdToDisplayName[systemId] ?? "System \(systemId)"
    }

    static func displayName(forGBearSlug slug: String) -> String {
        if let id = systemId(forGBearSlug: slug) {
            return displayName(forSystemId: id)
        }
        return slug.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Maps a stored platform hint (from scan) to a ScreenScraper system id.
    static func systemId(forPlatformHint hint: String) -> Int? {
        let normalized = hint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        for (id, name) in systemIdToDisplayName where name.lowercased() == normalized {
            return id
        }

        let aliases: [String: Int] = [
            "ps1": 57, "psx": 57, "playstation 1": 57, "playstation": 57,
            "ps2": 58, "playstation 2": 58,
            "ps3": 59, "playstation 3": 59,
            "psp": 61, "ps vita": 62, "vita": 62,
            "switch": 225, "nintendo switch": 225,
            "wii u": 18, "wii": 16, "gamecube": 13, "n64": 14,
            "gba": 12, "gbc": 10, "gb": 9, "nds": 15,
            "dreamcast": 23, "saturn": 22, "genesis": 1, "mega drive": 1,
            "xbox 360": 33, "xbox": 32,
            "pc": 135, "windows": 135, "mac": 135,
        ]
        if let id = aliases[normalized] { return id }
        for (needle, id) in aliases where normalized.contains(needle) {
            return id
        }
        return nil
    }

    /// Sorted ScreenScraper consoles for platform pickers (manual search, filters).
    static var selectableSystems: [(id: Int, name: String)] {
        systemIdToDisplayName
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

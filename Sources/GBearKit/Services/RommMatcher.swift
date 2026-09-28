import Foundation

/// Matches local library games to ROMM roms. ROMM names are usually clean (IGDB titles, or the file name for
/// unidentified roms); local names are dump file names with tags, scene junk, and disc numbers.
///
/// Tiers, first hit wins: exact file name → normalized title → ROMM title contained in the local name
/// (only when a single ROMM game fits and the extra local words carry no sequel number).
/// Disc numbers never cross: Disc 2 matches ROMM's Disc 2, or a disc-less ROMM game that holds every disc.
struct RommMatcher {
    private struct Entry {
        let rom: RommClient.Rom
        let disc: Int?
        let keys: [String]
    }

    private let entries: [Entry]
    private var byExact: [String: [Int]] = [:]
    private var byKey: [String: [Int]] = [:]

    init(roms: [RommClient.Rom]) {
        entries = roms.map { rom in
            let keys = [rom.name, rom.fileNameNoTags, rom.fileName].map(Self.titleKey).filter { !$0.isEmpty }
            return Entry(
                rom: rom,
                disc: Self.discNumber(rom.fileName) ?? Self.discNumber(rom.name),
                keys: Array(NSOrderedSet(array: keys)) as? [String] ?? keys
            )
        }
        for (index, entry) in entries.enumerated() {
            byExact[Self.exactKey(entry.rom.fileName), default: []].append(index)
            for key in entry.keys {
                byKey[key, default: []].append(index)
            }
        }
    }

    /// ROMM roms for one local game: usually one; a disc-less local game matches every disc of a split ROMM set.
    func match(fileName: String, titles: [String]) -> [RommClient.Rom] {
        let disc = Self.discNumber(fileName) ?? titles.lazy.compactMap(Self.discNumber).first

        if let hits = byExact[Self.exactKey(fileName)] {
            let picked = pick(hits, disc: disc)
            if !picked.isEmpty { return picked }
        }

        var localKeys: [String] = []
        for key in ([fileName] + titles).map(Self.titleKey) where !key.isEmpty && !localKeys.contains(key) {
            localKeys.append(key)
        }
        for key in localKeys {
            guard let hits = byKey[key] else { continue }
            let picked = pick(hits, disc: disc)
            if !picked.isEmpty { return picked }
        }

        for key in localKeys {
            let local = Self.tokens(key)
            var hits: [Int] = []
            var games = Set<String>()
            var extra = Set<String>()
            for (index, entry) in entries.enumerated() {
                for romKey in entry.keys {
                    let rom = Self.tokens(romKey)
                    guard rom.count >= 2, rom.count < local.count, rom.isSubset(of: local) else { continue }
                    let leftover = local.subtracting(rom)
                    guard !leftover.contains(where: Self.isNumberToken) else { continue }
                    hits.append(index)
                    games.insert(entry.keys.first ?? romKey)
                    extra = leftover
                    break
                }
            }
            guard games.count == 1, let game = games.first else { continue }
            // Extra words that are another ROMM game's subtitle mean the local file is that game, not this one.
            let extraBelongsElsewhere = entries.contains { other in
                other.keys.first != game && other.keys.contains { extra.isSubset(of: Self.tokens($0)) }
            }
            if extraBelongsElsewhere { continue }
            let picked = pick(hits, disc: disc)
            if !picked.isEmpty { return picked }
        }
        return []
    }

    private func pick(_ indexes: [Int], disc: Int?) -> [RommClient.Rom] {
        var seen = Set<Int>()
        let candidates = indexes.filter { seen.insert($0).inserted }.map { entries[$0] }
        let whole = candidates.filter { $0.disc == nil }
        if let disc {
            if let same = candidates.first(where: { $0.disc == disc }) { return [same.rom] }
            return whole.first.map { [$0.rom] } ?? []
        }
        if let first = whole.first { return [first.rom] }
        return candidates.sorted { ($0.disc ?? 0) < ($1.disc ?? 0) }.map(\.rom)
    }

    // MARK: Keys

    /// Drops a real file extension (`.chd`, `.nsp`) but not title punctuation (`Dr. Mario`, `Vol.2`).
    static func strippingExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 5,
              ext.allSatisfy({ $0.isLetter || $0.isNumber }),
              ext.contains(where: \.isLetter) else { return name }
        return (name as NSString).deletingPathExtension
    }

    static func exactKey(_ fileName: String) -> String {
        strippingExtension(fileName).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func discNumber(_ text: String) -> Int? {
        guard let range = text.range(of: #"(?i)\b(?:disc|disk|cd)\s*0*([1-9][0-9]?)\b"#, options: .regularExpression) else {
            return nil
        }
        return Int(text[range].filter(\.isNumber))
    }

    /// Order-insensitive word key: dump tags, scene junk, and disc labels removed; accents folded; roman numerals as digits.
    static func titleKey(_ raw: String) -> String {
        var text = RomTitleNormalizer.searchQuery(fromFileNameStem: strippingExtension(raw))
        text = text.replacingOccurrences(of: #"(?i)\b(?:disc|disk|cd)\s*\d+\b"#, with: " ", options: .regularExpression)
        text = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        text = text.replacingOccurrences(of: "&", with: " and ")
        let words = text
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !fillerWords.contains($0) }
            .map { romanNumerals[$0] ?? $0 }
        return words.sorted().joined(separator: " ")
    }

    private static let romanNumerals = [
        "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "vii": "7", "viii": "8", "ix": "9", "x": "10",
        "xi": "11", "xii": "12", "xiii": "13",
    ]
    private static let fillerWords: Set<String> = ["the", "a", "an", "and", "of"]

    private static func tokens(_ key: String) -> Set<String> {
        Set(key.split(separator: " ").map(String.init))
    }

    /// Sequel numbers block a containment match (`Crash Bandicoot 2` must not match `Crash Bandicoot`); version tags don't.
    private static func isNumberToken(_ token: String) -> Bool {
        if token.range(of: #"^v\d+$"#, options: .regularExpression) != nil { return false }
        return token.contains(where: \.isNumber)
    }
}

import Foundation
import SwiftData

/// Links multi-disc library entries so cover art and ScreenScraper metadata stay in sync.
enum DiscGroupService {
    static func discGroupUUID(for game: LibraryGame) -> UUID? {
        guard let raw = game.discGroupIDString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let uuid = UUID(uuidString: raw) else { return nil }
        return uuid
    }

    static func linkedGames(for game: LibraryGame, context: ModelContext) -> [LibraryGame] {
        guard let groupID = game.discGroupIDString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupID.isEmpty else { return [] }
        return sortedDiscs(fetchGames(inGroupID: groupID, context: context))
    }

    /// Library grid ordering: grouped discs stay together and sort by `discGroupOrder`.
    static func librarySort(lhs: LibraryGame, rhs: LibraryGame) -> Bool {
        if let leftGroup = normalizedGroupID(lhs.discGroupIDString),
           let rightGroup = normalizedGroupID(rhs.discGroupIDString),
           leftGroup == rightGroup {
            return discOrderValue(for: lhs) < discOrderValue(for: rhs)
        }

        let titleCmp = sortTitle(for: lhs).localizedStandardCompare(sortTitle(for: rhs))
        if titleCmp != .orderedSame {
            return titleCmp == .orderedAscending
        }

        if normalizedGroupID(lhs.discGroupIDString) != nil || normalizedGroupID(rhs.discGroupIDString) != nil {
            return discOrderValue(for: lhs) < discOrderValue(for: rhs)
        }

        if lhs.sortOrder != rhs.sortOrder {
            return lhs.sortOrder < rhs.sortOrder
        }
        return lhs.dateAdded < rhs.dateAdded
    }

    /// Uppercase Roman numerals 1–39 standing alone after the first word (`Clock Tower II`, `Final Fantasy VII: …`).
    /// A lone `I` counts only before the end or punctuation, so `… I Am …` stays a word.
    private static let romanNumeral = try! NSRegularExpression(
        pattern: #"(?<=[\s:\-–—])(X{0,3}(?:IX|IV|V?I{0,3}))(?=$|[\s:\-–—,.!?)\]])"#
    )

    static func sortTitle(for game: LibraryGame) -> String {
        game.ignoresRomanNumeralsInSort == true ? game.libraryListTitle : sortTitle(game.libraryListTitle)
    }

    /// Title used only for ordering: Roman numerals become digits so `II` sorts between `1` and `3`.
    static func sortTitle(_ title: String) -> String {
        let ns = title as NSString
        var result = title
        for match in romanNumeral.matches(in: title, range: NSRange(location: 0, length: ns.length)).reversed() {
            let numeral = ns.substring(with: match.range(at: 1))
            guard !numeral.isEmpty, let value = romanValue(numeral) else { continue }
            if numeral == "I" {
                let after = match.range.location + match.range.length
                if after < ns.length, ns.substring(with: NSRange(location: after, length: 1)) == " " { continue }
            }
            result = (result as NSString).replacingCharacters(in: match.range(at: 1), with: String(value))
        }
        return result
    }

    private static func romanValue(_ numeral: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10]
        var total = 0
        var previous = 0
        for character in numeral.reversed() {
            guard let value = values[character] else { return nil }
            total += value < previous ? -value : value
            previous = max(previous, value)
        }
        return total > 0 ? total : nil
    }

    static func moveDisc(in groupID: String, from index: Int, direction: Int, context: ModelContext) {
        var discs = sortedDiscs(fetchGames(inGroupID: groupID, context: context))
        let target = index + direction
        guard discs.indices.contains(index), discs.indices.contains(target) else { return }
        discs.swapAt(index, target)
        applyDiscOrder(discs, context: context)
    }

    /// Re-derives order from `(Disc N)` tags in filenames, then updates library positions.
    static func normalizeDiscOrderFromFilenames(_ games: [LibraryGame], context: ModelContext) {
        let ordered = games.sorted {
            let left = discNumber(in: $0.romPath) ?? discNumber(in: $0.title) ?? Int.max
            let right = discNumber(in: $1.romPath) ?? discNumber(in: $1.title) ?? Int.max
            if left != right { return left < right }
            return $0.libraryListTitle.localizedCaseInsensitiveCompare($1.libraryListTitle) == .orderedAscending
        }
        for game in ordered {
            game.discGroupOrder = nil
        }
        applyDiscOrder(ordered, context: context)
    }

    static func moveDisc(in groupID: String, from sourceIndex: Int, to destinationIndex: Int, context: ModelContext) {
        var discs = sortedDiscs(fetchGames(inGroupID: groupID, context: context))
        guard discs.indices.contains(sourceIndex),
              destinationIndex >= 0,
              destinationIndex < discs.count,
              sourceIndex != destinationIndex else { return }
        let item = discs.remove(at: sourceIndex)
        discs.insert(item, at: destinationIndex)
        applyDiscOrder(discs, context: context)
    }

    /// Auto-links multi-disc clusters for emulators with `autoLinkMultiDiscGames` enabled. Returns sets linked.
    @discardableResult
    static func autoLinkMultiDiscGames(for emulator: EmulatorProfile, context: ModelContext) -> Int {
        guard emulator.autoLinkMultiDiscGames else { return 0 }

        let games = ((try? context.fetch(FetchDescriptor<LibraryGame>())) ?? [])
            .filter { $0.emulatorUUID == emulator.id }
        guard games.count >= 2 else { return 0 }

        var clusters: [String: [LibraryGame]] = [:]
        for game in games {
            let base = discBaseTitle(for: game)
            guard !base.isEmpty else { continue }
            clusters[base, default: []].append(game)
        }

        var linkedSetCount = 0
        for cluster in clusters.values where cluster.count >= 2 {
            if autoLinkCluster(cluster, context: context) {
                linkedSetCount += 1
            }
        }
        return linkedSetCount
    }

    @discardableResult
    static func autoLinkAllEnabledEmulators(context: ModelContext) -> Int {
        let emulators = (try? context.fetch(FetchDescriptor<EmulatorProfile>())) ?? []
        return emulators.reduce(0) { partial, emulator in
            partial + autoLinkMultiDiscGames(for: emulator, context: context)
        }
    }

    static func suggestedLinkCandidates(for game: LibraryGame, among games: [LibraryGame]) -> [LibraryGame] {
        let base = discBaseTitle(for: game)
        guard !base.isEmpty else { return [] }
        return games.filter { candidate in
            guard candidate.id != game.id else { return false }
            return discBaseTitle(for: candidate) == base
        }
    }

    /// Every disc set the Info column would suggest linking, matched within one emulator, that isn't already one
    /// group. Sets whose discs already sit in two different groups are left alone, like `autoLinkMultiDiscGames`.
    static func suggestedDiscSets(in games: [LibraryGame]) -> [[LibraryGame]] {
        var clusters: [String: [LibraryGame]] = [:]
        for game in games {
            let base = discBaseTitle(for: game)
            guard !base.isEmpty else { continue }
            clusters["\(game.emulatorUUID?.uuidString ?? "mac")|\(base)", default: []].append(game)
        }
        return clusters.values.filter { cluster in
            guard cluster.count >= 2 else { return false }
            let groupIDs = Set(cluster.compactMap { normalizedGroupID($0.discGroupIDString) })
            guard groupIDs.count <= 1 else { return false }
            if let only = groupIDs.first, cluster.allSatisfy({ normalizedGroupID($0.discGroupIDString) == only }) {
                return false
            }
            return true
        }
    }

    /// Short label for UI badges, e.g. "Disc 2".
    static func discLabel(for game: LibraryGame) -> String? {
        if let number = discNumber(in: game.romPath) ?? discNumber(in: game.title) ?? discNumber(in: game.libraryDisplayName ?? "") {
            return "Disc \(number)"
        }
        return nil
    }

    static func link(_ games: [LibraryGame], context: ModelContext) {
        let unique = Dictionary(grouping: games, by: \.id).compactMap(\.value.first)
        guard unique.count >= 2 else { return }

        let existingGroupIDs = Set(
            unique.compactMap(\.discGroupIDString)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let groupID = existingGroupIDs.count == 1 ? existingGroupIDs.first! : UUID().uuidString

        let canonical = unique.first { !($0.coverImageURLString?.isEmpty ?? true) }
            ?? unique.first { $0.screenScraperGameId != nil }
            ?? unique[0]

        for game in unique {
            game.discGroupIDString = groupID
            copySharedState(from: canonical, to: game)
        }
        applyDiscOrder(sortedDiscs(unique), context: context)
    }

    static func unlink(_ game: LibraryGame, context: ModelContext) {
        guard let groupID = game.discGroupIDString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupID.isEmpty else { return }

        game.discGroupIDString = nil
        game.discGroupOrder = nil

        let remaining = fetchGames(inGroupID: groupID, context: context).filter { $0.id != game.id }
        if remaining.count == 1 {
            remaining[0].discGroupIDString = nil
            remaining[0].discGroupOrder = nil
        } else if !remaining.isEmpty {
            applyDiscOrder(sortedDiscs(remaining), context: context)
        }
        try? context.save()
    }

    /// Copies cover art and ScreenScraper pins from `source` to every other disc in the group.
    static func propagateSharedState(from source: LibraryGame, context: ModelContext) {
        guard let groupID = source.discGroupIDString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupID.isEmpty else { return }

        let siblings = fetchGames(inGroupID: groupID, context: context).filter { $0.id != source.id }
        guard !siblings.isEmpty else { return }

        for sibling in siblings {
            copySharedState(from: source, to: sibling)
        }
        try? context.save()
    }

    // MARK: - Private

    private static func copySharedState(from source: LibraryGame, to target: LibraryGame) {
        target.coverImageURLString = source.coverImageURLString
        target.coverImageOptionsJSON = source.coverImageOptionsJSON
        target.screenScraperGameId = source.screenScraperGameId
        target.screenScraperSystemId = source.screenScraperSystemId
        target.remoteCoverSource = source.remoteCoverSource
        target.theGamesDBCheckedAt = source.theGamesDBCheckedAt
        target.igdbCheckedAt = source.igdbCheckedAt
    }

    private static func fetchGames(inGroupID groupID: String, context: ModelContext) -> [LibraryGame] {
        let id = groupID
        let descriptor = FetchDescriptor<LibraryGame>(predicate: #Predicate { $0.discGroupIDString == id })
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func autoLinkCluster(_ games: [LibraryGame], context: ModelContext) -> Bool {
        guard games.count >= 2 else { return false }

        let groupIDs = Set(games.compactMap { normalizedGroupID($0.discGroupIDString) })
        if groupIDs.count > 1 { return false }

        if let existingGroup = groupIDs.first {
            let fullyLinked = games.allSatisfy { normalizedGroupID($0.discGroupIDString) == existingGroup }
            if fullyLinked { return false }
        }

        link(games, context: context)
        return true
    }

    private static func sortedDiscs(_ games: [LibraryGame]) -> [LibraryGame] {
        games.sorted { discOrderValue(for: $0) < discOrderValue(for: $1) }
    }

    private static func applyDiscOrder(_ games: [LibraryGame], context: ModelContext) {
        guard !games.isEmpty else { return }
        let baseSort = games.map(\.sortOrder).min() ?? 0
        for (index, game) in games.enumerated() {
            game.discGroupOrder = index
            game.sortOrder = baseSort + index
        }
        try? context.save()
    }

    private static func discOrderValue(for game: LibraryGame) -> Int {
        if let manual = game.discGroupOrder { return manual }
        if let parsed = discNumber(in: game.romPath)
            ?? discNumber(in: game.title)
            ?? discNumber(in: game.libraryDisplayName ?? "") {
            return parsed - 1
        }
        return game.sortOrder
    }

    private static func normalizedGroupID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func discBaseTitle(for game: LibraryGame) -> String {
        let candidates = [
            game.libraryDisplayName,
            game.title,
            URL(fileURLWithPath: game.romPath).deletingPathExtension().lastPathComponent,
        ]
        for raw in candidates {
            let normalized = normalizeDiscTitle(raw ?? "")
            if !normalized.isEmpty { return normalized }
        }
        return ""
    }

    private static func normalizeDiscTitle(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        let patterns = [
            #"\((?:disc|disk|cd|dvd)\s*\d+[^)]*\)"#,
            #"\[(?:disc|disk|cd|dvd)\s*\d+[^\]]*\]"#,
            #"(?:disc|disk|cd|dvd)\s*\d+\s*(?:of\s*\d+)?"#,
            #"\(track\s*\d+[^)]*\)"#,
            #"\(usa\)"#, #"\(eur\)"#, #"\(jpn\)"#,
        ]
        for pattern in patterns {
            while let range = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                s.removeSubrange(range)
            }
        }

        return s
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func discNumber(in text: String) -> Int? {
        let patterns = [
            #"(?i)(?:disc|disk|cd|dvd)\s*(\d+)"#,
            #"(?i)\((?:disc|disk|cd|dvd)\s*(\d+)[^)]*\)"#,
            #"(?i)\[(?:disc|disk|cd|dvd)\s*(\d+)[^\]]*\]"#,
        ]
        let nsRange = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, options: [], range: nsRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text),
                  let value = Int(text[range]) else { continue }
            return value
        }
        return nil
    }
}

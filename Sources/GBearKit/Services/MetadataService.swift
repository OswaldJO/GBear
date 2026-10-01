import Foundation

enum ScreenScraperMatchMethod: String, Sendable {
    case pinned
    case hash
    case exactFilename
    case search
    case autoAmbiguousSearch
}

struct MetadataResult: Sendable {
    var normalizedTitle: String
    var coverImageURL: URL?
    var screenScraperGameId: Int?
    var screenScraperSystemId: Int?
    var matchMethod: ScreenScraperMatchMethod = .search
    /// True when the match was chosen algorithmically from an otherwise ambiguous result set.
    var autoResolvedAmbiguity: Bool = false
}

struct ScreenScraperDisambiguationRequest: Sendable, Identifiable, Hashable {
    let id: UUID
    let libraryGameId: UUID
    let libraryTitle: String
    let searchQuery: String
    let candidates: [ScreenScraperGameMatch]

    init(libraryGameId: UUID, libraryTitle: String, searchQuery: String, candidates: [ScreenScraperGameMatch]) {
        self.id = libraryGameId
        self.libraryGameId = libraryGameId
        self.libraryTitle = libraryTitle
        self.searchQuery = searchQuery
        self.candidates = candidates
    }
}

enum MetadataFetchOutcome: Sendable {
    case resolved(MetadataResult)
    case needsDisambiguation(ScreenScraperDisambiguationRequest)
    case unavailable
}

/// Fetches game metadata and cover art.
enum MetadataService {
    /// Returns normalized title and optional cover URL, or `nil` if credentials are not configured.
    static func fetchMetadata(
        libraryGameId: UUID,
        displayTitle: String,
        romFileNameStem: String,
        romPath: String,
        emulatorSystemId: Int?,
        pinnedGameId: Int?,
        pinnedSystemId: Int?,
        selectionSkipped: Bool = false
    ) async throws -> MetadataFetchOutcome? {
        guard MetadataCredentials.isConfigured else { return nil }
        if selectionSkipped { return .unavailable }

        let query = searchQuery(displayTitle: displayTitle, romFileNameStem: romFileNameStem)
        let coverRegion = RomTitleNormalizer.regionCode(fromFileNameStem: romFileNameStem)
            ?? RomTitleNormalizer.regionCode(fromFileNameStem: displayTitle)

        if let pinnedGameId, let pinnedSystemId {
            let match = try await ScreenScraperClient.fetchGame(
                gameId: pinnedGameId,
                systemId: pinnedSystemId,
                fallbackTitle: displayTitle,
                coverRegion: coverRegion
            )
            return .resolved(metadataResult(from: match, method: .pinned))
        }

        if let emulatorSystemId, let fingerprint = await RomFingerprint.build(forRomPath: romPath) {
            let hasChecksums = fingerprint.md5Hash != nil || fingerprint.crc32Hash != nil || fingerprint.sha1Hash != nil
            if hasChecksums {
                for hashCandidate in fingerprint.hashLookupCandidates {
                    if let hashMatch = try? await ScreenScraperClient.lookupByRom(
                        fingerprint: hashCandidate,
                        systemId: emulatorSystemId,
                        coverRegion: coverRegion
                    ) {
                        return .resolved(metadataResult(from: hashMatch, method: .hash))
                    }
                }
            }

            for exactCandidate in fingerprint.exactFilenameCandidates {
                if let exactMatch = try? await ScreenScraperClient.lookupByRom(
                    fingerprint: exactCandidate,
                    systemId: emulatorSystemId,
                    coverRegion: coverRegion
                ) {
                    return .resolved(metadataResult(from: exactMatch, method: .exactFilename))
                }
            }
        }

        let candidates = await searchCandidates(
            queries: searchQueryVariants(displayTitle: displayTitle, romFileNameStem: romFileNameStem),
            canonicalSearchQuery: query,
            emulatorSystemId: emulatorSystemId,
            coverRegion: coverRegion
        )

        guard !candidates.isEmpty else { return .unavailable }

        let deduped = deduplicatedCandidates(candidates)
        let compatible = compatibleCandidates(searchQuery: query, in: deduped)
        if let auto = autoSelectedMatch(from: compatible, emulatorSystemId: emulatorSystemId, searchQuery: query) {
            let enriched = try await ScreenScraperClient.fetchGame(
                gameId: auto.gameId,
                systemId: auto.systemId,
                fallbackTitle: auto.title,
                coverRegion: coverRegion
            )
            return .resolved(metadataResult(from: enriched, method: .search))
        }

        let promptCandidates: [ScreenScraperGameMatch]
        if let emulatorSystemId {
            let onEmulator = compatible.filter { $0.systemId == emulatorSystemId }
            promptCandidates = onEmulator.isEmpty ? compatible : onEmulator
        } else {
            promptCandidates = compatible
        }

        guard !promptCandidates.isEmpty else { return .unavailable }

        if MetadataCredentials.screenScraperAutoSelectAmbiguousMatches,
           let pick = algorithmicPick(from: promptCandidates, emulatorSystemId: emulatorSystemId, searchQuery: query) {
            let enriched = try await ScreenScraperClient.fetchGame(
                gameId: pick.gameId,
                systemId: pick.systemId,
                fallbackTitle: pick.title,
                coverRegion: coverRegion
            )
            var result = metadataResult(from: enriched, method: .autoAmbiguousSearch)
            result.autoResolvedAmbiguity = true
            return .resolved(result)
        }

        let prompt = ScreenScraperDisambiguationRequest(
            libraryGameId: libraryGameId,
            libraryTitle: displayTitle,
            searchQuery: query,
            candidates: promptCandidates
        )
        return .needsDisambiguation(prompt)
    }

    static func searchQuery(displayTitle: String, romFileNameStem: String) -> String {
        let fromRom = RomTitleNormalizer.searchQuery(fromFileNameStem: romFileNameStem)
        let fromDisplay = RomTitleNormalizer.searchQuery(fromFileNameStem: displayTitle)
        let candidates = [fromDisplay, fromRom].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let clean = candidates.filter { !RomTitleNormalizer.looksLikeDumpName($0) }
        let pool = clean.isEmpty ? candidates : clean
        return pool.max(by: { $0.count < $1.count }) ?? displayTitle
    }

    /// Whether a scraped title should replace the library filename title.
    static func shouldApplyScrapedTitle(
        searchQuery: String,
        pickedTitle: String,
        matchMethod: ScreenScraperMatchMethod
    ) -> Bool {
        switch matchMethod {
        case .pinned, .hash, .exactFilename:
            return true
        case .search, .autoAmbiguousSearch:
            return pickTitleIsCompatible(searchQuery: searchQuery, pickTitle: pickedTitle)
        }
    }

    static func pickTitleIsCompatible(searchQuery: String, pickTitle: String) -> Bool {
        let query = searchQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let pick = pickTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !pick.isEmpty else { return false }

        let queryDistinct = distinguishingTokens(from: query)
        let pickDistinct = distinguishingTokens(from: pick)
        let requiredDistinct = queryDistinct.subtracting(optionalPartVolumeTokens(in: query))
        if !requiredDistinct.isSubset(of: pickDistinct), !subtitleAnchorMatches(query: query, pick: pick) {
            return false
        }

        let queryWords = wordTokens(from: query)
        let pickWords = wordTokens(from: pick)
        let extraPickWords = pickWords.subtracting(queryWords)
        if queryWords.count <= 2, !extraPickWords.isEmpty, requiredDistinct.isEmpty, !subtitleAnchorMatches(query: query, pick: pick) {
            return false
        }

        return true
    }

    /// Stricter check for name-search backups (TheGamesDB, IGDB), whose search returns loosely related games.
    /// The shorter title's words must all appear in the longer one, and a one-word title must match exactly.
    /// `Off the Game` ✗ `Olympic Games Tokyo 2020`; `Hollow Knight Voidheart Edition` ✓ `Hollow Knight`.
    /// `SP(LR)ITE` ✓ `Sp(L/R)ite スプライト`: in-word punctuation is joined, and a Japanese / other non-Latin subtitle
    /// is ignored when the query is written in Latin letters.
    static func backupTitleMatches(searchQuery rawQuery: String, candidate rawCandidate: String) -> Bool {
        let searchQuery = RomTitleNormalizer.joiningInWordPunctuation(rawQuery)
        var candidate = RomTitleNormalizer.joiningInWordPunctuation(rawCandidate)
        if !containsNonLatinWord(searchQuery) {
            candidate = droppingNonLatinWords(candidate)
        }
        guard pickTitleIsCompatible(searchQuery: searchQuery, pickTitle: candidate) else { return false }
        let queryWords = significantWords(from: searchQuery)
        let candidateWords = significantWords(from: candidate)
        guard !queryWords.isEmpty, !candidateWords.isEmpty else { return false }
        let (shorter, longer) = queryWords.count <= candidateWords.count
            ? (queryWords, candidateWords)
            : (candidateWords, queryWords)
        guard shorter.isSubset(of: longer) else { return false }
        return shorter.count >= 2 || shorter == longer
    }

    private static let backupStopWords: Set<String> = ["the", "of", "a", "an", "and"]

    private static func isNonLatinWord(_ word: Substring) -> Bool {
        guard word.contains(where: \.isLetter) else { return false }
        let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return !folded.unicodeScalars.contains { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    private static func containsNonLatinWord(_ text: String) -> Bool {
        text.split(whereSeparator: \.isWhitespace).contains(where: isNonLatinWord)
    }

    private static func droppingNonLatinWords(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .filter { !isNonLatinWord($0) }
            .joined(separator: " ")
    }

    private static func significantWords(from text: String) -> Set<String> {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
        var words = Set<String>()
        for raw in folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(raw).lowercased()
            if let number = RomTitleNormalizer.canonicalDistinguishingToken(word) {
                words.insert(number)
            } else if word.count >= 2, !backupStopWords.contains(word) {
                words.insert(word)
            }
        }
        return words
    }

    /// Part/Vol numbers in ROM filenames (e.g. "Part 1") are often absent from ScreenScraper titles (e.g. ".hack//Infection").
    private static func optionalPartVolumeTokens(in query: String) -> Set<String> {
        var optional = Set<String>()
        let patterns = [#"(?i)part\s+(\d+)"#, #"(?i)vol\.?\s*(\d+)"#]
        let nsRange = NSRange(query.startIndex..., in: query)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: query, options: [], range: nsRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: query) else { continue }
            optional.insert(String(query[range]))
        }
        return optional
    }

    /// Matches franchise subtitles after `:` or G.U. volume suffixes (Reminisce, Infection, etc.).
    private static func subtitleAnchorMatches(query: String, pick: String) -> Bool {
        for anchor in subtitleAnchors(from: query) where pick.contains(anchor) {
            return true
        }
        return false
    }

    private static func subtitleAnchors(from query: String) -> [String] {
        var anchors: [String] = []
        func add(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard trimmed.count >= 4, !anchors.contains(trimmed) else { return }
            anchors.append(trimmed)
        }

        if let colon = query.lastIndex(of: ":") {
            add(String(query[query.index(after: colon)...]))
        }
        let nsRange = NSRange(query.startIndex..., in: query)
        if let regex = try? NSRegularExpression(pattern: #"(?i)vol\.?\s*\d+\s*[-:]\s*(.+)$"#, options: []),
           let match = regex.firstMatch(in: query, options: [], range: nsRange),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: query) {
            add(String(query[range]))
        }
        return anchors
    }

    static func searchQueryVariants(displayTitle: String, romFileNameStem: String) -> [String] {
        let fromRom = RomTitleNormalizer.searchQuery(fromFileNameStem: romFileNameStem)
        let fromDisplay = RomTitleNormalizer.searchQuery(fromFileNameStem: displayTitle)
        var variants: [String] = []

        func append(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !variants.contains(trimmed) else { return }
            variants.append(trimmed)
        }

        append(fromRom)
        append(fromDisplay)
        append(searchQuery(displayTitle: displayTitle, romFileNameStem: romFileNameStem))
        append(RomTitleNormalizer.withArabicNumerals(fromRom))
        append(RomTitleNormalizer.withArabicNumerals(fromDisplay))
        for base in [fromRom, fromDisplay] {
            for alt in RomTitleNormalizer.screenscraperTitleVariants(for: base) {
                append(alt)
                append(RomTitleNormalizer.withArabicNumerals(alt))
            }
        }
        return variants
    }

    private static func searchCandidates(
        queries: [String],
        canonicalSearchQuery: String,
        emulatorSystemId: Int?,
        coverRegion: String?
    ) async -> [ScreenScraperGameMatch] {
        var collected: [ScreenScraperGameMatch] = []

        func hasCompatibleMatch(in batch: [ScreenScraperGameMatch]) -> Bool {
            batch.contains { pickTitleIsCompatible(searchQuery: canonicalSearchQuery, pickTitle: $0.title) }
        }

        if let emulatorSystemId {
            for query in queries {
                let batch = (try? await ScreenScraperClient.searchGames(
                    searchQuery: query,
                    systemId: emulatorSystemId,
                    coverRegion: coverRegion
                )) ?? []
                collected.append(contentsOf: batch)
                if hasCompatibleMatch(in: batch) { return collected }
            }
        }

        if !hasCompatibleMatch(in: collected) {
            for query in queries {
                let batch = (try? await ScreenScraperClient.searchGames(
                    searchQuery: query,
                    systemId: nil,
                    coverRegion: coverRegion
                )) ?? []
                collected.append(contentsOf: batch)
                if hasCompatibleMatch(in: batch) { return collected }
            }
        }

        return collected
    }

    private static func metadataResult(from match: ScreenScraperGameMatch, method: ScreenScraperMatchMethod) -> MetadataResult {
        MetadataResult(
            normalizedTitle: match.title,
            coverImageURL: match.coverURL,
            screenScraperGameId: match.gameId,
            screenScraperSystemId: match.systemId,
            matchMethod: method
        )
    }

    private static func compatibleCandidates(searchQuery: String, in candidates: [ScreenScraperGameMatch]) -> [ScreenScraperGameMatch] {
        candidates.filter { pickTitleIsCompatible(searchQuery: searchQuery, pickTitle: $0.title) }
    }

    private static func deduplicatedCandidates(_ candidates: [ScreenScraperGameMatch]) -> [ScreenScraperGameMatch] {
        var seen = Set<String>()
        var output: [ScreenScraperGameMatch] = []
        for candidate in candidates {
            let key = "\(candidate.gameId)-\(candidate.systemId)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(candidate)
        }
        return output
    }

    private static func autoSelectedMatch(
        from candidates: [ScreenScraperGameMatch],
        emulatorSystemId: Int?,
        searchQuery: String
    ) -> ScreenScraperGameMatch? {
        if candidates.count == 1 {
            let only = candidates[0]
            return pickTitleIsCompatible(searchQuery: searchQuery, pickTitle: only.title) ? only : nil
        }

        if let emulatorSystemId {
            let emulatorMatches = candidates.filter { $0.systemId == emulatorSystemId }
            if emulatorMatches.count == 1 {
                return emulatorMatches[0]
            }
            if let best = bestTitleMatch(searchQuery: searchQuery, in: emulatorMatches) {
                return best
            }
        }

        let distinctSystems = Set(candidates.map(\.systemId))
        if distinctSystems.count == 1 {
            if let best = bestTitleMatch(searchQuery: searchQuery, in: candidates) {
                return best
            }
            return nil
        }

        if let best = bestTitleMatch(searchQuery: searchQuery, in: candidates) {
            return best
        }

        return nil
    }

    private static func bestTitleMatch(searchQuery: String, in candidates: [ScreenScraperGameMatch]) -> ScreenScraperGameMatch? {
        let scored = scoreCandidates(searchQuery: searchQuery, in: candidates).sorted { $0.1 > $1.1 }

        guard let top = scored.first, top.1 > 0 else { return nil }
        if scored.count == 1 { return top.0 }
        if scored.count > 1, top.1 > scored[1].1 {
            return top.0
        }
        return nil
    }

    /// Best-effort pick when the user allows automatic resolution of ambiguous matches.
    private static func algorithmicPick(
        from candidates: [ScreenScraperGameMatch],
        emulatorSystemId: Int?,
        searchQuery: String
    ) -> ScreenScraperGameMatch? {
        guard !candidates.isEmpty else { return nil }

        let pool: [ScreenScraperGameMatch]
        if let emulatorSystemId {
            let onEmulator = candidates.filter { $0.systemId == emulatorSystemId }
            pool = onEmulator.isEmpty ? candidates : onEmulator
        } else {
            pool = candidates
        }

        if pool.count == 1 {
            return pool[0]
        }

        if let clearWinner = bestTitleMatchWithMargin(searchQuery: searchQuery, in: pool, minimumMargin: 80) {
            return clearWinner
        }

        // User opted into auto-select: pick the best-scoring candidate even when scores are close.
        return bestTitleMatchRelaxed(searchQuery: searchQuery, in: pool)
    }

    /// Like [bestTitleMatch] but always returns the top-scoring candidate.
    private static func bestTitleMatchRelaxed(searchQuery: String, in candidates: [ScreenScraperGameMatch]) -> ScreenScraperGameMatch? {
        scoreCandidates(searchQuery: searchQuery, in: candidates)
            .sorted { $0.1 > $1.1 }
            .first?
            .0
    }

    /// Requires a clear score winner before auto-picking (avoids guessing on close matches).
    private static func bestTitleMatchWithMargin(
        searchQuery: String,
        in candidates: [ScreenScraperGameMatch],
        minimumMargin: Int
    ) -> ScreenScraperGameMatch? {
        let scored = scoreCandidates(searchQuery: searchQuery, in: candidates).sorted { $0.1 > $1.1 }
        guard let top = scored.first, top.1 > 0 else { return nil }
        if scored.count == 1 { return top.0 }
        guard let second = scored.dropFirst().first else { return top.0 }
        if top.1 - second.1 >= minimumMargin {
            return top.0
        }
        return nil
    }

    private static func scoreCandidates(searchQuery: String, in candidates: [ScreenScraperGameMatch]) -> [(ScreenScraperGameMatch, Int)] {
        candidates.map { candidate in
            (candidate, titleMatchScore(query: searchQuery, candidateTitle: candidate.title))
        }
    }

    private static func titleMatchScore(query: String, candidateTitle: String) -> Int {
        let query = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let title = candidateTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !title.isEmpty else { return 0 }

        var score = 0
        if title == query { score += 200 }
        if title.hasPrefix(query) || query.hasPrefix(title) { score += 120 }
        if title.contains(query) { score += 80 }

        let queryWordTokens = wordTokens(from: query)
        let titleWordTokens = wordTokens(from: title)

        if !title.isEmpty, query.contains(title) {
            if titleWordTokens.isSubset(of: queryWordTokens) {
                score += 60
            } else {
                score += 15
            }
        }

        score += queryWordTokens.intersection(titleWordTokens).count * 15

        let queryDistinct = distinguishingTokens(from: query)
        let titleDistinct = distinguishingTokens(from: title)
        let matchedDistinct = queryDistinct.intersection(titleDistinct)
        score += matchedDistinct.count * 40

        let missingDistinct = queryDistinct.subtracting(titleDistinct)
        score -= missingDistinct.count * 120

        let extraTitleWords = titleWordTokens.subtracting(queryWordTokens)
        if !extraTitleWords.isEmpty, queryWordTokens.count <= 2 {
            score -= extraTitleWords.count * 55
        }

        return score
    }

    private static func wordTokens(from text: String) -> Set<String> {
        Set(
            text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { String($0).lowercased() }
                .filter { $0.count >= 2 }
        )
    }

    private static func distinguishingTokens(from text: String) -> Set<String> {
        var tokens = Set<String>()
        for raw in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(raw).lowercased()
            if let canonical = RomTitleNormalizer.canonicalDistinguishingToken(word) {
                tokens.insert(canonical)
            }
        }
        return tokens
    }
}

import Foundation

/// Derives a cleaner search string from a ROM filename (similar in spirit to GBear’s name cleanup before metadata lookup).
enum RomTitleNormalizer {
    private static let romanToArabic: [String: String] = [
        "i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5",
        "vi": "6", "vii": "7", "viii": "8", "ix": "9", "x": "10",
        "xi": "11", "xii": "12", "xiii": "13", "xiv": "14", "xv": "15",
    ]

    private static let junkTokens: Set<String> = [
        "romslab", "hdd", "trial", "nsp", "eshop", "xci", "usa", "eur", "eu", "jpn", "wor",
    ]

    /// Drops dump tags so ScreenScraper title search matches the game name.
    /// `Off the Game [0100F5201B452000][v0] (1.33 GB)` → `Off the Game`; `Vandal Hearts II (USA)` → `Vandal Hearts II`.
    static func strippingTrailingParentheticalTags(_ title: String) -> String {
        var s = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let bracketPattern = #"\[[^\]]*\]"#
        while let range = s.range(of: bracketPattern, options: .regularExpression) {
            s.removeSubrange(range)
        }

        let sizePattern = #"\s*\(\s*[\d.,]+\s*(GB|MB|KB|GiB|MiB|KiB|TB)\s*\)"#
        while let range = s.range(of: sizePattern, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(range)
        }

        let switchTitleIdPattern = #"\s*\b0100[0-9A-Fa-f]{12}\b"#
        while let range = s.range(of: switchTitleIdPattern, options: .regularExpression) {
            s.removeSubrange(range)
        }

        let trailingPattern = #"\s*[\(\[][^\)\]]+[\)\]]\s*$"#
        while let range = s.range(of: trailingPattern, options: .regularExpression) {
            s.removeSubrange(range)
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when a string still looks like a dump filename (underscores, Switch title id, trailing `v0`).
    static func looksLikeDumpName(_ title: String) -> Bool {
        if title.contains("_") { return true }
        if title.range(of: #"0100[0-9A-Fa-f]{12}"#, options: .regularExpression) != nil { return true }
        if title.range(of: #"(?i)(?:^|\s)v\d+$"#, options: .regularExpression) != nil { return true }
        return false
    }

    static func searchQuery(fromFileNameStem stem: String) -> String {
        let spaced = stem.replacingOccurrences(of: "_", with: " ")
        var s = strippingTrailingParentheticalTags(spaced)
        s = stripTrailingVersionTag(s)
        for ch in ["™", "®", "©"] {
            s = s.replacingOccurrences(of: ch, with: "")
        }
        let patterns = [#"\([^)]*\)"#, #"\[[^\]]*\]"#]
        for p in patterns {
            while let r = s.range(of: p, options: .regularExpression) {
                s.removeSubrange(r)
            }
        }
        s = reorderTrailingThe(in: s)
        s = normalizeDotHack(in: s)
        s = normalizeObscure(in: s)
        s = normalizeAllCapsWords(in: s)
        s = stripJunkTokens(from: s)
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extra search strings for ScreenScraper (alternate spellings and franchise punctuation).
    static func screenscraperTitleVariants(for query: String) -> [String] {
        var variants: [String] = []
        func append(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != query, !variants.contains(trimmed) else { return }
            variants.append(trimmed)
        }

        let lower = query.lowercased()
        if lower.contains("dot hack") || lower.contains(".hack") || lower.contains("hack part") || lower.contains("hack g.u") {
            append(query.replacingOccurrences(of: "Dot Hack", with: ".hack", options: .caseInsensitive))
            append(query.replacingOccurrences(of: "dot hack", with: ".hack", options: .caseInsensitive))
            append(query.replacingOccurrences(of: " - ", with: " // "))
            append(query.replacingOccurrences(of: " : ", with: " // "))
            for variant in dotHackScreenScraperTitles(from: query) {
                append(variant)
            }
        }
        if lower.contains("obscure") {
            append(query.replacingOccurrences(of: "ObsCure", with: "Obscure", options: .caseInsensitive))
        }
        if lower.hasPrefix("the ") {
            append(String(query.dropFirst(4)))
        }
        return variants
    }

    /// Alternate query with roman numerals as arabic digits (e.g. "Final Fantasy IX" → "Final Fantasy 9").
    static func withArabicNumerals(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).map { token -> String in
            let word = String(token)
            if let arabic = romanToArabic[word.lowercased()] {
                return arabic
            }
            return word
        }.joined(separator: " ")
    }

    /// ScreenScraper region short code parsed from No-Intro-style tags in a filename.
    static func regionCode(fromFileNameStem stem: String) -> String? {
        let upper = stem.uppercased()
        let tags: [(String, String)] = [
            ("(USA)", "us"), ("(US)", "us"), ("[USA]", "us"), ("[US]", "us"),
            ("(CANADA)", "us"), ("(CAN)", "us"),
            ("(EUROPE)", "eu"), ("(EUR)", "eu"), ("(EU)", "eu"),
            ("(FRANCE)", "fr"), ("(FR)", "fr"),
            ("(GERMANY)", "de"), ("(DE)", "de"),
            ("(SPAIN)", "es"), ("(ES)", "es"),
            ("(ITALY)", "it"), ("(IT)", "it"),
            ("(JAPAN)", "jp"), ("(JPN)", "jp"), ("(JP)", "jp"),
            ("(KOREA)", "kr"), ("(KOR)", "kr"),
            ("(AUSTRALIA)", "au"), ("(AUS)", "au"),
            ("(WORLD)", "wor"), ("(WOR)", "wor"),
            ("(PORTUGAL)", "pt"), ("(PT)", "pt"),
        ]
        for (tag, code) in tags where upper.contains(tag) {
            return code
        }
        return nil
    }

    /// Canonical sequel/number token for title matching (roman numerals and digits normalize together).
    static func canonicalDistinguishingToken(_ token: String) -> String? {
        let lower = token.lowercased()
        if let arabic = romanToArabic[lower] { return arabic }
        if lower.allSatisfy(\.isNumber), !lower.isEmpty { return lower }
        return nil
    }

    private static func normalizeDotHack(in text: String) -> String {
        text.replacingOccurrences(of: "Dot Hack", with: ".hack", options: .caseInsensitive)
    }

    /// ScreenScraper lists .hack PS2 titles as `.hack//…` with `//` segment separators.
    private static func dotHackScreenScraperTitles(from query: String) -> [String] {
        var results: [String] = []
        func add(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !results.contains(trimmed) else { return }
            results.append(trimmed)
        }

        let normalized = normalizeDotHack(in: query)
        let ns = normalized as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        if normalized.range(of: "G.U.", options: .caseInsensitive) != nil,
           let volRegex = try? NSRegularExpression(pattern: #"Vol\.?\s*(\d+)"#, options: .caseInsensitive),
           let nameRegex = try? NSRegularExpression(
               pattern: #"Vol\.?\s*\d+\s*[:\-]\s*(.+)$"#,
               options: .caseInsensitive
           ),
           let volMatch = volRegex.firstMatch(in: normalized, options: [], range: fullRange),
           volMatch.numberOfRanges > 1,
           let volRange = Range(volMatch.range(at: 1), in: normalized),
           let nameMatch = nameRegex.firstMatch(in: normalized, options: [], range: fullRange),
           nameMatch.numberOfRanges > 1,
           let nameRange = Range(nameMatch.range(at: 1), in: normalized) {
            let vol = String(normalized[volRange])
            let name = String(normalized[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            add(".hack//G.U. Vol.\(vol)//\(name)")
            add(".hack//G.U. Vol \(vol)//\(name)")
        }

        if normalized.range(of: "Part", options: .caseInsensitive) != nil,
           let colon = normalized.lastIndex(of: ":") {
            let subtitle = String(normalized[normalized.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !subtitle.isEmpty {
                add(".hack//\(subtitle)")
                add(".hack \(subtitle)")
            }
        }

        return results
    }

    private static func normalizeObscure(in text: String) -> String {
        text.replacingOccurrences(of: "ObsCure", with: "Obscure", options: .caseInsensitive)
    }

    private static func normalizeAllCapsWords(in text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let w = String(word)
            guard w.count > 2, w == w.uppercased(), w.contains(where: \.isLetter) else { return w }
            return w.prefix(1).uppercased() + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    private static func stripJunkTokens(from text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !junkTokens.contains($0.lowercased()) }
            .joined(separator: " ")
    }

    private static func stripTrailingVersionTag(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?i)\s+v\d+\s*$"#
        while let range = s.range(of: pattern, options: .regularExpression) {
            s.removeSubrange(range)
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// Title through the sequel number, when words follow it.
    /// `Fullmetal Alchemist 3 The Girl Who Succeeds God` → `Fullmetal Alchemist 3`.
    static func titleThroughSequelNumber(_ query: String) -> String? {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let numberIndex = words.lastIndex(where: { canonicalDistinguishingToken($0) != nil }) else { return nil }
        guard numberIndex + 1 < words.count, numberIndex >= 1 else { return nil }
        return words[...numberIndex].joined(separator: " ")
    }

    private static func reorderTrailingThe(in text: String) -> String {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasSuffix(", the") {
            let base = String(s.dropLast(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !base.isEmpty { return "The \(base)" }
        }
        if s.lowercased().hasSuffix(" the") {
            let base = String(s.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !base.isEmpty { return "The \(base)" }
        }
        return s
    }
}

import Foundation

/// Resolves ScreenScraper platform hints from a user-configured emulator profile and the builtin catalog.
enum EmulatorPlatformResolver {
    private static nonisolated(unsafe) var resolutionCache: [UUID: (key: String, resolution: Resolution)] = [:]

    struct Resolution: Sendable {
        var gbearPlatformSlugs: [String]
        var primarySystemId: Int?
        var catalogRecord: BuiltinEmulatorProfileRecord?

        var primaryPlatformHint: String? {
            gbearPlatformSlugs.first.map { ScreenScraperPlatformMap.displayName(forGBearSlug: $0) }
        }
    }

    static func resolve(emulator: EmulatorProfile?) -> Resolution? {
        guard let emulator else { return nil }
        let key = cacheKey(for: emulator)
        if let cached = resolutionCache[emulator.id], cached.key == key {
            return cached.resolution
        }
        let resolved = resolveUncached(emulator: emulator)
        if let resolved {
            resolutionCache[emulator.id] = (key, resolved)
        }
        return resolved
    }

    private static func cacheKey(for emulator: EmulatorProfile) -> String {
        "\(emulator.name)|\(emulator.launchArgumentTemplate)|\(emulator.supportedFileTypesCSV ?? "")"
    }

    private static func resolveUncached(emulator: EmulatorProfile) -> Resolution? {
        if let record = matchingCatalogRecord(for: emulator) {
            let systemId = record.platforms.first.flatMap { ScreenScraperPlatformMap.systemId(forGBearSlug: $0) }
            return Resolution(
                gbearPlatformSlugs: record.platforms,
                primarySystemId: systemId,
                catalogRecord: record
            )
        }
        if let inferred = inferFromProfileName(emulator.name) {
            return inferred
        }
        return nil
    }

    private static func matchingCatalogRecord(for emulator: EmulatorProfile) -> BuiltinEmulatorProfileRecord? {
        let template = emulator.launchArgumentTemplate
        let extensions = emulator.supportedFileTypesSet
        let profileName = emulator.name.lowercased()

        if let core = retroArchCoreFileName(from: template) {
            let coreMatches = BuiltinEmulatorCatalogCache.profiles.filter { record in
                record.emulatorId == "retroarch" && record.startupArguments.lowercased().contains(core.lowercased())
            }
            if coreMatches.count == 1 {
                return coreMatches[0]
            }
            if coreMatches.count > 1, !extensions.isEmpty {
                return coreMatches.max(by: { overlapScore($0, extensions: extensions) < overlapScore($1, extensions: extensions) })
            }
            if let best = coreMatches.first {
                return best
            }
        }

        let normalizedTemplate = normalizeTemplate(template)
        var candidates = BuiltinEmulatorCatalogCache.profiles.filter { record in
            normalizeTemplate(CatalogLaunchArgumentOverrides.effectiveStartupArguments(for: record)) == normalizedTemplate
        }
        if candidates.count == 1 {
            return candidates[0]
        }

        candidates = BuiltinEmulatorCatalogCache.profiles.filter { record in
            guard !extensions.isEmpty else { return false }
            return overlapScore(record, extensions: extensions) > 0
        }
        if candidates.count == 1 {
            return candidates[0]
        }
        if candidates.count > 1, !extensions.isEmpty {
            return candidates.max(by: { overlapScore($0, extensions: extensions) < overlapScore($1, extensions: extensions) })
        }

        candidates = BuiltinEmulatorCatalogCache.profiles.filter { record in
            record.displayTitle.lowercased() == profileName
                || profileName.contains(record.profileName.lowercased())
        }
        if candidates.count == 1 {
            return candidates[0]
        }

        return nil
    }

    private static func inferFromProfileName(_ name: String) -> Resolution? {
        let lower = name.lowercased()
        let dolphinPairs: [(needle: String, slug: String)] = [
            ("gamecube", "nintendo_gamecube"),
            ("wii u", "nintendo_wiiu"),
            ("wii", "nintendo_wii"),
        ]
        if lower.contains("dolphin") {
            for pair in dolphinPairs where lower.contains(pair.needle) {
                return Resolution(
                    gbearPlatformSlugs: [pair.slug],
                    primarySystemId: ScreenScraperPlatformMap.systemId(forGBearSlug: pair.slug),
                    catalogRecord: nil
                )
            }
        }
        return nil
    }

    private static func retroArchCoreFileName(from template: String) -> String? {
        let pattern = #"-L\s+"?([^"\s]+_libretro\.[^"\s]+)"?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(template.startIndex..., in: template)
        guard let match = regex.firstMatch(in: template, options: [], range: range),
              match.numberOfRanges > 1,
              let coreRange = Range(match.range(at: 1), in: template) else { return nil }
        return String(template[coreRange]).split(separator: "/").last.map(String.init)
    }

    private static func normalizeTemplate(_ template: String) -> String {
        template
            .lowercased()
            .replacingOccurrences(of: "{imagepath}", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func overlapScore(_ record: BuiltinEmulatorProfileRecord, extensions: Set<String>) -> Int {
        let catalogExtensions = Set(record.imageExtensions.map { $0.lowercased() })
        return catalogExtensions.intersection(extensions).count
    }
}

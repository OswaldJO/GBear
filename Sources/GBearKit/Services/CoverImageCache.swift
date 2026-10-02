import AppKit
import CryptoKit
import Foundation
import SwiftData
import SwiftUI

/// Persists remote cover art under Application Support so the library grid loads instantly.
enum CoverImageCache {
    private static let folderName = "cover-cache"

    static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "GBear", directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory)
        let directory = base ?? URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: folderName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func normalizedURL(from urlString: String) -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
        guard let url = URL(string: normalized) else { return nil }
        guard url.isFileURL || url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    /// Pre-index cache name (hash of the full address). Still checked so older downloads are reused.
    static func localFileURL(for remoteURL: URL) -> URL {
        let hex = hexDigest(Data(remoteURL.absoluteString.utf8))
        let ext = remoteURL.pathExtension.isEmpty ? "img" : remoteURL.pathExtension
        return cacheDirectory().appendingPathComponent("\(hex).\(ext)")
    }

    /// ScreenScraper answers from rotating mirror hosts and puts the dev/user credentials in every media address,
    /// so the same image arrives under different addresses. Those parts are dropped from the cache key.
    static func cacheKey(for remote: URL) -> String {
        guard var components = URLComponents(url: remote, resolvingAgainstBaseURL: false) else { return remote.absoluteString }
        components.scheme = "https"
        if components.host?.lowercased().hasSuffix("screenscraper.fr") == true {
            components.host = "screenscraper.fr"
        }
        let volatile: Set<String> = ["devid", "devpassword", "softname", "ssid", "sspassword", "output"]
        let items = (components.queryItems ?? [])
            .filter { !volatile.contains($0.name.lowercased()) }
            .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        components.queryItems = items.isEmpty ? nil : items
        return components.string ?? remote.absoluteString
    }

    static func cachedFileURL(for urlString: String) -> URL? {
        guard let url = normalizedURL(from: urlString) else { return nil }
        if url.isFileURL {
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return existingFile(for: url)
    }

    /// Downloads a remote cover once and returns a stable `file://` reference. Files are named by content,
    /// so the same picture from different addresses is stored once.
    @discardableResult
    static func persistCoverReference(_ urlString: String) async -> String {
        guard let remote = normalizedURL(from: urlString), remote.scheme?.hasPrefix("http") == true else {
            return urlString
        }
        if let existing = existingFile(for: remote) {
            return existing.absoluteString
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: remote)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode), !data.isEmpty else {
                return urlString
            }
            guard NSImage(data: data) != nil else {
                return urlString
            }
            let rawExt = remote.pathExtension.lowercased()
            let ext = rawExt.isEmpty ? "img" : (rawExt == "php" ? "jpg" : rawExt)
            let destination = cacheDirectory().appendingPathComponent("\(hexDigest(data)).\(ext)")
            if !FileManager.default.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: .atomic)
            }
            Index.set(destination.lastPathComponent, for: cacheKey(for: remote))
            return destination.absoluteString
        } catch {
            return urlString
        }
    }

    private static func existingFile(for remote: URL) -> URL? {
        let fm = FileManager.default
        let key = cacheKey(for: remote)
        if let name = Index.fileName(for: key) {
            let indexed = cacheDirectory().appendingPathComponent(name)
            if fm.fileExists(atPath: indexed.path) { return indexed }
        }
        let legacy = localFileURL(for: remote)
        for candidate in [legacy, legacy.deletingPathExtension().appendingPathExtension("jpg")]
        where fm.fileExists(atPath: candidate.path) {
            Index.set(candidate.lastPathComponent, for: key)
            return candidate
        }
        return nil
    }

    static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Cache key → file name, saved as `index.json` in the cache folder.
    private enum Index {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var entries: [String: String]?

        private static var fileURL: URL { cacheDirectory().appendingPathComponent("index.json") }

        static func fileName(for key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return loadedLocked()[key]
        }

        static func set(_ name: String, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            var map = loadedLocked()
            guard map[key] != name else { return }
            map[key] = name
            entries = map
            if let data = try? JSONEncoder().encode(map) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }

        /// Points entries at kept files after duplicates were merged (`old file name → kept file name`).
        static func remap(_ renames: [String: String]) {
            lock.lock()
            defer { lock.unlock() }
            var map = loadedLocked()
            for (key, name) in map {
                if let kept = renames[name] { map[key] = kept }
            }
            entries = map
            if let data = try? JSONEncoder().encode(map) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }

        private static func loadedLocked() -> [String: String] {
            if let entries { return entries }
            let loaded = (try? Data(contentsOf: fileURL))
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            entries = loaded
            return loaded
        }
    }

    /// Byte-identical files in the cache folder: each duplicate's path → the copy to keep. Run off the main thread.
    nonisolated static func duplicateFileMap() -> [String: String] {
        let fm = FileManager.default
        let directory = cacheDirectory()
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [:] }
        var keeperByDigest: [String: URL] = [:]
        var map: [String: String] = [:]
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension != "json" {
            guard let data = try? Data(contentsOf: file) else { continue }
            let digest = hexDigest(data)
            if let keeper = keeperByDigest[digest] {
                map[file.standardizedFileURL.path] = keeper.standardizedFileURL.path
            } else {
                keeperByDigest[digest] = file
            }
        }
        return map
    }

    private static let mergedDuplicatesKey = "CoverCache.MergedDuplicates.v1"

    /// One time: earlier scrapes saved the same picture once per address (BJ-119). Points every game at one copy,
    /// drops the repeats from its cover list, and deletes the extra files. Returns how many games changed.
    @MainActor
    @discardableResult
    static func mergeDuplicateCoversOnce(context: ModelContext) async -> Int {
        guard !UserDefaults.standard.bool(forKey: mergedDuplicatesKey) else { return 0 }
        let map = await Task.detached(priority: .utility) { duplicateFileMap() }.value
        defer { UserDefaults.standard.set(true, forKey: mergedDuplicatesKey) }
        guard !map.isEmpty, let games = try? context.fetch(FetchDescriptor<LibraryGame>()) else { return 0 }

        func kept(_ option: String) -> String {
            guard let url = URL(string: option), url.isFileURL,
                  let keeper = map[url.standardizedFileURL.path] else { return option }
            return URL(fileURLWithPath: keeper).absoluteString
        }

        var changed = 0
        for game in games {
            let primary = game.coverImageURLString.map(kept)
            let options = game.coverImageOptions.map(kept)
            guard primary != game.coverImageURLString || options != game.coverImageOptions else { continue }
            game.coverImageURLString = primary
            game.coverImageOptions = options
            changed += 1
        }
        try? context.save()

        Index.remap(Dictionary(uniqueKeysWithValues: map.map {
            (URL(fileURLWithPath: $0.key).lastPathComponent, URL(fileURLWithPath: $0.value).lastPathComponent)
        }))
        for duplicate in map.keys {
            try? FileManager.default.removeItem(atPath: duplicate)
        }
        return changed
    }

    static func loadNSImage(urlString: String?) -> NSImage? {
        guard let urlString, let fileURL = cachedFileURL(for: urlString), fileURL.isFileURL else { return nil }
        return NSImage(contentsOf: fileURL)
    }

    private nonisolated(unsafe) static let memory: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()

    /// Covers already on disk, kept in memory once loaded. The library grid is lazy and discards tiles that
    /// scroll far away; a recreated tile reads its image (and so its size) from here on its first frame instead
    /// of drawing a placeholder at the default height and then jumping to the cover's shape (BJ-126).
    static func image(for urlString: String?) -> NSImage? {
        guard let urlString else { return nil }
        if let cached = memory.object(forKey: urlString as NSString) { return cached }
        guard let image = loadNSImage(urlString: urlString) else { return nil }
        memory.setObject(image, forKey: urlString as NSString)
        return image
    }
}

/// Cover tile that reads from disk cache (no network reload on every library visit).
struct CachedCoverThumbnail: View {
    let urlString: String?
    var contentMode: ContentMode = .fill
    var onImageSize: ((CGSize?) -> Void)?

    @State private var image: NSImage?

    init(urlString: String?, contentMode: ContentMode = .fill, onImageSize: ((CGSize?) -> Void)? = nil) {
        self.urlString = urlString
        self.contentMode = contentMode
        self.onImageSize = onImageSize
        _image = State(initialValue: CoverImageCache.image(for: urlString))
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .task(id: urlString) {
            await refreshImage()
            onImageSize?(image?.size)
        }
    }

    private func refreshImage() async {
        guard let urlString else {
            image = nil
            return
        }
        if let cached = CoverImageCache.image(for: urlString) {
            if image !== cached { image = cached }
            return
        }
        let persisted = await CoverImageCache.persistCoverReference(urlString)
        image = CoverImageCache.image(for: persisted)
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }
}

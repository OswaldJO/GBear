import AppKit
import CryptoKit
import Foundation
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

    static func localFileURL(for remoteURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let ext = remoteURL.pathExtension.isEmpty ? "img" : remoteURL.pathExtension
        return cacheDirectory().appendingPathComponent("\(hex).\(ext)")
    }

    static func cachedFileURL(for urlString: String) -> URL? {
        guard let url = normalizedURL(from: urlString) else { return nil }
        if url.isFileURL {
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let local = localFileURL(for: url)
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    /// Downloads a remote cover once and returns a stable `file://` reference.
    @discardableResult
    static func persistCoverReference(_ urlString: String) async -> String {
        guard let remote = normalizedURL(from: urlString), remote.scheme?.hasPrefix("http") == true else {
            return urlString
        }
        let destination = localFileURL(for: remote)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination.absoluteString
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: remote)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode), !data.isEmpty else {
                return urlString
            }
            guard NSImage(data: data) != nil else {
                return urlString
            }
            let writeURL = destination.pathExtension.lowercased() == "php"
                ? destination.deletingPathExtension().appendingPathExtension("jpg")
                : destination
            try data.write(to: writeURL, options: .atomic)
            return writeURL.absoluteString
        } catch {
            return urlString
        }
    }

    static func loadNSImage(urlString: String?) -> NSImage? {
        guard let urlString, let fileURL = cachedFileURL(for: urlString), fileURL.isFileURL else { return nil }
        return NSImage(contentsOf: fileURL)
    }
}

/// Cover tile that reads from disk cache (no network reload on every library visit).
struct CachedCoverThumbnail: View {
    let urlString: String?
    var contentMode: ContentMode = .fill

    @State private var image: NSImage?

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
        }
    }

    private func refreshImage() async {
        guard let urlString else {
            image = nil
            return
        }
        if let cached = CoverImageCache.loadNSImage(urlString: urlString) {
            image = cached
            return
        }
        let persisted = await CoverImageCache.persistCoverReference(urlString)
        image = CoverImageCache.loadNSImage(urlString: persisted)
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }
}

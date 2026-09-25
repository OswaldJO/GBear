import Foundation

/// File-backed log for a user-initiated library metadata scrape.
enum MetadataScrapeSessionLog {
    private static let fileName = "metadata_scrape.log"
    private static let queue = DispatchQueue(label: "MetadataScrapeSessionLog")
    private nonisolated(unsafe) static var sessionActive = false
    private nonisolated(unsafe) static var writer: FileHandle?

    static func startSession(totalGames: Int, preferredRegion: String) {
        queue.sync {
            closeWriterLocked()
            sessionActive = true
            guard let url = logFileURL() else { return }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            do {
                writer = try FileHandle(forWritingTo: url)
                writeLocked("I", "=== ScreenScraper library scrape started ===")
                writeLocked("I", "host=\(ProcessInfo.processInfo.hostName)")
                writeLocked("I", "games=\(totalGames) preferredRegion=\(preferredRegion)")
                writeLocked("I", "credentialsConfigured=\(MetadataCredentials.isConfigured) userLogin=\(MetadataCredentials.hasUserCredentials)")
            } catch {
                writer = nil
                sessionActive = false
            }
        }
    }

    static func i(_ message: String) {
        queue.sync { writeLocked("I", message) }
    }

    static func w(_ message: String) {
        queue.sync { writeLocked("W", message) }
    }

    static func e(_ message: String) {
        queue.sync { writeLocked("E", message) }
    }

    @discardableResult
    static func endSession(summary: MetadataBackgroundFetcher.ScrapeSummary) -> URL? {
        queue.sync {
            if sessionActive {
                writeLocked("I", "processed=\(summary.processed) updated=\(summary.updated)")
                writeLocked("I", "=== ScreenScraper library scrape ended ===")
            }
            sessionActive = false
            closeWriterLocked()
            return logFileURLIfNonEmpty()
        }
    }

    static func logFileURLIfNonEmpty() -> URL? {
        guard let url = logFileURL() else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 0 ? url : nil
    }

    private static func logFileURL() -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "GBear", directoryHint: .isDirectory)
            .appending(path: "metadata-scrape", directoryHint: .isDirectory)
        guard let base else { return nil }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: fileName)
    }

    private static func writeLocked(_ level: String, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        writer?.write(data)
    }

    private static func closeWriterLocked() {
        try? writer?.close()
        writer = nil
    }

    /// Copies the session log into ~/Downloads with a timestamped name.
    static func saveCopyToDownloads(from source: URL) -> URL? {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return nil
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = "gbear-scrape-\(stamp).log"
        let destination = downloads.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}

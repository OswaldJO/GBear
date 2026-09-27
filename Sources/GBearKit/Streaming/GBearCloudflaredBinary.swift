import Darwin
import Foundation

/// Finds or downloads the Cloudflare tunnel client so the host can open an outbound relay.
enum GBearCloudflaredBinary {
    private static let supportFolder = "GBear/gbear-stream"

    static func ensure() async throws -> URL {
        if let installed = existingInstall(), FileManager.default.isExecutableFile(atPath: installed.path) {
            return installed
        }
        let destination = try supportDirectory().appending(path: "cloudflared")
        if FileManager.default.isExecutableFile(atPath: destination.path), try await runs(destination) {
            return destination
        }
        let asset: String
        if machine() == "arm64" {
            asset = "cloudflared-darwin-arm64.tgz"
        } else {
            asset = "cloudflared-darwin-amd64.tgz"
        }
        guard let remote = URL(string: "https://github.com/cloudflare/cloudflared/releases/latest/download/\(asset)") else {
            throw failure("Could not build the connector download URL.")
        }
        let archive = try supportDirectory().appending(path: asset)
        let (downloaded, response) = try await URLSession.shared.download(from: remote)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw failure("Could not download the network connector (HTTP \(status)).")
        }
        if FileManager.default.fileExists(atPath: archive.path) {
            try FileManager.default.removeItem(at: archive)
        }
        try FileManager.default.moveItem(at: downloaded, to: archive)
        try extract(archive: archive, into: try supportDirectory())
        try? FileManager.default.removeItem(at: archive)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw failure("The network connector download did not include cloudflared.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        clearQuarantine(destination)
        guard try await runs(destination) else {
            throw failure("The network connector was downloaded but would not start.")
        }
        return destination
    }

    private static func existingInstall() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
        ]
        return candidates.map { URL(fileURLWithPath: $0) }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private static func supportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: supportFolder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    private static func extract(archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw failure("Could not unpack the network connector.")
        }
    }

    private static func clearQuarantine(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-d", "com.apple.quarantine", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    private static func runs(_ url: URL) async throws -> Bool {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "GBearCloudflared", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

import Foundation

/// Playnite-native streaming (no Sunshine/Moonlight ports).
enum PlayniteStreamPorts {
    /// HTTP control plane: status, pairing, session.
    static let controlHTTP: UInt16 = 28765
    /// Raw H.264 over TCP (`PNV1` framed packets).
    static let videoTCP: UInt16 = 28766
    /// PCM audio subscribe (`PNAS`) over UDP; phone also opens `audioTCP` for downlink.
    static let audioUDP: UInt16 = 28767
    /// Framed `PNA1` over TCP (4-byte little-endian length + packet). Primary audio path on LAN.
    static let audioTCP: UInt16 = 28769
    /// Touch / pointer events from phone over UDP (`PNI1` packets).
    static let inputUDP: UInt16 = 28768
    static let protocolVersion = "playnite-stream/1"
    static let videoMagic: UInt32 = 0x3156_4E50 // "PNV1" little-endian
    static let audioMagic: UInt32 = 0x3141_4E50 // "PNA1" little-endian
    static let audioSubscribeMagic: UInt32 = 0x5341_4E50 // "PNAS" little-endian
    static let inputMagic: UInt32 = 0x3149_4E50 // "PNI1" little-endian
    static let keyboardMagic: UInt32 = 0x314B_4E50 // "PNK1" little-endian
    /// Structured gamepad state for co-op seats (`PNG1`).
    static let gamepadMagic: UInt32 = 0x3147_4E50 // "PNG1" little-endian
    static let maxCoopViewers = 2
}

/// File-backed diagnostics for an active companion stream (Mac host side).
enum PlayniteStreamSessionLog {
    private static let fileName = "playnite_stream.log"
    private static let queue = DispatchQueue(label: "PlayniteStreamSessionLog")
    private nonisolated(unsafe) static var sessionActive = false
    private nonisolated(unsafe) static var writer: FileHandle?

    static func startSession(deviceName: String?, width: Int, height: Int, fps: Int) {
        queue.sync {
            closeWriterLocked()
            sessionActive = true
            guard let url = logFileURL() else { return }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            do {
                writer = try FileHandle(forWritingTo: url)
                let device = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? deviceName!
                    : "companion"
                writeLocked("I", "=== Playnite stream log started (Mac host) ===")
                writeLocked("I", "host=\(ProcessInfo.processInfo.hostName)")
                writeLocked("I", "device=\(device) stream=\(width)x\(height) @ \(fps)fps")
                writeLocked(
                    "I",
                    "Ports: control \(PlayniteStreamPorts.controlHTTP), video \(PlayniteStreamPorts.videoTCP), " +
                        "audio UDP \(PlayniteStreamPorts.audioUDP), audio TCP \(PlayniteStreamPorts.audioTCP), " +
                        "input \(PlayniteStreamPorts.inputUDP)"
                )
                writeLocked(
                    "I",
                    "Logs include: companion stream/start|stop, TCP video, audio subscribe, PNK1/PNI1 (see Console too)"
                )
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
    static func endSession(reason: String) -> URL? {
        queue.sync {
            if sessionActive {
                writeLocked("I", "=== Playnite stream log ended: \(reason) ===")
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
            .appending(path: "playnite-stream", directoryHint: .isDirectory)
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
        let name = "playnite-stream-\(stamp).log"
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

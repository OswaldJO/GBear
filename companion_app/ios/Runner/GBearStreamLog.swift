import Foundation
import UIKit

/// File-backed stream diagnostics (mirrors Android `GBearStreamLog`).
enum GBearStreamLog {
  private static let fileName = "gbear_stream.log"
  private static let queue = DispatchQueue(label: "com.gbear.streamlog")
  private static var writer: TextOutputStream?

  static func startSession(host: String, port: Int, width: Int, height: Int) {
    queue.sync {
      closeWriterLocked()
      guard let url = logFileURL() else { return }
      do {
        try "".write(to: url, atomically: true, encoding: .utf8)
        writer = try FileWriter(url: url)
        i("=== GBear stream log started ===")
        i("device=\(UIDevice.current.model) iOS=\(UIDevice.current.systemVersion)")
        i("target=\(host):\(port) \(width)x\(height)")
        i("Logs include: TCP connect, GBV1 frames, decode/display errors")
      } catch {
        writer = nil
      }
    }
  }

  static func i(_ message: String) { write("I", message) }
  static func w(_ message: String) { write("W", message) }
  static func e(_ message: String) { write("E", message) }

  @discardableResult
  static func endSession(reason: String) -> String? {
    queue.sync {
      writeLocked("I", "=== GBear stream log ended: \(reason) ===")
      closeWriterLocked()
      return logFilePath()
    }
  }

  static func logFilePath() -> String? {
    guard let url = logFileURL() else { return nil }
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
    return size > 0 ? url.path : nil
  }

  private static func logFileURL() -> URL? {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
      .appendingPathComponent(fileName)
  }

  private static func write(_ level: String, _ message: String) {
    queue.sync { writeLocked(level, message) }
  }

  private static func writeLocked(_ level: String, _ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) [\(level)] \(message)\n"
    writer?.write(line)
    // Native logs do not appear in `flutter run` by default; use Xcode Console or `flutter logs`.
    NSLog("[GBearVideo] %@", message)
  }

  private static func closeWriterLocked() {
    writer = nil
  }

  private struct FileWriter: TextOutputStream {
    private let handle: FileHandle

    init(url: URL) throws {
      FileManager.default.createFile(atPath: url.path, contents: nil)
      handle = try FileHandle(forWritingTo: url)
    }

    mutating func write(_ string: String) {
      guard let data = string.data(using: .utf8) else { return }
      handle.write(data)
    }
  }
}

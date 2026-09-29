import CoreGraphics
import Foundation

/// GBear windows that must never appear in the streamed picture (for example the bitrate overlay).
enum GBearCaptureExclusions {
    static let didChange = Notification.Name("GBearCaptureExclusionsDidChange")

    private static let lock = NSLock()
    private nonisolated(unsafe) static var ids: Set<CGWindowID> = []

    static var windowIDs: Set<CGWindowID> {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }

    static func add(_ id: CGWindowID) {
        lock.lock()
        let inserted = ids.insert(id).inserted
        lock.unlock()
        if inserted { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    static func remove(_ id: CGWindowID) {
        lock.lock()
        let removed = ids.remove(id) != nil
        lock.unlock()
        if removed { NotificationCenter.default.post(name: didChange, object: nil) }
    }
}

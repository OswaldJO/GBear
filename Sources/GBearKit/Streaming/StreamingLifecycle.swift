import Foundation

/// App-level hooks for the native GBear stream host.
public enum StreamingLifecycle {
    public static func stopManagedHostOnQuit() {
        Task { await GBearStreamHostManager.shared.stop() }
    }
}

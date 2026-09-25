import AppKit
import CoreGraphics
import Foundation

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

/// In-process screen capture permission (GBear only).
@MainActor
final class GBearScreenCapturePipeline {
    private(set) var isReady = false
    private(set) var lastError: String?
    /// True when capture is allowed (ScreenCaptureKit probe or CoreGraphics preflight).
    private(set) var hasSystemAuthorization = false

    /// Checks permission only — never shows the system dialog.
    func refresh() async {
        lastError = nil
        isReady = false
        hasSystemAuthorization = false

        #if canImport(ScreenCaptureKit)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !content.displays.isEmpty else {
                lastError = "No display available for capture."
                hasSystemAuthorization = ScreenCaptureAuthorization.preflightGranted()
                return
            }
            hasSystemAuthorization = true
            isReady = true
            return
        } catch {
            let preflight = ScreenCaptureAuthorization.preflightGranted()
            hasSystemAuthorization = preflight
            if preflight {
                lastError = "\(error.localizedDescription) Restart the streaming host."
            } else {
                lastError = "Screen Recording is not enabled for GBear."
            }
            return
        }
        #else
        hasSystemAuthorization = ScreenCaptureAuthorization.preflightGranted()
        if hasSystemAuthorization {
            isReady = true
        } else {
            lastError = "Screen Recording is not enabled for GBear."
        }
        #endif
    }

    /// System consent dialog (adds the app to Screen Recording). Call only from explicit UI or stream start.
    func requestSystemPrompt() async -> Bool {
        await refresh()
        if isReady { return true }

        guard !hasSystemAuthorization else { return false }

        _ = ScreenCaptureAuthorization.requestAccess()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await refresh()
        return isReady
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

import AppKit
import SwiftUI

/// Standalone resizable window for the computer guest's stream, so the picture can grow to full screen.
@MainActor
final class GBearGuestVideoWindow: NSObject, NSWindowDelegate {
    static let shared = GBearGuestVideoWindow()

    private var window: NSWindow?
    private var onUserClose: (() -> Void)?

    var isOpen: Bool { window != nil }

    func show(title: String, onUserClose: @escaping () -> Void) {
        self.onUserClose = onUserClose
        if let window {
            window.title = title
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.initialSize()),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.contentMinSize = NSSize(width: 480, height: 270)
        window.backgroundColor = .black
        window.contentView = NSHostingView(rootView: GBearGuestVideoWindowContent())
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func updateTitle(_ title: String) {
        window?.title = title
    }

    /// Closes without calling `onUserClose` (the caller already left the session).
    func close() {
        onUserClose = nil
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        let callback = onUserClose
        onUserClose = nil
        callback?()
    }

    private static func initialSize() -> NSSize {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let width = min(1280, visible.width * 0.8, (visible.height * 0.8 - 28) * 16 / 9)
        return NSSize(width: width.rounded(), height: (width * 9 / 16).rounded())
    }
}

private struct GBearGuestVideoWindowContent: View {
    @State private var guestManager = GBearStreamGuestManager.shared

    var body: some View {
        GBearGuestVideoView(sample: guestManager.latestSample)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .ignoresSafeArea()
    }
}

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
        GBearGuestVideoRenderer.shared.onVideoSizeChange = { size in
            GBearGuestVideoWindow.shared.matchVideoShape(size)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// Resizes the window to the stream's shape (for example 16:10 from a MacBook) so there are no bars.
    func matchVideoShape(_ size: CGSize) {
        guard let window, size.width > 0, size.height > 0,
              !window.styleMask.contains(.fullScreen) else { return }
        window.contentAspectRatio = size
        let current = window.contentLayoutRect.size
        let height = (current.width * size.height / size.width).rounded()
        guard abs(height - current.height) > 1 else { return }
        var frame = window.frame
        let newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: current.width, height: height)))
        frame.origin.y += frame.height - newFrame.height
        frame.size = newFrame.size
        window.setFrame(frame, display: true, animate: false)
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
    @AppStorage(GBearStreamGuestManager.showHostBitRateKey) private var showHostBitRate = true

    var body: some View {
        GBearGuestVideoView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .overlay(alignment: .topLeading) {
                if showHostBitRate {
                    GBearHostBitRateBadge()
                        .padding(10)
                }
            }
            .ignoresSafeArea()
    }
}

/// The host's video bitrate, as the host reports it once a second.
private struct GBearHostBitRateBadge: View {
    @State private var guest = GBearStreamGuestManager.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let rate = guest.hostBitRate, context.date.timeIntervalSince(rate.receivedAt) < 4 {
                Text(Self.text(rate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .allowsHitTesting(false)
                    .help("Video bitrate the host is sending. The number after the slash is the host's target.")
            }
        }
    }

    static func text(_ rate: GBearStreamGuestManager.HostBitRate) -> String {
        let measured = String(format: "%.1f", Double(rate.measured) / 1_000_000)
        guard rate.target > 0 else { return "Host \(measured) Mbit/s" }
        return "Host \(measured) / \(String(format: "%.1f", Double(rate.target) / 1_000_000)) Mbit/s"
    }
}

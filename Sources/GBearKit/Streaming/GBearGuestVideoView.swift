import AppKit
import QuartzCore
import SwiftUI

/// Guest picture. Frames go straight from the decoder to `GBearGuestVideoRenderer`, not through SwiftUI.
struct GBearGuestVideoView: NSViewRepresentable {
    func makeNSView(context: Context) -> GBearGuestVideoNSView {
        GBearGuestVideoNSView()
    }

    func updateNSView(_ nsView: GBearGuestVideoNSView, context: Context) {}
}

final class GBearGuestVideoNSView: NSView {
    private let metalLayer = GBearGuestVideoRenderer.shared.makeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = metalLayer
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = metalLayer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            updateDrawableSize()
            GBearGuestVideoRenderer.shared.attach(metalLayer)
        } else {
            GBearGuestVideoRenderer.shared.detach(metalLayer)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        GBearGuestVideoRenderer.shared.setDrawableSize(
            CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        )
    }
}

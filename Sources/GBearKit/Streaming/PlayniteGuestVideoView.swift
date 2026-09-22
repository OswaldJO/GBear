import AVFoundation
import CoreMedia
import SwiftUI

struct PlayniteGuestVideoView: NSViewRepresentable {
    var sample: CMSampleBuffer?

    func makeNSView(context: Context) -> PlayniteGuestVideoNSView {
        PlayniteGuestVideoNSView()
    }

    func updateNSView(_ nsView: PlayniteGuestVideoNSView, context: Context) {
        if let sample {
            nsView.enqueue(sample)
        }
    }
}

final class PlayniteGuestVideoNSView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = displayLayer
        displayLayer.videoGravity = .resizeAspect
    }

    func enqueue(_ sample: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sample)
    }
}

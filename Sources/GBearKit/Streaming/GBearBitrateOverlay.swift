import AppKit
import SwiftUI

/// Small always-on-top bitrate readout that stays visible over games, including full-screen ones.
/// It is left out of the streamed picture, so friends never see it.
@MainActor
@Observable
final class GBearBitrateOverlay: NSObject, NSWindowDelegate {
    static let shared = GBearBitrateOverlay()

    struct Sample: Equatable {
        let measured: Int
        let target: Int
    }

    static let historyLength = 60

    private(set) var isOpen = false
    private(set) var history: [Sample] = []

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var timer: Timer?
    /// Keeps the once-a-second readout from being throttled by App Nap while a game is in front.
    @ObservationIgnored private var stayAwake: NSObjectProtocol?

    func toggle() {
        if isOpen { close() } else { show() }
    }

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 230, height: 118),
            styleMask: [.titled, .closable, .utilityWindow, .hudWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Bitrate"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        // Above ordinary and floating windows so a game in front of GBear does not cover it.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: GBearBitrateOverlayContent())
        panel.delegate = self
        if !panel.setFrameUsingName("GBearBitrateOverlay") {
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 250, y: screen.maxY - 20))
            }
        }
        panel.setFrameAutosaveName("GBearBitrateOverlay")
        panel.orderFrontRegardless()
        self.panel = panel
        isOpen = true
        GBearCaptureExclusions.add(CGWindowID(panel.windowNumber))

        history = []
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in await GBearBitrateOverlay.shared.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        stayAwake = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "GBear bitrate overlay"
        )
        Task { await sample() }
    }

    func close() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        if let stayAwake {
            ProcessInfo.processInfo.endActivity(stayAwake)
            self.stayAwake = nil
        }
        if let panel {
            GBearCaptureExclusions.remove(CGWindowID(panel.windowNumber))
            panel.delegate = nil
        }
        panel = nil
        isOpen = false
    }

    private func sample() async {
        let host = GBearStreamHostManager.shared
        await host.refreshVideoBitRate()
        guard host.isVideoStreaming, let rate = host.videoBitRate else {
            if !history.isEmpty { history = [] }
            return
        }
        history.append(Sample(measured: rate.measured, target: rate.target))
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }
}

private struct GBearBitrateOverlayContent: View {
    @State private var overlay = GBearBitrateOverlay.shared
    @State private var host = GBearStreamHostManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if host.isVideoStreaming, let rate = host.videoBitRate {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(rate.measured > 0 ? Self.mbit(rate.measured) : "…")
                        .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    Text("Mbit/s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(detailText(target: rate.target))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                GBearBitrateSparkline(samples: overlay.history)
                    .frame(height: 30)
            } else {
                Text("Not streaming")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Shows the video bitrate while a phone or friend is watching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func detailText(target: Int) -> String {
        var text = "target \(Self.mbit(target))"
        if let rtt = host.relayRoundTripMillis {
            text += String(format: " · round trip %.0f ms", rtt)
        }
        return text
    }

    private static func mbit(_ bitsPerSecond: Int) -> String {
        String(format: "%.1f", Double(bitsPerSecond) / 1_000_000)
    }
}

/// Last minute of measured bitrate (filled) against the target (dashed line).
private struct GBearBitrateSparkline: View {
    let samples: [GBearBitrateOverlay.Sample]

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let peak = samples.map { max($0.measured, $0.target) }.max() ?? 1
            let top = Double(max(peak, 1)) * 1.1
            let step = size.width / CGFloat(GBearBitrateOverlay.historyLength - 1)
            let startX = size.width - step * CGFloat(samples.count - 1)
            func point(_ index: Int, _ value: Int) -> CGPoint {
                CGPoint(
                    x: startX + step * CGFloat(index),
                    y: size.height - size.height * CGFloat(Double(value) / top)
                )
            }

            var area = Path()
            area.move(to: CGPoint(x: startX, y: size.height))
            for (index, sample) in samples.enumerated() {
                area.addLine(to: point(index, sample.measured))
            }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(.accentColor.opacity(0.35)))

            var measured = Path()
            var target = Path()
            for (index, sample) in samples.enumerated() {
                let m = point(index, sample.measured)
                let t = point(index, sample.target)
                if index == 0 {
                    measured.move(to: m)
                    target.move(to: t)
                } else {
                    measured.addLine(to: m)
                    target.addLine(to: t)
                }
            }
            context.stroke(measured, with: .color(.accentColor), lineWidth: 1.5)
            context.stroke(target, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }
}

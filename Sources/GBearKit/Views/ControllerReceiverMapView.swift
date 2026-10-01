import SwiftUI

/// **Controller map** button beside **Move to**: live view of the pad input this Mac receives for one player.
struct ControllerReceiverMapButton: View {
    let seat: Int
    let playerName: String

    @State private var monitor = GBearPadInputMonitor.shared
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Controller map", systemImage: "gamecontroller")
                .foregroundStyle(isAnyControlPressed ? Color.green : Color.primary)
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ControllerReceiverMapPanel(seat: seat, playerName: playerName)
        }
    }

    private var isAnyControlPressed: Bool {
        guard let reading = monitor.readings[seat] else { return false }
        return GBearPadControl.allCases.contains { $0.isPressed(in: reading.event) }
    }
}

private struct ControllerReceiverMapPanel: View {
    let seat: Int
    let playerName: String

    @State private var monitor = GBearPadInputMonitor.shared

    var body: some View {
        let reading = monitor.readings[seat]
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Player \(seat) — \(playerName)")
                    .font(.headline)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    signalLine(reading: reading, now: context.date)
                }
                Text(routeNote(reading?.route))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top])

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(GBearPadControl.allCases, id: \.self) { control in
                        row(control, reading: reading)
                        Divider()
                    }
                }
            }
        }
        .frame(width: 380, height: 520)
    }

    @ViewBuilder
    private func signalLine(reading: GBearPadInputMonitor.Reading?, now: Date) -> some View {
        if let reading {
            let age = max(0, now.timeIntervalSince(reading.receivedAt))
            Label(
                age < 1 ? "Receiving" : "Last signal \(Self.ageText(age)) ago",
                systemImage: "dot.radiowaves.left.and.right"
            )
            .font(.subheadline)
            .foregroundStyle(age < 5 ? Color.green : Color.orange)
        } else {
            Label("No signal yet. Ask them to press a button.", systemImage: "antenna.radiowaves.left.and.right.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ control: GBearPadControl, reading: GBearPadInputMonitor.Reading?) -> some View {
        let value = reading.map { control.value(in: $0.event) } ?? 0
        let pressed = value > GBearPadControl.pressThreshold
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(control.label)
                    .font(.body)
                Text(summary(control, route: reading?.route))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            stateBadge(control, value: value, pressed: pressed)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(pressed ? Color.green.opacity(0.18) : Color.clear)
    }

    @ViewBuilder
    private func stateBadge(_ control: GBearPadControl, value: Float, pressed: Bool) -> some View {
        let text: String = if pressed {
            "Pressed"
        } else if control.isAnalog, value > 0.05 {
            "\(Int((value * 100).rounded()))%"
        } else {
            "—"
        }
        Text(text)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(pressed ? Color.green : Color.secondary.opacity(0.15))
            )
            .foregroundStyle(pressed ? Color.white : Color.secondary)
    }

    private func summary(_ control: GBearPadControl, route: GBearPadInputMonitor.Route?) -> String {
        switch route {
        case .keyboard, .unrouted, nil:
            if let key = control.standInKey(seat: seat) {
                "Sends \(key.label)"
            } else {
                "Not delivered"
            }
        case .virtualPad:
            "GBear Virtual Pad \(seat)"
        case .hostController:
            "Read directly by the emulator"
        }
    }

    private func routeNote(_ route: GBearPadInputMonitor.Route?) -> String {
        switch route {
        case .keyboard, .unrouted, nil:
            padMissingNote
        case .virtualPad:
            "The emulator sees this player as GBear Virtual Pad \(seat), a PlayStation 4 controller (some emulators list it as “PS4 Controller” or “Wireless Controller”)."
        case .hostController:
            "This Mac’s own controller. The emulator reads it directly."
        }
    }

    private var padMissingNote: String {
        let why = GBearVirtualGamepad.isEntitled
            ? "macOS refused to create GBear Virtual Pad \(seat) even though GBear has the Virtual HID permission (see Console for IOHIDUserDevice errors)."
            : "This Mac can’t create GBear Virtual Pad \(seat) yet (needs Apple’s Virtual HID permission)."
        if GBearPadControl.seatsWithKeys.contains(seat) {
            return why + " Until then, set Player \(seat) to the keyboard in the emulator. Each button below presses its own key."
        }
        return why + " Only Players 1–4 have stand-in keys, so Player \(seat) reaches the game once virtual pads work."
    }

    private static func ageText(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds)) s"
        }
        return "\(Int(seconds / 60)) min"
    }
}

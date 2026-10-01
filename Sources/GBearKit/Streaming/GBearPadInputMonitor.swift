import Foundation
import Observation

/// Latest pad state per player seat, for the host's **Controller map** panel.
@MainActor
@Observable
final class GBearPadInputMonitor {
    static let shared = GBearPadInputMonitor()

    enum Route: Equatable {
        /// Emulator sees `GBear Virtual Pad N`.
        case virtualPad
        /// `GBearKeyboardPadStandIn` presses keys for this seat.
        case keyboard
        /// No virtual pad and no stand-in keys left for this seat (Players 5–8).
        case unrouted
        /// This Mac's own controller, which the emulator reads directly.
        case hostController
    }

    struct Reading {
        var event: GBearGamepadEventFormat.Event
        var receivedAt: Date
        var route: Route
    }

    private(set) var readings: [Int: Reading] = [:]

    func record(seat: Int, event: GBearGamepadEventFormat.Event, route: Route) {
        readings[seat] = Reading(event: event, receivedAt: Date(), route: route)
    }

    func clear(seat: Int) {
        readings.removeValue(forKey: seat)
    }

    func clearAll() {
        readings.removeAll()
    }
}

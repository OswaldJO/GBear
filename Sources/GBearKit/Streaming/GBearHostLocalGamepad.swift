import Foundation
import GameController

/// Routes this Mac's physical gamepads into a chosen GBear virtual pad (host-local player).
@MainActor
final class GBearHostLocalGamepad {
    static let shared = GBearHostLocalGamepad()

    private(set) var isActive = false
    private(set) var seat: Int = 1
    private var observers: [NSObjectProtocol] = []

    func start(seat: Int) {
        self.seat = seat
        if isActive {
            bindAll()
            return
        }
        isActive = true
        GCController.shouldMonitorBackgroundEvents = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.bindAll() }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.bindAll() }
        })
        bindAll()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
        }
        let empty = GBearGamepadEventFormat.Event(
            seat: UInt8(seat),
            buttons: 0,
            leftX: 0,
            leftY: 0,
            rightX: 0,
            rightY: 0,
            leftTrigger: 0,
            rightTrigger: 0
        )
        let padSeat = seat
        Task {
            await GBearVirtualGamepadManager.shared.applyToSeat(padSeat, event: empty)
        }
    }

    private func bindAll() {
        guard isActive else { return }
        for controller in GCController.controllers() {
            bind(controller)
        }
    }

    private func bind(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        pad.valueChangedHandler = { [weak self] gamepad, _ in
            guard let self, self.isActive else { return }
            let event = Self.snapshot(gamepad, seat: self.seat)
            let padSeat = self.seat
            Task {
                await GBearVirtualGamepadManager.shared.applyToSeat(padSeat, event: event)
            }
        }
    }

    nonisolated static func snapshot(_ pad: GCExtendedGamepad, seat: Int) -> GBearGamepadEventFormat.Event {
        var buttons: UInt32 = 0
        func set(_ bit: UInt32, _ pressed: Bool) {
            if pressed { buttons |= bit }
        }
        set(GBearGamepadEventFormat.Button.a, pad.buttonA.isPressed)
        set(GBearGamepadEventFormat.Button.b, pad.buttonB.isPressed)
        set(GBearGamepadEventFormat.Button.x, pad.buttonX.isPressed)
        set(GBearGamepadEventFormat.Button.y, pad.buttonY.isPressed)
        set(GBearGamepadEventFormat.Button.l1, pad.leftShoulder.isPressed)
        set(GBearGamepadEventFormat.Button.r1, pad.rightShoulder.isPressed)
        set(GBearGamepadEventFormat.Button.l3, pad.leftThumbstickButton?.isPressed == true)
        set(GBearGamepadEventFormat.Button.r3, pad.rightThumbstickButton?.isPressed == true)
        set(GBearGamepadEventFormat.Button.start, pad.buttonMenu.isPressed)
        if let options = pad.buttonOptions {
            set(GBearGamepadEventFormat.Button.select, options.isPressed)
        }
        if let home = pad.buttonHome {
            set(GBearGamepadEventFormat.Button.guide, home.isPressed)
        }
        set(GBearGamepadEventFormat.Button.dpadUp, pad.dpad.up.isPressed)
        set(GBearGamepadEventFormat.Button.dpadDown, pad.dpad.down.isPressed)
        set(GBearGamepadEventFormat.Button.dpadLeft, pad.dpad.left.isPressed)
        set(GBearGamepadEventFormat.Button.dpadRight, pad.dpad.right.isPressed)
        return GBearGamepadEventFormat.Event(
            seat: UInt8(seat),
            buttons: buttons,
            leftX: pad.leftThumbstick.xAxis.value,
            leftY: pad.leftThumbstick.yAxis.value,
            rightX: pad.rightThumbstick.xAxis.value,
            rightY: pad.rightThumbstick.yAxis.value,
            leftTrigger: pad.leftTrigger.value,
            rightTrigger: pad.rightTrigger.value
        )
    }
}

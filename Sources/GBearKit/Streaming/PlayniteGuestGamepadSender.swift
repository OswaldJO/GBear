import Foundation
import GameController
import Network

/// Sends this computer's GCController as `PNG1` to a remote GBear host.
final class PlayniteGuestGamepadSender: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let joinSeat: UInt8
    private var connection: NWConnection?
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "PlayniteGuest.pad")

    init(host: String, port: UInt16, joinSeat: Int) {
        self.host = host
        self.port = port
        self.joinSeat = UInt8(max(1, min(PlayniteStreamPorts.maxCoopViewers, joinSeat)))
    }

    func start() {
        stop()
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let params = NWParameters.udp
        let connection = NWConnection(to: endpoint, using: params)
        self.connection = connection
        connection.start(queue: queue)
        GCController.shouldMonitorBackgroundEvents = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.bindAll()
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.bindAll()
        })
        DispatchQueue.main.async { [weak self] in self?.bindAll() }
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
        }
        send(
            PlayniteGamepadEventFormat.Event(
                seat: joinSeat,
                buttons: 0,
                leftX: 0,
                leftY: 0,
                rightX: 0,
                rightY: 0,
                leftTrigger: 0,
                rightTrigger: 0
            )
        )
        connection?.cancel()
        connection = nil
    }

    private func bindAll() {
        for controller in GCController.controllers() {
            guard let pad = controller.extendedGamepad else { continue }
            pad.valueChangedHandler = { [weak self] gamepad, _ in
                guard let self else { return }
                self.send(PlayniteHostLocalGamepad.snapshot(gamepad, seat: Int(self.joinSeat)))
            }
        }
    }

    private func send(_ event: PlayniteGamepadEventFormat.Event) {
        let packet = PlayniteGamepadEventFormat.pack(
            seat: event.seat,
            buttons: event.buttons,
            leftX: event.leftX,
            leftY: event.leftY,
            rightX: event.rightX,
            rightY: event.rightY,
            leftTrigger: event.leftTrigger,
            rightTrigger: event.rightTrigger
        )
        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }
}



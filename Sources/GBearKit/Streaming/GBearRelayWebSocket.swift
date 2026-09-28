import Foundation

/// Outbound WebSocket used by both the host and the guest to reach the relay.
final class GBearRelayWebSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private var binaryHandler: (@Sendable (Data) -> Void)?
    private var textHandler: (@Sendable (String) -> Void)?
    private var openHandler: (@Sendable () -> Void)?
    private var closeHandler: (@Sendable (String) -> Void)?
    private var opened = false
    /// False while `close()` is tearing the socket down, so that cancel does not look like a drop.
    private var notifyClose = false

    func setHandlers(
        onBinary: (@Sendable (Data) -> Void)? = nil,
        onText: (@Sendable (String) -> Void)? = nil,
        onOpen: (@Sendable () -> Void)? = nil,
        onClose: (@Sendable (String) -> Void)? = nil
    ) {
        lock.lock()
        binaryHandler = onBinary
        textHandler = onText
        openHandler = onOpen
        closeHandler = onClose
        lock.unlock()
    }

    func connect(_ url: URL) {
        close()
        let configuration = URLSessionConfiguration.default
        // A short request timeout kills this socket when the other side is only sending.
        // The host mostly receives controller packets, so a quiet load screen used to
        // drop the session after 30s and nothing reconnected (BJ-097).
        configuration.timeoutIntervalForRequest = 24 * 60 * 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.timeoutInterval = 24 * 60 * 60
        notifyClose = true
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 8 * 1024 * 1024
        self.session = session
        self.task = task
        task.resume()
        receiveNext()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                self?.task?.sendPing { _ in }
            }
        }
    }

    func send(_ data: Data, completion: @escaping @Sendable () -> Void = {}) {
        guard let task else {
            completion()
            return
        }
        task.send(.data(data)) { _ in
            completion()
        }
    }

    func close() {
        notifyClose = false
        pingTask?.cancel()
        pingTask = nil
        let old = task
        task = nil
        old?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        session = nil
        opened = false
    }

    static func relayURL(base: URL, deviceID: String, sessionID: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        case "wss", "ws":
            break
        default:
            return nil
        }
        components.path = "/v1/ws"
        components.queryItems = [
            URLQueryItem(name: "deviceId", value: deviceID),
            URLQueryItem(name: "sessionId", value: sessionID),
            URLQueryItem(name: "mode", value: "relay"),
        ]
        return components.url
    }

    private func receiveNext() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self, self.task === task else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.emitBinary(data)
                case .string(let text):
                    self.emitText(text)
                @unknown default:
                    break
                }
                self.receiveNext()
            case .failure(let error):
                self.emitClose(error.localizedDescription)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        opened = true
        let handler = openHandler
        lock.unlock()
        handler?()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard webSocketTask === task else { return }
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "closed (\(closeCode.rawValue))"
        emitClose(text)
    }

    private func emitBinary(_ data: Data) {
        lock.lock()
        let handler = binaryHandler
        lock.unlock()
        handler?(data)
    }

    private func emitText(_ text: String) {
        lock.lock()
        let handler = textHandler
        lock.unlock()
        handler?(text)
    }

    private func emitClose(_ reason: String) {
        lock.lock()
        let handler = closeHandler
        let notify = notifyClose
        notifyClose = false
        opened = false
        lock.unlock()
        if notify {
            handler?(reason)
        }
    }
}

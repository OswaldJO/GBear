import Foundation
import Network

enum GBearNWListenerAwaitError: Error, LocalizedError {
    case readyTimeout(seconds: Double)
    case cancelledTimeout(seconds: Double)
    case failed(Error)

    var errorDescription: String? {
        switch self {
        case .readyTimeout(let seconds):
            return "listener did not become ready within \(seconds)s"
        case .cancelledTimeout(let seconds):
            return "listener did not cancel within \(seconds)s"
        case .failed(let error):
            return error.localizedDescription
        }
    }
}

enum GBearNWListenerAwait {
    /// Waits until [listener] reaches `.ready` (or fails) before returning from `start()`.
    static func waitUntilReady(_ listener: NWListener, timeoutSeconds: Double = 5) async throws {
        if listener.state == .ready { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            final class ReadyGate: @unchecked Sendable {
                var finished = false
            }
            let gate = ReadyGate()
            listener.stateUpdateHandler = { state in
                guard !gate.finished else { return }
                switch state {
                case .ready:
                    gate.finished = true
                    continuation.resume()
                case .failed(let error):
                    gate.finished = true
                    continuation.resume(throwing: GBearNWListenerAwaitError.failed(error))
                case .cancelled:
                    gate.finished = true
                    continuation.resume(throwing: GBearNWListenerAwaitError.failed(
                        NSError(domain: "GBearNWListener", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "listener cancelled before ready",
                        ])
                    ))
                default:
                    break
                }
            }
            if listener.state == .ready {
                gate.finished = true
                continuation.resume()
                return
            }
            Task {
                let nanos = UInt64(max(0.1, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                guard !gate.finished else { return }
                gate.finished = true
                continuation.resume(throwing: GBearNWListenerAwaitError.readyTimeout(seconds: timeoutSeconds))
            }
        }
    }

    /// After [listener.cancel], wait until state is `.cancelled` so the port can be rebound.
    static func waitUntilCancelled(_ listener: NWListener, timeoutSeconds: Double = 1) async {
        if listener.state == .cancelled { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            final class CancelGate: @unchecked Sendable {
                var finished = false
            }
            let gate = CancelGate()
            listener.stateUpdateHandler = { state in
                guard !gate.finished else { return }
                if state == .cancelled {
                    gate.finished = true
                    continuation.resume()
                }
            }
            if listener.state == .cancelled {
                gate.finished = true
                continuation.resume()
                return
            }
            Task {
                let nanos = UInt64(max(0.1, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                guard !gate.finished else { return }
                gate.finished = true
                continuation.resume()
            }
        }
    }
}

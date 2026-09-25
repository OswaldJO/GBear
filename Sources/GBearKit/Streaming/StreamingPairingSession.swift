import Foundation

/// Mac-side pairing: shows incoming companion requests with Pair / Deny.
@MainActor
@Observable
final class StreamingPairingSession {
    enum Phase: Equatable {
        case idle
        case paired(deviceName: String)
    }

    var phase: Phase = .idle
    var hostReachable = false
    var statusMessage = ""
    var lastError: String?

    private let hostManager: GBearStreamHostManager

    init(hostManager: GBearStreamHostManager = .shared) {
        self.hostManager = hostManager
    }

    func refreshHostStatus() {
        Task { @MainActor in
            await hostManager.ensureReady()
            hostReachable = await hostManager.ping() || hostManager.state == .running
            if hostManager.isVideoStreaming {
                statusMessage = "Streaming to the companion — audio is on the phone; Mac speakers are muted until the stream stops."
            } else {
                statusMessage = hostReachable
                    ? (hostManager.isCaptureReady
                        ? "Waiting for a device to request pairing from the companion app."
                        : (hostManager.needsScreenCaptureConsent
                            ? "Pairing host is up — allow Screen Recording before streaming (pairing works without it)."
                            : "Pairing host is up — restart the host to refresh capture."))
                    : hostManager.statusLine
            }
        }
    }

    func beginListeningForRequests() {
        hostManager.startWatchingPairingRequests()
        statusMessage = "When a phone taps Pair, approve it here."
    }

    func stopListeningForRequests() {
        hostManager.stopWatchingPairingRequests()
    }

    func approve(_ request: GBearStreamControlServer.PendingPairRequest) {
        Task { @MainActor in
            let ok = await hostManager.approvePairing(deviceID: request.deviceID)
            await hostManager.refreshPendingPairRequests()
            if ok {
                phase = .paired(deviceName: request.deviceName)
                statusMessage = "Paired with \(request.deviceName)."
            } else {
                lastError = "Could not approve pairing."
            }
        }
    }

    func deny(_ request: GBearStreamControlServer.PendingPairRequest) {
        Task { @MainActor in
            _ = await hostManager.denyPairing(deviceID: request.deviceID)
            await hostManager.refreshPendingPairRequests()
            statusMessage = "Denied pairing request from \(request.deviceName)."
        }
    }

    func disconnect() {
        phase = .idle
        statusMessage = ""
        lastError = nil
    }
}

import Foundation

/// Picks the relay video bitrate from control-channel ping round trips and dropped frames.
/// Pings ride the same WebSocket as the video, so a growing round trip means picture is queueing.
final class GBearRelayBitrateController: @unchecked Sendable {
    static let startBitRate = 6_000_000
    static let minBitRate = 2_000_000
    static let maxBitRate = 12_000_000
    /// Older guests do not answer pings, so there is no queue signal to climb safely past this.
    static let maxBitRateWithoutPings = 8_000_000

    private static let queueHighMillis = 250.0
    private static let queueLowMillis = 80.0
    private static let decreaseCooldown: TimeInterval = 2
    private static let increaseAfterStable: TimeInterval = 6
    private static let increaseAfterDrop: TimeInterval = 10
    private static let keyframeRequestInterval: TimeInterval = 1

    private let lock = NSLock()
    private var bitRate = startBitRate
    private var baselineRTT: Double?
    private var hasPongs = false
    private var lastChange: TimeInterval = 0
    private var lastDrop: TimeInterval = 0
    private var lastKeyframeRequest: TimeInterval = 0

    /// Called off the main actor with the new target in bits per second.
    var onBitRateChange: (@Sendable (Int) -> Void)?
    var onKeyframeNeeded: (@Sendable () -> Void)?

    var currentBitRate: Int {
        lock.lock()
        defer { lock.unlock() }
        return bitRate
    }

    func reset() {
        lock.lock()
        bitRate = Self.startBitRate
        baselineRTT = nil
        hasPongs = false
        lastChange = Self.now()
        lastDrop = 0
        lastKeyframeRequest = 0
        lock.unlock()
    }

    func pingMessage() -> [String: Any] {
        ["type": "ping", "t": Self.now() * 1000]
    }

    func handlePong(sentMillis: Double) {
        let now = Self.now()
        let rtt = now * 1000 - sentMillis
        guard rtt >= 0, rtt < 60_000 else { return }
        lock.lock()
        hasPongs = true
        // Creep the baseline up slowly so a route change does not look like a permanent queue.
        let baseline = min(rtt, (baselineRTT ?? rtt) + 2)
        baselineRTT = baseline
        let queue = rtt - baseline
        var change: Int?
        if queue > Self.queueHighMillis, now - lastChange > Self.decreaseCooldown {
            change = decreaseLocked(now: now)
        } else if queue < Self.queueLowMillis,
                  now - lastChange > Self.increaseAfterStable,
                  now - lastDrop > Self.increaseAfterDrop {
            change = increaseLocked(now: now, ceiling: Self.maxBitRate)
        }
        lock.unlock()
        if let change { onBitRateChange?(change) }
    }

    /// A video frame was dropped on this Mac or in the relay because the link fell behind.
    func handleDrop() {
        let now = Self.now()
        lock.lock()
        lastDrop = now
        let wantsKeyframe = now - lastKeyframeRequest > Self.keyframeRequestInterval
        if wantsKeyframe { lastKeyframeRequest = now }
        let change = now - lastChange > Self.decreaseCooldown ? decreaseLocked(now: now) : nil
        lock.unlock()
        if let change { onBitRateChange?(change) }
        if wantsKeyframe { onKeyframeNeeded?() }
    }

    /// Once a second. Lets the rate climb for guests that never answer pings.
    func tick() {
        let now = Self.now()
        lock.lock()
        var change: Int?
        if !hasPongs,
           now - lastChange > Self.increaseAfterStable * 2,
           now - lastDrop > Self.increaseAfterDrop * 1.5 {
            change = increaseLocked(now: now, ceiling: Self.maxBitRateWithoutPings)
        }
        lock.unlock()
        if let change { onBitRateChange?(change) }
    }

    private func decreaseLocked(now: TimeInterval) -> Int? {
        let next = max(Self.minBitRate, Int(Double(bitRate) * 0.7))
        guard next != bitRate else { return nil }
        bitRate = next
        lastChange = now
        return next
    }

    private func increaseLocked(now: TimeInterval, ceiling: Int) -> Int? {
        let next = min(ceiling, Int(Double(bitRate) * 1.12))
        guard next > bitRate else { return nil }
        bitRate = next
        lastChange = now
        return next
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

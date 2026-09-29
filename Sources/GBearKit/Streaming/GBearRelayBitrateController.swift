import Foundation

/// Picks the relay video bitrate from control-channel ping round trips and dropped frames.
/// Pings ride the same WebSocket as the video, so a growing round trip means picture is queueing.
/// The rate only climbs while the encoder actually sends close to the target: a still screen
/// proves nothing about the link, and a target raised during one floods it when the game gets busy.
final class GBearRelayBitrateController: @unchecked Sendable {
    static let startBitRate = 8_000_000
    static let minBitRate = 2_000_000
    static let maxBitRate = 16_000_000
    /// Older guests do not answer pings, so there is no queue signal to climb safely past this.
    static let maxBitRateWithoutPings = 8_000_000

    /// Audio shares the socket, so queueing shows up as audio delay; back off well before a second.
    private static let queueHighMillis = 150.0
    private static let queueSevereMillis = 500.0
    private static let queueLowMillis = 40.0
    /// Share of the target the encoder must actually send before the target may rise.
    private static let usedShareToClimb = 0.6
    private static let decreaseCooldown: TimeInterval = 2
    private static let increaseAfterStable: TimeInterval = 4
    private static let increaseAfterDrop: TimeInterval = 10
    private static let keyframeRequestInterval: TimeInterval = 1

    private let lock = NSLock()
    private var bitRate = startBitRate
    private var baselineRTT: Double?
    private var hasPongs = false
    private var lastChange: TimeInterval = 0
    private var lastDrop: TimeInterval = 0
    private var lastKeyframeRequest: TimeInterval = 0
    private var sentBytes = 0
    private var sentWindowStart: TimeInterval = 0
    /// Smoothed video bits per second handed to the relay.
    private var sentRate = 0.0

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
        sentBytes = 0
        sentWindowStart = Self.now()
        sentRate = 0
        lock.unlock()
    }

    /// Every encoded video frame bound for the relay, before any drop.
    func noteVideoSent(bytes: Int) {
        lock.lock()
        sentBytes += bytes
        lock.unlock()
    }

    func pingMessage() -> [String: Any] {
        ["type": "ping", "t": Self.now() * 1000]
    }

    /// Returns the round trip in milliseconds, or nil for a pong that makes no sense.
    @discardableResult
    func handlePong(sentMillis: Double) -> Double? {
        let now = Self.now()
        let rtt = now * 1000 - sentMillis
        guard rtt >= 0, rtt < 60_000 else { return nil }
        lock.lock()
        hasPongs = true
        // Creep the baseline up slowly so a route change does not look like a permanent queue.
        let baseline = min(rtt, (baselineRTT ?? rtt) + 2)
        baselineRTT = baseline
        let queue = rtt - baseline
        updateSentRateLocked(now: now)
        var change: Int?
        if queue > Self.queueSevereMillis, now - lastChange > Self.decreaseCooldown {
            change = decreaseLocked(now: now, factor: 0.5)
        } else if queue > Self.queueHighMillis, now - lastChange > Self.decreaseCooldown {
            change = decreaseLocked(now: now)
        } else if queue < Self.queueLowMillis,
                  now - lastChange > Self.increaseAfterStable,
                  now - lastDrop > Self.increaseAfterDrop,
                  isUsingTargetLocked {
            change = increaseLocked(now: now, ceiling: Self.maxBitRate)
        }
        lock.unlock()
        if let change { onBitRateChange?(change) }
        return rtt
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
        if !hasPongs { updateSentRateLocked(now: now) }
        if !hasPongs,
           now - lastChange > Self.increaseAfterStable * 2,
           now - lastDrop > Self.increaseAfterDrop * 1.5,
           isUsingTargetLocked {
            change = increaseLocked(now: now, ceiling: Self.maxBitRateWithoutPings)
        }
        lock.unlock()
        if let change { onBitRateChange?(change) }
    }

    private var isUsingTargetLocked: Bool {
        sentRate >= Double(bitRate) * Self.usedShareToClimb
    }

    private func updateSentRateLocked(now: TimeInterval) {
        let elapsed = now - sentWindowStart
        guard elapsed >= 0.5 else { return }
        let rate = Double(sentBytes * 8) / elapsed
        // About a two-second memory, so one keyframe or one quiet second does not decide it.
        sentRate = sentRate == 0 ? rate : sentRate * 0.5 + rate * 0.5
        sentBytes = 0
        sentWindowStart = now
    }

    private func decreaseLocked(now: TimeInterval, factor: Double = 0.7) -> Int? {
        let next = max(Self.minBitRate, Int(Double(bitRate) * factor))
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

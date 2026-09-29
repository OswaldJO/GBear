import Foundation

/// One row per second of a capture session, saved to Downloads as CSV when the capture stops.
/// Idle seconds are kept as zero rows so still screens and stalls show up in the data.
struct GBearBitrateLog {
    private struct Sample {
        let time: Date
        let elapsed: Double
        let measured: Int
        let target: Int
        let frames: Int
        let keyframes: Int
        let bytes: Int
        let maxFrameBytes: Int
        let lanViewers: Int
        let lanDropped: Int
        let relayActive: Bool
        let relayRoundTripMillis: Double?
        let events: String
    }

    private let startedAt = Date()
    private let width: Int
    private let height: Int
    private let fps: Int
    private let tuning: GBearVideoTuning
    private var samples: [Sample] = []

    private var windowStart = Date()
    private var frames = 0
    private var keyframes = 0
    private var bytes = 0
    private var maxFrameBytes = 0
    private var lanDropped = 0
    private var relayRoundTripMillis: Double?
    /// Event text → count within the current second, in first-seen order.
    private var events: [(String, Int)] = []

    init(width: Int, height: Int, fps: Int, tuning: GBearVideoTuning) {
        self.width = width
        self.height = height
        self.fps = fps
        self.tuning = tuning
    }

    mutating func recordFrame(bytes count: Int, keyframe: Bool) {
        frames += 1
        if keyframe { keyframes += 1 }
        bytes += count
        maxFrameBytes = max(maxFrameBytes, count)
    }

    mutating func recordLANDrops(_ count: Int) {
        lanDropped += count
    }

    /// Several friends answer pings each second; the slowest round trip is the one that limits the picture.
    mutating func recordRelayRoundTrip(millis: Double) {
        relayRoundTripMillis = max(relayRoundTripMillis ?? 0, millis)
    }

    mutating func note(_ event: String) {
        if let index = events.firstIndex(where: { $0.0 == event }) {
            events[index].1 += 1
        } else {
            events.append((event, 1))
        }
    }

    mutating func closeSecond(target: Int, lanViewers: Int, relayActive: Bool) {
        let now = Date()
        let interval = max(now.timeIntervalSince(windowStart), 0.001)
        let eventText = events.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: "; ")
        samples.append(Sample(
            time: now,
            elapsed: now.timeIntervalSince(startedAt),
            measured: Int(Double(bytes * 8) / interval),
            target: target,
            frames: frames,
            keyframes: keyframes,
            bytes: bytes,
            maxFrameBytes: maxFrameBytes,
            lanViewers: lanViewers,
            lanDropped: lanDropped,
            relayActive: relayActive,
            relayRoundTripMillis: relayRoundTripMillis,
            events: eventText
        ))
        windowStart = now
        frames = 0
        keyframes = 0
        bytes = 0
        maxFrameBytes = 0
        lanDropped = 0
        relayRoundTripMillis = nil
        events = []
    }

    var isWorthSaving: Bool { samples.count >= 2 }

    /// Writes `GBear bitrate <date>.csv` into [directory] and returns its URL.
    func write(to directory: URL) throws -> URL {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = directory.appendingPathComponent("GBear bitrate \(stamp.string(from: startedAt)).csv")
        try csv().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func csv() -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm:ss"

        let measured = samples.map(\.measured).sorted()
        let targets = samples.map(\.target)
        let totalBytes = samples.reduce(0) { $0 + $1.bytes }
        let duration = samples.last?.elapsed ?? 0
        let roundTrips = samples.compactMap(\.relayRoundTripMillis).sorted()
        func kbps(_ value: Int) -> String { String(value / 1000) }
        func percentile(_ sorted: [Int], _ p: Double) -> Int {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        let average = measured.isEmpty ? 0 : measured.reduce(0, +) / measured.count
        let averageTarget = targets.isEmpty ? 0 : targets.reduce(0, +) / targets.count
        let tuningName = tuning == .relay ? "remote co-op (relay)" : "Wi-Fi (lan)"

        var lines = [
            "# GBear bitrate log",
            "# started \(clock.string(from: startedAt)), duration \(Int(duration)) s, \(samples.count) samples (1 per second)",
            "# capture \(width)x\(height) @ \(fps) fps, \(tuningName)",
            "# measured kbps: average \(kbps(average)), median \(kbps(percentile(measured, 0.5))), p95 \(kbps(percentile(measured, 0.95))), peak \(kbps(measured.last ?? 0))",
            "# target kbps: average \(kbps(averageTarget)), min \(kbps(targets.min() ?? 0)), max \(kbps(targets.max() ?? 0))",
            String(
                format: "# total %.1f MB, %d frames, %d keyframes, %d LAN frames dropped",
                Double(totalBytes) / 1_000_000,
                samples.reduce(0) { $0 + $1.frames },
                samples.reduce(0) { $0 + $1.keyframes },
                samples.reduce(0) { $0 + $1.lanDropped }
            ),
        ]
        if !roundTrips.isEmpty {
            lines.append(String(
                format: "# relay round trip ms: median %.0f, p95 %.0f, max %.0f",
                roundTrips[roundTrips.count / 2],
                roundTrips[min(roundTrips.count - 1, Int(Double(roundTrips.count - 1) * 0.95))],
                roundTrips.last ?? 0
            ))
        }
        lines.append(
            "time,elapsed_s,measured_kbps,target_kbps,frames,keyframes,bytes,max_frame_bytes," +
                "lan_viewers,lan_dropped_frames,relay,relay_rtt_ms,events"
        )
        for sample in samples {
            let rtt = sample.relayRoundTripMillis.map { String(format: "%.0f", $0) } ?? ""
            let events = sample.events.isEmpty ? "" : "\"\(sample.events.replacingOccurrences(of: "\"", with: "'"))\""
            lines.append([
                time.string(from: sample.time),
                String(format: "%.1f", sample.elapsed),
                kbps(sample.measured),
                kbps(sample.target),
                String(sample.frames),
                String(sample.keyframes),
                String(sample.bytes),
                String(sample.maxFrameBytes),
                String(sample.lanViewers),
                String(sample.lanDropped),
                sample.relayActive ? "1" : "0",
                rtt,
                events,
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

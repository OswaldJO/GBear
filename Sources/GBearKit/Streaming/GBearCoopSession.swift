import Foundation

/// Who occupies a couch co-op slot.
enum GBearCoopClientKind: String, Sendable, Codable, Equatable {
    /// This Mac is playing locally (no video client; feeds a virtual pad from GCController).
    case localHost
    /// Phone companion app (receives video, sends GBG1).
    case companion
    /// Another computer running GBear as a stream guest.
    case computerGuest

    var wantsVideo: Bool { self != .localHost }

    var displayLabel: String {
        switch self {
        case .localHost: return "This Mac"
        case .companion: return "Phone"
        case .computerGuest: return "Computer"
        }
    }
}

/// One player slot (1…8). `joinSeat` is the GBG1 tag frozen at join; `seat` is the current virtual pad.
struct GBearCoopSeat: Sendable, Equatable, Identifiable {
    let deviceID: String
    let deviceName: String
    /// Current virtual pad / player number (1…maxSeats). Reassignable after join.
    let seat: Int
    /// Seat written into GBG1 by this client. Host remaps joinSeat → seat.
    let joinSeat: Int
    let kind: GBearCoopClientKind
    let joinedAt: Date

    var id: String { deviceID }

    var wantsVideo: Bool { kind.wantsVideo }

    var json: [String: Any] {
        [
            "deviceId": deviceID,
            "name": deviceName,
            "seat": seat,
            "joinSeat": joinSeat,
            "kind": kind.rawValue,
            "wantsVideo": wantsVideo,
            "joinedAt": ISO8601DateFormatter().string(from: joinedAt),
        ]
    }

    func with(seat: Int) -> GBearCoopSeat {
        GBearCoopSeat(
            deviceID: deviceID,
            deviceName: deviceName,
            seat: seat,
            joinSeat: joinSeat,
            kind: kind,
            joinedAt: joinedAt
        )
    }
}

/// In-memory co-op session on the Mac stream host (LAN; WAN uses the same seat model).
///
/// Default assignment is **join order**, except Player 1 is reserved for the host player
/// (`hostPlayerDeviceID`) until they join. After people are seated, `reassign` swaps slots.
struct GBearCoopSessionState: Sendable, Equatable {
    var sessionID: String
    var createdAt: Date
    var seats: [GBearCoopSeat]
    /// Device allowed to drive Mac pointer (`GBI1`). Default first video client or seat 1.
    var cursorOwnerDeviceID: String?
    /// Who owns the host-player identity (this Mac, or a companion standing in for the host).
    var hostPlayerDeviceID: String = GBearCoopSessionState.localHostDeviceID

    static let maxSeats = GBearStreamPorts.maxCoopViewers
    static let localHostDeviceID = "host-local"

    var json: [String: Any] {
        [
            "sessionId": sessionID,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "cursorOwnerDeviceId": cursorOwnerDeviceID as Any,
            "hostPlayerDeviceId": hostPlayerDeviceID,
            "hostPlayerSeated": seat(for: hostPlayerDeviceID) != nil,
            "localHostPlaying": localHostIsPlaying,
            "remotePlayers": remotePlayerCount,
            "maxRemotePlayers": maxRemotePlayers,
            "maxSeats": Self.maxSeats,
            "seats": seats.map(\.json),
            "openSeats": max(0, Self.maxSeats - seats.count),
            "capacityNote": capacityNote,
        ]
    }

    /// Eight pads total. This Mac counts as a player when it is playing, so only 7 devices can join.
    /// Eight devices can join only when one of them plays as the host instead of this Mac.
    static let slotCapacityExplanation =
        "At most 8 players. This Mac uses one slot when it is playing, so 7 devices can join. " +
        "An 8th device can join only if it plays as the host in place of this Mac " +
        "(this Mac then leaves the pad list)."

    var localHostIsPlaying: Bool {
        seat(for: Self.localHostDeviceID) != nil
    }

    var remotePlayerCount: Int {
        seats.filter { $0.kind != .localHost }.count
    }

    /// Remotes allowed while the current host-player choice holds.
    var maxRemotePlayers: Int {
        if hostPlayerDeviceID == Self.localHostDeviceID || localHostIsPlaying {
            return Self.maxSeats - 1
        }
        return Self.maxSeats
    }

    var capacityNote: String {
        if hostPlayerDeviceID == Self.localHostDeviceID || localHostIsPlaying {
            return "8 slots: this Mac + up to 7 devices. An 8th device can join only by playing as the host instead of this Mac."
        }
        return "8 slots: this Mac is not playing, so up to 8 devices can join. Player 1 is the host companion."
    }

    var joinFullMessage: String {
        if localHostIsPlaying || hostPlayerDeviceID == Self.localHostDeviceID {
            return "Session full (8 players: this Mac + 7 devices). An 8th device can join only if it plays as the host instead of this Mac."
        }
        if reservedHostSeat != nil, seats.count >= Self.maxSeats - 1 {
            return "Session full (7 devices in Player 2–8; Player 1 is reserved for the host companion). The 8th device must play as the host."
        }
        return "Session full (8 players)."
    }

    /// GBG1 joinSeat → current virtual pad.
    var joinSeatTranslation: [UInt8: UInt8] {
        Dictionary(uniqueKeysWithValues: seats.map { (UInt8($0.joinSeat), UInt8($0.seat)) })
    }

    var occupiedSeats: Set<Int> {
        Set(seats.map(\.seat))
    }

    var videoClientCount: Int {
        seats.filter(\.wantsVideo).count
    }

    /// Player 1 is held for the host until they occupy any slot (then join order fills the rest).
    var reservedHostSeat: Int? {
        seat(for: hostPlayerDeviceID) == nil ? 1 : nil
    }

    func seat(for deviceID: String) -> GBearCoopSeat? {
        seats.first { $0.deviceID == deviceID }
    }

    func occupant(seat number: Int) -> GBearCoopSeat? {
        seats.first { $0.seat == number }
    }

    static func isValidSeat(_ value: Int) -> Bool {
        (1 ... maxSeats).contains(value)
    }

    /// Point the host-player identity at a device. If that device is already seated, move them to P1.
    /// Switching off this Mac drops the local pad so a companion can take Player 1.
    mutating func designateHostPlayer(deviceID: String) {
        hostPlayerDeviceID = deviceID
        if deviceID != Self.localHostDeviceID {
            _ = leave(deviceID: Self.localHostDeviceID)
        }
        if seat(for: deviceID) != nil, occupant(seat: 1)?.deviceID != deviceID {
            _ = reassign(deviceID: deviceID, toSeat: 1)
        }
    }

    /// Claim Player 1 for this Mac when it is the host player and not yet seated.
    mutating func seatLocalHostIfNeeded(deviceName: String) {
        guard hostPlayerDeviceID == Self.localHostDeviceID else { return }
        guard seat(for: Self.localHostDeviceID) == nil else { return }
        _ = join(
            deviceID: Self.localHostDeviceID,
            deviceName: deviceName,
            preferredSeat: 1,
            kind: .localHost
        )
    }

    mutating func join(
        deviceID: String,
        deviceName: String,
        preferredSeat: Int?,
        kind: GBearCoopClientKind = .companion,
        playAsHost: Bool = false
    ) -> Result<GBearCoopSeat, JoinError> {
        let previousHost = hostPlayerDeviceID
        if playAsHost {
            designateHostPlayer(deviceID: deviceID)
        }
        let result: Result<GBearCoopSeat, JoinError>
        if deviceID == hostPlayerDeviceID {
            result = assignHostSeat(deviceID: deviceID, deviceName: deviceName, kind: kind)
        } else if let existing = seat(for: deviceID) {
            result = .success(existing)
        } else if seats.count >= Self.maxSeats {
            result = .failure(.full)
        } else {
            var blocked = occupiedSeats
            if let reserved = reservedHostSeat {
                blocked.insert(reserved)
            }
            let seatNumber: Int
            if let preferred = preferredSeat, Self.isValidSeat(preferred), !blocked.contains(preferred) {
                seatNumber = preferred
            } else if let free = (1 ... Self.maxSeats).first(where: { !blocked.contains($0) }) {
                seatNumber = free
            } else {
                seatNumber = -1
            }
            if seatNumber < 1 {
                result = .failure(.full)
            } else {
                result = appendSeat(
                    deviceID: deviceID,
                    deviceName: deviceName,
                    seatNumber: seatNumber,
                    kind: kind
                )
            }
        }
        if case .failure = result, playAsHost {
            hostPlayerDeviceID = previousHost
        }
        return result
    }

    mutating func leave(deviceID: String) -> Bool {
        let before = seats.count
        seats.removeAll { $0.deviceID == deviceID }
        if cursorOwnerDeviceID == deviceID {
            cursorOwnerDeviceID = seats.first(where: \.wantsVideo)?.deviceID
                ?? seats.first(where: { $0.seat == 1 })?.deviceID
                ?? seats.first?.deviceID
        }
        return seats.count < before
    }

    mutating func reassign(deviceID: String, toSeat: Int) -> Result<GBearCoopSeat, JoinError> {
        guard Self.isValidSeat(toSeat) else { return .failure(.invalidSeat) }
        guard let index = seats.firstIndex(where: { $0.deviceID == deviceID }) else {
            return .failure(.notInSession)
        }
        if let other = seats.firstIndex(where: { $0.seat == toSeat && $0.deviceID != deviceID }) {
            seats[other] = seats[other].with(seat: seats[index].seat)
        }
        seats[index] = seats[index].with(seat: toSeat)
        return .success(seats[index])
    }

    enum JoinError: Error {
        case full
        case invalidSeat
        case notInSession
    }

    /// Host player always sits at Player 1 on join (bumps whoever is there into the next free seat).
    private mutating func assignHostSeat(
        deviceID: String,
        deviceName: String,
        kind: GBearCoopClientKind
    ) -> Result<GBearCoopSeat, JoinError> {
        if seat(for: deviceID) != nil {
            if occupant(seat: 1)?.deviceID != deviceID {
                _ = reassign(deviceID: deviceID, toSeat: 1)
            }
            if let seated = seat(for: deviceID) {
                return .success(seated)
            }
        }
        guard seats.count < Self.maxSeats else {
            return .failure(.full)
        }
        if let other = occupant(seat: 1), other.deviceID != deviceID {
            let taken = occupiedSeats
            guard let free = (2 ... Self.maxSeats).first(where: { !taken.contains($0) }) else {
                return .failure(.full)
            }
            _ = reassign(deviceID: other.deviceID, toSeat: free)
        }
        return appendSeat(
            deviceID: deviceID,
            deviceName: deviceName,
            seatNumber: 1,
            kind: kind
        )
    }

    private mutating func appendSeat(
        deviceID: String,
        deviceName: String,
        seatNumber: Int,
        kind: GBearCoopClientKind
    ) -> Result<GBearCoopSeat, JoinError> {
        let seat = GBearCoopSeat(
            deviceID: deviceID,
            deviceName: deviceName,
            seat: seatNumber,
            joinSeat: seatNumber,
            kind: kind,
            joinedAt: Date()
        )
        seats.append(seat)
        if cursorOwnerDeviceID == nil, seat.wantsVideo {
            cursorOwnerDeviceID = deviceID
        }
        return .success(seat)
    }
}

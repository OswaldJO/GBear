import Foundation

/// Couch co-op seats for up to two companion viewers on one capture session.
struct PlayniteCoopSeat: Sendable, Equatable, Identifiable {
    let deviceID: String
    let deviceName: String
    /// 1 or 2
    let seat: Int
    let joinedAt: Date

    var id: String { deviceID }

    var json: [String: Any] {
        [
            "deviceId": deviceID,
            "name": deviceName,
            "seat": seat,
            "joinedAt": ISO8601DateFormatter().string(from: joinedAt),
        ]
    }
}

/// In-memory co-op session on the Mac stream host (LAN; WAN uses the same seat model).
struct PlayniteCoopSessionState: Sendable, Equatable {
    var sessionID: String
    var createdAt: Date
    var seats: [PlayniteCoopSeat]
    /// Device allowed to drive Mac pointer (`PNI1`). Default seat 1.
    var cursorOwnerDeviceID: String?

    static let maxSeats = 2

    var json: [String: Any] {
        [
            "sessionId": sessionID,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "cursorOwnerDeviceId": cursorOwnerDeviceID as Any,
            "seats": seats.map(\.json),
            "openSeats": max(0, Self.maxSeats - seats.count),
        ]
    }

    func seat(for deviceID: String) -> PlayniteCoopSeat? {
        seats.first { $0.deviceID == deviceID }
    }

    mutating func join(deviceID: String, deviceName: String, preferredSeat: Int?) -> Result<PlayniteCoopSeat, JoinError> {
        if let existing = seat(for: deviceID) {
            return .success(existing)
        }
        guard seats.count < Self.maxSeats else {
            return .failure(.full)
        }
        let taken = Set(seats.map(\.seat))
        let seatNumber: Int
        if let preferred = preferredSeat, (preferred == 1 || preferred == 2), !taken.contains(preferred) {
            seatNumber = preferred
        } else if !taken.contains(1) {
            seatNumber = 1
        } else {
            seatNumber = 2
        }
        let seat = PlayniteCoopSeat(
            deviceID: deviceID,
            deviceName: deviceName,
            seat: seatNumber,
            joinedAt: Date()
        )
        seats.append(seat)
        if cursorOwnerDeviceID == nil, seatNumber == 1 {
            cursorOwnerDeviceID = deviceID
        }
        return .success(seat)
    }

    mutating func leave(deviceID: String) -> Bool {
        let before = seats.count
        seats.removeAll { $0.deviceID == deviceID }
        if cursorOwnerDeviceID == deviceID {
            cursorOwnerDeviceID = seats.first(where: { $0.seat == 1 })?.deviceID ?? seats.first?.deviceID
        }
        return seats.count < before
    }

    mutating func reassign(deviceID: String, toSeat: Int) -> Result<PlayniteCoopSeat, JoinError> {
        guard toSeat == 1 || toSeat == 2 else { return .failure(.invalidSeat) }
        guard let index = seats.firstIndex(where: { $0.deviceID == deviceID }) else {
            return .failure(.notInSession)
        }
        if let other = seats.firstIndex(where: { $0.seat == toSeat && $0.deviceID != deviceID }) {
            let swapped = seats[other]
            seats[other] = PlayniteCoopSeat(
                deviceID: swapped.deviceID,
                deviceName: swapped.deviceName,
                seat: seats[index].seat,
                joinedAt: swapped.joinedAt
            )
        }
        let current = seats[index]
        let updated = PlayniteCoopSeat(
            deviceID: current.deviceID,
            deviceName: current.deviceName,
            seat: toSeat,
            joinedAt: current.joinedAt
        )
        seats[index] = updated
        return .success(updated)
    }

    enum JoinError: Error {
        case full
        case invalidSeat
        case notInSession
    }
}

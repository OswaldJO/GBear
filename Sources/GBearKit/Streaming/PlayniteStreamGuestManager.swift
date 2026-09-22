import AVFoundation
import CoreMedia
import Foundation
import SwiftUI

/// Computer-to-computer guest: pair with a host Mac, receive video/audio, send local pads as PNG1.
@MainActor
@Observable
final class PlayniteStreamGuestManager {
    static let shared = PlayniteStreamGuestManager()

    enum Phase: Equatable {
        case idle
        case pairing
        case connected
        case streaming
        case failed(String)
    }

    var hostAddress: String = ""
    var preferredSeat: Int = 0
    var phase: Phase = .idle
    var statusMessage: String = "Enter a host LAN IP to join as a computer guest."
    var assignedSeat: Int = 1
    var latestSample: CMSampleBuffer?

    private let video = PlayniteVideoStreamClient()
    private let audio = PlayniteAudioStreamClient()
    private var padSender: PlayniteGuestGamepadSender?
    private var deviceID: String {
        let key = "gbear.guest.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    private var deviceName: String {
        "\(ProcessInfo.processInfo.hostName) (computer)"
    }

    func pairAndJoin() async {
        let host = hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            phase = .failed("Enter the host Mac’s LAN IP.")
            return
        }
        phase = .pairing
        statusMessage = "Asking host to pair…"
        do {
            _ = try await post(host: host, path: "/playnite/v1/pair/request", body: [
                "deviceId": deviceID,
                "deviceName": deviceName,
                "clientKind": PlayniteCoopClientKind.computerGuest.rawValue,
            ])
            let deadline = Date().addingTimeInterval(5 * 60)
            while Date() < deadline {
                let status = try await getStatus(host: host, deviceID: deviceID)
                if status == "paired" {
                    phase = .connected
                    statusMessage = "Paired. Starting stream…"
                    await startStream(host: host)
                    return
                }
                if status == "denied" {
                    phase = .failed("Host denied pairing.")
                    return
                }
                statusMessage = "Waiting for approval on the host Mac…"
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            phase = .failed("Timed out waiting for host to approve pairing.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        padSender?.stop()
        padSender = nil
        video.stop()
        audio.stop()
        latestSample = nil
        let host = hostAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty {
            _ = try? await post(host: host, path: "/playnite/v1/stream/stop", body: ["deviceId": deviceID])
        }
        if phase == .streaming || phase == .connected || phase == .pairing {
            phase = .idle
            statusMessage = "Disconnected."
        }
    }

    private func startStream(host: String) async {
        do {
            var body: [String: Any] = [
                "deviceId": deviceID,
                "deviceName": deviceName,
                "clientKind": PlayniteCoopClientKind.computerGuest.rawValue,
                "width": 1920,
                "height": 1080,
                "fps": 60,
            ]
            if preferredSeat >= 1 {
                body["preferredSeat"] = preferredSeat
            }
            let json = try await post(host: host, path: "/playnite/v1/stream/start", body: body)
            guard json["ok"] as? Bool == true else {
                phase = .failed(json["error"] as? String ?? "Stream start failed.")
                return
            }
            let seat = json["seat"] as? Int ?? 1
            assignedSeat = seat
            let videoPort = UInt16(json["videoPort"] as? Int ?? Int(PlayniteStreamPorts.videoTCP))
            let audioPort = UInt16(json["audioTcpPort"] as? Int ?? Int(PlayniteStreamPorts.audioTCP))
            let inputPort = UInt16(json["inputPort"] as? Int ?? Int(PlayniteStreamPorts.inputUDP))
            video.onSampleBuffer = { [weak self] sample in
                Task { @MainActor in
                    self?.latestSample = sample
                }
            }
            video.onEnded = { [weak self] reason in
                Task { @MainActor in
                    self?.statusMessage = "Video ended (\(reason))"
                }
            }
            video.start(host: host, port: videoPort)
            audio.start(host: host, port: audioPort)
            let sender = PlayniteGuestGamepadSender(host: host, port: inputPort, joinSeat: seat)
            sender.start()
            padSender = sender
            phase = .streaming
            statusMessage = "Playing as Player \(seat) on \(host)"
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func getStatus(host: String, deviceID: String) async throws -> String {
        let url = URL(string: "http://\(host):\(PlayniteStreamPorts.controlHTTP)/playnite/v1/pair/status?deviceId=\(deviceID)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["status"] as? String ?? "unknown"
    }

    @discardableResult
    private func post(host: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = URL(string: "http://\(host):\(PlayniteStreamPorts.controlHTTP)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status == 409 {
            throw NSError(
                domain: "PlayniteGuest",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: json["error"] as? String ?? "Session full"]
            )
        }
        if status == 403 {
            throw NSError(domain: "PlayniteGuest", code: status, userInfo: [NSLocalizedDescriptionKey: "Not paired with host."])
        }
        return json
    }
}

import Foundation

/// Client for the hosted GBear session coordinator (auth, invites, signaling, TURN).
@MainActor
@Observable
final class GBearSessionCoordinatorClient {
    static let shared = GBearSessionCoordinatorClient()

    private(set) var baseURL: URL = URL(string: "http://127.0.0.1:8787")!
    private(set) var idToken: String?
    private(set) var email: String?
    private(set) var remoteSessionID: String?
    private(set) var lastInviteCode: String?
    private(set) var lastError: String?
    private(set) var iceServers: [[String: Any]] = []

    private let deviceIDKey = "gbear.session.hostDeviceId"

    var hostDeviceID: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: deviceIDKey)
        return created
    }

    func configure(baseURLString: String) {
        if let url = URL(string: baseURLString) {
            baseURL = url
        }
    }

    /// Dev path: `dev:you@gmail.com`. Production: Google ID token string.
    func signIn(idToken: String) async -> Bool {
        self.idToken = idToken
        lastError = nil
        do {
            let body: [String: Any] = [
                "deviceId": hostDeviceID,
                "deviceName": ProcessInfo.processInfo.hostName,
                "role": "host",
            ]
            let json = try await postJSON(path: "/v1/auth/register-device", body: body)
            email = json["email"] as? String
            return json["ok"] as? Bool == true
        } catch {
            lastError = error.localizedDescription
            idToken = nil
            return false
        }
    }

    func createRemoteSession() async -> String? {
        guard idToken != nil else {
            lastError = "Sign in first"
            return nil
        }
        do {
            let json = try await postJSON(path: "/v1/session/create", body: [
                "hostDeviceId": hostDeviceID,
                "hostName": ProcessInfo.processInfo.hostName,
            ])
            let session = json["session"] as? [String: Any]
            remoteSessionID = session?["sessionId"] as? String
            return remoteSessionID
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func mintInvite() async -> String? {
        guard let remoteSessionID else {
            lastError = "No remote session"
            return nil
        }
        do {
            let json = try await postJSON(path: "/v1/session/invite", body: [
                "sessionId": remoteSessionID,
            ])
            let code = json["inviteCode"] as? String
            lastInviteCode = code
            return code
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func refreshTURNCredentials() async {
        guard idToken != nil else { return }
        do {
            let json = try await postJSON(path: "/v1/turn/credentials", body: [:])
            iceServers = (json["iceServers"] as? [[String: Any]]) ?? []
        } catch {
            lastError = error.localizedDescription
        }
    }

    func postSignal(toDeviceID: String, payload: [String: Any]) async {
        guard let remoteSessionID else { return }
        _ = try? await postJSON(path: "/v1/signal", body: [
            "sessionId": remoteSessionID,
            "fromDeviceId": hostDeviceID,
            "toDeviceId": toDeviceID,
            "payload": payload,
        ])
    }

    func endRemoteSession() async {
        guard let remoteSessionID else { return }
        _ = try? await postJSON(path: "/v1/session/end", body: ["sessionId": remoteSessionID])
        self.remoteSessionID = nil
        lastInviteCode = nil
    }

    private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let token = idToken else {
            throw NSError(domain: "GBearSession", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "Not signed in",
            ])
        }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "GBearSession", code: -1)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200 ..< 300).contains(http.statusCode) else {
            let message = json["error"] as? String ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "GBearSession", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        return json
    }
}

import Foundation
import Security

/// Steam sign-in the way the Steam client does it (`IAuthenticationService`): account name + password with Steam Guard,
/// or a QR code approved in the Steam Mobile app. Ends with a refresh token that later mints access tokens for the Web API.
enum SteamAuth {
    /// `EAuthSessionGuardType`
    enum Confirmation: Int, Sendable {
        case none = 1
        case emailCode = 2
        case deviceCode = 3
        case deviceConfirmation = 4
        case emailConfirmation = 5
        case machineToken = 6
    }

    struct Session: Sendable, Equatable {
        var clientID: String
        var requestID: String
        var steamID: String?
        var interval: Double
        var confirmations: [Confirmation]
        var emailDomain: String?
        var challengeURL: String?
    }

    struct Tokens: Sendable {
        var refreshToken: String
        var accessToken: String?
        var accountName: String?
    }

    enum PollResult: Sendable {
        case pending(Session)
        case done(Tokens)
    }

    private static let base = "https://api.steampowered.com/IAuthenticationService/"
    private static let deviceName = "GBear on \(Host.current().localizedName ?? "Mac")"
    /// `EAuthTokenPlatformType_MobileApp`. Only MobileApp refresh tokens can be renewed through
    /// `GenerateAccessTokenForApp` over the Web API; WebBrowser tokens get AccessDenied (15) there.
    private static let platformType = "3"

    private static var deviceFields: [String: String] {
        [
            "device_friendly_name": deviceName,
            "platform_type": platformType,
            "device_details[device_friendly_name]": deviceName,
            "device_details[platform_type]": platformType,
            "device_details[os_type]": "-500",
            "device_details[gaming_device_type]": "528",
        ]
    }

    // MARK: Begin

    static func beginWithCredentials(accountName: String, password: String) async throws -> Session {
        let key = try await call("GetPasswordRSAPublicKey", fields: ["account_name": accountName], get: true)
        guard let modulus = key["publickey_mod"] as? String,
              let exponent = key["publickey_exp"] as? String,
              let timestamp = key["timestamp"] as? String else {
            throw StorefrontError.decoding("Steam")
        }
        let encrypted = try encryptPassword(password, modulusHex: modulus, exponentHex: exponent)
        let response = try await call("BeginAuthSessionViaCredentials", fields: deviceFields.merging([
            "account_name": accountName,
            "encrypted_password": encrypted,
            "encryption_timestamp": timestamp,
            "remember_login": "true",
            "persistence": "1",
            "website_id": "Mobile",
        ]) { $1 })
        return try session(from: response)
    }

    static func beginWithQR() async throws -> Session {
        let response = try await call("BeginAuthSessionViaQR", fields: deviceFields)
        return try session(from: response)
    }

    static func submitCode(_ code: String, type: Confirmation, session: Session) async throws {
        guard let steamID = session.steamID else { throw StorefrontError.signInFailed("Steam did not return an account for this sign-in.") }
        do {
            _ = try await call("UpdateAuthSessionWithSteamGuardCode", fields: [
                "client_id": session.clientID,
                "steamid": steamID,
                "code": code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                "code_type": String(type.rawValue),
            ])
        } catch SteamAuthError.result(29) {
            // DuplicateRequest: this code was already accepted.
        }
    }

    static func poll(_ session: Session) async throws -> PollResult {
        let response = try await call("PollAuthSessionStatus", fields: [
            "client_id": session.clientID,
            "request_id": session.requestID,
        ])
        if let refresh = response["refresh_token"] as? String, !refresh.isEmpty {
            return .done(Tokens(
                refreshToken: refresh,
                accessToken: response["access_token"] as? String,
                accountName: response["account_name"] as? String
            ))
        }
        var next = session
        if let newClient = response["new_client_id"] as? String, !newClient.isEmpty { next.clientID = newClient }
        if let newURL = response["new_challenge_url"] as? String, !newURL.isEmpty { next.challengeURL = newURL }
        return .pending(next)
    }

    // MARK: Signed-in state

    /// Saves the refresh token, SteamID and display name.
    static func completeSignIn(_ tokens: Tokens) async throws {
        guard let steamID = steamID(fromJWT: tokens.refreshToken) else {
            throw StorefrontError.signInFailed("Steam sign-in finished without an account ID.")
        }
        StorefrontCredentials.setRefreshToken(tokens.refreshToken, for: .steam)
        StorefrontCredentials.steamAccessToken = tokens.accessToken
        StorefrontCredentials.steamID = steamID
        var persona: String?
        if let access = tokens.accessToken {
            persona = await SteamClient.personaName(accessToken: access)
        }
        StorefrontCredentials.setAccountName(persona ?? tokens.accountName ?? steamID, for: .steam)
    }

    /// Access token for the Web API: the saved one while it has 5+ minutes left, otherwise a new one minted from the refresh token.
    static func accessToken() async throws -> String {
        if let cached = StorefrontCredentials.steamAccessToken,
           let expiry = jwtClaims(cached)?["exp"] as? NSNumber,
           expiry.doubleValue > Date().timeIntervalSince1970 + 300 {
            return cached
        }
        guard let refresh = StorefrontCredentials.refreshToken(for: .steam),
              let steamID = StorefrontCredentials.steamID ?? steamID(fromJWT: refresh) else {
            throw StorefrontError.notSignedIn
        }
        if let expiry = jwtClaims(refresh)?["exp"] as? NSNumber, expiry.doubleValue < Date().timeIntervalSince1970 {
            throw StorefrontError.signInFailed("Steam sign-in expired. Sign in again.")
        }
        let response: [String: Any]
        do {
            response = try await call("GenerateAccessTokenForApp", fields: [
                "refresh_token": refresh,
                "steamid": steamID,
                "renewal_type": "1",
            ])
        } catch SteamAuthError.result(15) {
            // Sign-ins from before GBear switched to MobileApp tokens are WebBrowser tokens, which Steam won't renew here.
            throw StorefrontError.signInFailed("Steam needs you to sign in again (older GBear sign-ins can't be renewed).")
        }
        guard let access = response["access_token"] as? String, !access.isEmpty else {
            throw StorefrontError.decoding("Steam")
        }
        StorefrontCredentials.steamAccessToken = access
        if let rotated = response["refresh_token"] as? String, !rotated.isEmpty {
            StorefrontCredentials.setRefreshToken(rotated, for: .steam)
        }
        return access
    }

    static func steamID(fromJWT token: String) -> String? {
        guard let sub = jwtClaims(token)?["sub"] as? String, !sub.isEmpty, sub.allSatisfy(\.isNumber) else { return nil }
        return sub
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Transport

    private static func session(from response: [String: Any]) throws -> Session {
        guard let clientID = string(response["client_id"]),
              let requestID = response["request_id"] as? String else {
            throw StorefrontError.decoding("Steam")
        }
        let confirmations = (response["allowed_confirmations"] as? [[String: Any]] ?? [])
            .compactMap { ($0["confirmation_type"] as? NSNumber).flatMap { Confirmation(rawValue: $0.intValue) } }
        return Session(
            clientID: clientID,
            requestID: requestID,
            steamID: string(response["steamid"]),
            interval: max(1, (response["interval"] as? NSNumber)?.doubleValue ?? 5),
            confirmations: confirmations,
            emailDomain: (response["allowed_confirmations"] as? [[String: Any]])?
                .compactMap { $0["associated_message"] as? String }.first { !$0.isEmpty },
            challengeURL: response["challenge_url"] as? String
        )
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func call(_ method: String, fields: [String: String], get: Bool = false) async throws -> [String: Any] {
        let body = formEncode(fields)
        var request: URLRequest
        if get {
            request = URLRequest(url: URL(string: base + method + "/v1/?" + body)!)
        } else {
            request = URLRequest(url: URL(string: base + method + "/v1/")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        if let result = http?.value(forHTTPHeaderField: "x-eresult").flatMap(Int.init), result != 1 {
            throw SteamAuthError.result(result)
        }
        guard let code = http?.statusCode, (200 ... 299).contains(code) else {
            throw StorefrontError.http("Steam", http?.statusCode ?? -1)
        }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return root?["response"] as? [String: Any] ?? [:]
    }

    private static func formEncode(_ fields: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    // MARK: Password encryption (RSA PKCS#1 v1.5 with Steam's per-account key)

    private static func encryptPassword(_ password: String, modulusHex: String, exponentHex: String) throws -> String {
        guard let modulus = bytes(fromHex: modulusHex), let exponent = bytes(fromHex: exponentHex) else {
            throw StorefrontError.decoding("Steam")
        }
        let der = derSequence(derInteger(modulus) + derInteger(exponent))
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: modulus.count * 8,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, &error),
              let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(password.utf8) as CFData, &error) as Data? else {
            throw StorefrontError.signInFailed("Could not prepare the Steam password.")
        }
        return encrypted.base64EncodedString()
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        let characters = Array(hex.count % 2 == 0 ? hex : "0" + hex)
        var result: [UInt8] = []
        result.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index ... index + 1]), radix: 16) else { return nil }
            result.append(byte)
        }
        return result
    }

    private static func derLength(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var value = count
        var digits: [UInt8] = []
        while value > 0 {
            digits.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(digits.count)] + digits
    }

    private static func derInteger(_ raw: [UInt8]) -> [UInt8] {
        var value = Array(raw.drop { $0 == 0 })
        if value.isEmpty { value = [0] }
        if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
        return [0x02] + derLength(value.count) + value
    }

    private static func derSequence(_ content: [UInt8]) -> [UInt8] {
        [0x30] + derLength(content.count) + content
    }
}

enum SteamAuthError: Error, LocalizedError {
    /// Steam `EResult` from the `x-eresult` header.
    case result(Int)

    var errorDescription: String? {
        switch self {
        case .result(5): return "Incorrect account name or password."
        case .result(9), .result(27): return "This sign-in request expired. Start again."
        case .result(65): return "That email code didn't work. Check it and try again."
        case .result(84): return "Too many sign-in attempts. Wait a few minutes and try again."
        case .result(88): return "That Steam Guard code didn't work. Check it and try again."
        case .result(let code): return "Steam sign-in failed (error \(code))."
        }
    }
}

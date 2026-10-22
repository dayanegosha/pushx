import Foundation

struct RemoteProfile: Codable, Identifiable, Sendable {
    let id: UUID
    let friendCode: String
    let createdAt: Date
    var displayName: String? = nil
    enum CodingKeys: String, CodingKey {
        case id, friendCode = "friend_code", createdAt = "created_at", displayName = "display_name"
    }
}

struct FriendRow: Codable, Identifiable, Sendable {
    let userID: UUID
    let friendCode: String
    let status: String
    let requestedAt: Date
    var displayName: String? = nil
    var id: UUID { userID }
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", friendCode = "friend_code", status, requestedAt = "requested_at", displayName = "display_name"
    }
}

struct LeaderboardRow: Codable, Identifiable, Sendable {
    let userID: UUID
    let friendCode: String
    let repetitions: Int
    let rank: Int
    let isMe: Bool
    var displayName: String? = nil
    var id: UUID { userID }
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", friendCode = "friend_code", repetitions, rank, isMe = "is_me", displayName = "display_name"
    }
}

struct BlockedFriendRow: Codable, Identifiable, Sendable {
    let userID: UUID
    let friendCode: String
    var displayName: String? = nil
    var id: UUID { userID }
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", friendCode = "friend_code", displayName = "display_name"
    }
}

struct RemoteWorkout: Codable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let repetitions: Int
    let detectionMode: String
    let dayUTC: String
    let receivedAt: Date
    enum CodingKeys: String, CodingKey {
        case id, startedAt = "started_at", endedAt = "ended_at", repetitions
        case detectionMode = "detection_mode", dayUTC = "day_utc", receivedAt = "received_at"
    }
}

struct AuthSession: Codable, Sendable {
    let userID: UUID
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let email: String?
    let appleUserID: String?
    let displayName: String?

    var hasValidCredentials: Bool {
        Self.isValidToken(accessToken) && Self.isValidToken(refreshToken) && expiresAt.timeIntervalSince1970.isFinite
    }

    static func isValidToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 && !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }
    }
}

private struct TokenResponse: Decodable {
    struct User: Decodable { let id: UUID; let email: String? }
    let accessToken: String
    let refreshToken: String
    let expiresIn: TimeInterval
    let expiresAt: TimeInterval?
    let user: User
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token"
        case expiresIn = "expires_in", expiresAt = "expires_at", user
    }

    func session(appleUserID: String?, displayName: String?) throws -> AuthSession {
        let result = AuthSession(userID: user.id, accessToken: accessToken, refreshToken: refreshToken,
                                 expiresAt: expiresAt.map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(expiresIn),
                                 email: user.email, appleUserID: appleUserID, displayName: displayName)
        guard expiresIn.isFinite, expiresIn > 0, result.hasValidCredentials, result.expiresAt > Date() else {
            throw ServiceError.invalidResponse
        }
        return result
    }
}

final class BackendRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor BackendService {
    static let shared = BackendService()
    private let urlSession: URLSession
    private let baseURL: URL?
    private let anonKey: String
    private let requestDelegate = BackendRequestDelegate()
    nonisolated let isConfigured: Bool

    init(urlSession: URLSession? = nil, baseURL: URL? = AppConfiguration.supabaseURL,
         anonKey: String = AppConfiguration.supabaseAnonKey) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        self.urlSession = urlSession ?? URLSession(configuration: configuration)
        self.baseURL = baseURL
        self.anonKey = anonKey
        isConfigured = baseURL?.scheme == "https" && baseURL?.host?.isEmpty == false
            && baseURL?.user == nil && baseURL?.password == nil && baseURL?.query == nil && baseURL?.fragment == nil
            && AuthSession.isValidToken(anonKey) && !anonKey.contains("$(") && !anonKey.hasPrefix("sb_secret_")
    }

    func exchangeAppleToken(idToken: String, nonce: String, appleUserID: String, displayName: String?) async throws -> AuthSession {
        let body = ["provider": "apple", "id_token": idToken, "nonce": nonce]
        let response = try await send(path: "auth/v1/token", method: "POST", body: body,
                                      query: [URLQueryItem(name: "grant_type", value: "id_token")])
        let token = try decode(TokenResponse.self, data: response)
        return try token.session(appleUserID: appleUserID, displayName: displayName)
    }

    func refresh(_ session: AuthSession) async throws -> AuthSession {
        let response = try await send(path: "auth/v1/token", method: "POST", body: ["refresh_token": session.refreshToken],
                                      query: [URLQueryItem(name: "grant_type", value: "refresh_token")])
        let result = try decode(TokenResponse.self, data: response).session(appleUserID: session.appleUserID, displayName: session.displayName)
        guard result.userID == session.userID else { throw ServiceError.invalidResponse }
        return result
    }

    func logout(accessToken: String) async throws {
        _ = try await send(path: "auth/v1/logout", method: "POST", accessToken: accessToken,
                           query: [URLQueryItem(name: "scope", value: "local")])
    }

    func profile(accessToken: String) async throws -> RemoteProfile {
        try await rpc("get_profile", body: [:], accessToken: accessToken, as: RemoteProfile.self)
    }

    func setDisplayName(_ name: String, onlyIfEmpty: Bool = false, accessToken: String) async throws -> RemoteProfile {
        guard let normalized = ProfileName.normalized(name) else { throw ServiceError.invalidDisplayName }
        return try await rpc("set_display_name", body: ["p_display_name": normalized, "p_only_if_empty": onlyIfEmpty],
                             accessToken: accessToken, as: RemoteProfile.self)
    }

    func uploadWorkout(id: UUID, startedAt: Date, endedAt: Date, repetitions: Int, detectionMode: String, accessToken: String) async throws -> RemoteWorkout {
        let body: [String: Any] = ["p_id": id.uuidString, "p_started_at": ServiceDates.string(startedAt),
                                   "p_ended_at": ServiceDates.string(endedAt), "p_repetitions": repetitions,
                                   "p_detection_mode": detectionMode]
        return try await rpc("upload_workout", body: body, accessToken: accessToken, as: RemoteWorkout.self)
    }

    func workouts(accessToken: String) async throws -> [RemoteWorkout] {
        var records: [RemoteWorkout] = []
        let pageSize = 1000
        while true {
            try Task.checkCancellation()
            let query = [
                URLQueryItem(name: "select", value: "id,started_at,ended_at,repetitions,detection_mode,day_utc,received_at"),
                URLQueryItem(name: "order", value: "ended_at.desc,id.desc"),
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "offset", value: String(records.count))
            ]
            let data = try await send(path: "rest/v1/workouts", method: "GET", accessToken: accessToken, query: query)
            let page = try decode([RemoteWorkout].self, data: data)
            records.append(contentsOf: page)
            if page.count < pageSize { return records }
        }
    }

    func friends(accessToken: String) async throws -> [FriendRow] {
        try await rpc("get_friends", body: [:], accessToken: accessToken, as: [FriendRow].self)
    }

    func blockedFriends(accessToken: String) async throws -> [BlockedFriendRow] {
        try await rpc("get_blocked_users", body: [:], accessToken: accessToken, as: [BlockedFriendRow].self)
    }

    @discardableResult
    func requestFriend(code: String, accessToken: String) async throws -> String {
        try await rpc("request_friend", body: ["p_friend_code": code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()],
                      accessToken: accessToken, as: String.self)
    }

    func respondToFriend(userID: UUID, accept: Bool, accessToken: String) async throws {
        _ = try await send(path: "rest/v1/rpc/respond_friend_request", method: "POST",
                           body: ["p_user_id": userID.uuidString, "p_accept": accept], accessToken: accessToken)
    }

    func removeFriend(userID: UUID, accessToken: String) async throws {
        try await userAction("remove_friend", userID: userID, accessToken: accessToken)
    }

    func blockUser(userID: UUID, accessToken: String) async throws {
        try await userAction("block_user", userID: userID, accessToken: accessToken)
    }

    func unblockUser(userID: UUID, accessToken: String) async throws {
        try await userAction("unblock_user", userID: userID, accessToken: accessToken)
    }

    func leaderboard(day: Date, accessToken: String) async throws -> [LeaderboardRow] {
        try await rpc("get_daily_leaderboard", body: ["p_day": ServiceDates.dayUTC(day)],
                      accessToken: accessToken, as: [LeaderboardRow].self)
    }

    func deleteAccount(authorizationCode: String, idToken: String, accessToken: String) async throws {
        struct Result: Decodable { let deleted: Bool }
        let data = try await send(path: "functions/v1/delete-account", method: "POST",
                                  body: ["authorizationCode": authorizationCode, "idToken": idToken], accessToken: accessToken)
        guard try decode(Result.self, data: data).deleted else { throw ServiceError.invalidResponse }
    }

    private func userAction(_ name: String, userID: UUID, accessToken: String) async throws {
        _ = try await send(path: "rest/v1/rpc/\(name)", method: "POST", body: ["p_user_id": userID.uuidString], accessToken: accessToken)
    }

    private func rpc<T: Decodable>(_ name: String, body: [String: Any], accessToken: String, as type: T.Type) async throws -> T {
        let data = try await send(path: "rest/v1/rpc/\(name)", method: "POST", body: body, accessToken: accessToken)
        return try decode(type, data: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do { return try ServiceDates.decoder().decode(type, from: data) }
        catch { throw ServiceError.invalidResponse }
    }

    private func send(path: String, method: String, body: [String: Any]? = nil, accessToken: String? = nil,
                      query: [URLQueryItem] = []) async throws -> Data {
        guard isConfigured, let baseURL else { throw ServiceError.notConfigured }
        if let accessToken, !AuthSession.isValidToken(accessToken) { throw ServiceError.notSignedIn }
        let endpoint = path.split(separator: "/").reduce(baseURL) { $0.appendingPathComponent(String($1)) }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw ServiceError.notConfigured }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ServiceError.notConfigured }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await urlSession.data(for: request, delegate: requestDelegate)
        guard let response = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200...299).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = [object?["error_code"], object?["error"], object?["message"], object?["code"]]
                .compactMap { $0 as? String }.joined(separator: " ")
            throw ServiceError.server(status: response.statusCode, code: code.lowercased())
        }
        return data
    }
}

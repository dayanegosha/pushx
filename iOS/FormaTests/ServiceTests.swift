import XCTest
@testable import Forma

private final class ServiceURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class ServiceTests: XCTestCase {
    private let userID = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!
    private let workoutID = UUID(uuidString: "12345678-1234-1234-1234-123456789abd")!
    private var service: BackendService!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServiceURLProtocol.self]
        service = BackendService(urlSession: URLSession(configuration: configuration),
                                 baseURL: URL(string: "https://forma-tests.invalid"), anonKey: "public-test-key")
    }

    override func tearDown() {
        ServiceURLProtocol.handler = nil
        service = nil
        super.tearDown()
    }

    func testAppleExchangeUsesRawNonceAndPublicKey() async throws {
        let userID = userID
        ServiceURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/auth/v1/token")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "id_token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "public-test-key")
            let payload = try Self.body(request)
            XCTAssertEqual(payload["nonce"] as? String, "raw-nonce")
            XCTAssertEqual(payload["provider"] as? String, "apple")
            XCTAssertEqual(payload["id_token"] as? String, "apple-jwt")
            return (200, try Self.json(["access_token": "token", "refresh_token": "refresh", "expires_in": 3600,
                                        "user": ["id": userID.uuidString, "email": "relay@example.invalid"]]))
        }
        let session = try await service.exchangeAppleToken(idToken: "apple-jwt", nonce: "raw-nonce",
                                                           appleUserID: "apple-subject", displayName: nil)
        XCTAssertEqual(session.userID, userID)
        XCTAssertEqual(session.appleUserID, "apple-subject")
        XCTAssertGreaterThan(session.expiresAt.timeIntervalSinceNow, 3500)
    }

    func testRefreshRotatesTokenAndPreservesAppleSubject() async throws {
        let session = AuthSession(userID: userID, accessToken: "expired", refreshToken: "old-refresh", expiresAt: .distantPast,
                                  email: nil, appleUserID: "apple-subject", displayName: nil)
        let userID = userID
        ServiceURLProtocol.handler = { request in
            XCTAssertEqual(try Self.body(request)["refresh_token"] as? String, "old-refresh")
            return (200, try Self.json(["access_token": "new-token", "refresh_token": "new-refresh", "expires_in": 3600,
                                        "user": ["id": userID.uuidString]]))
        }
        let refreshed = try await service.refresh(session)
        XCTAssertEqual(refreshed.accessToken, "new-token")
        XCTAssertEqual(refreshed.refreshToken, "new-refresh")
        XCTAssertEqual(refreshed.appleUserID, session.appleUserID)
    }

    func testProfileParsesPostgresMicroseconds() async throws {
        let userID = userID
        ServiceURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/get_profile")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            return (200, try Self.json(["id": userID.uuidString, "friend_code": "ABCDEF1234", "created_at": "2026-10-18T12:01:00.987654+00:00"]))
        }
        let profile = try await service.profile(accessToken: "token")
        XCTAssertEqual(profile.id, userID)
        XCTAssertEqual(profile.friendCode, "ABCDEF1234")
    }

    func testWorkoutUploadUsesImmutableIDAndDateFields() async throws {
        let row = workoutRow()
        let workoutID = workoutID
        ServiceURLProtocol.handler = { request in
            let payload = try Self.body(request)
            XCTAssertEqual(payload["p_id"] as? String, workoutID.uuidString)
            XCTAssertEqual(payload["p_repetitions"] as? Int, 20)
            XCTAssertEqual(payload["p_detection_mode"] as? String, "camera")
            XCTAssertNotNil(ServiceDates.date(payload["p_started_at"] as! String))
            return (200, try Self.json(row))
        }
        let workout = try await service.uploadWorkout(id: workoutID, startedAt: ServiceDates.date("2026-10-18T12:00:00Z")!,
                                                      endedAt: ServiceDates.date("2026-10-18T12:01:00Z")!, repetitions: 20,
                                                      detectionMode: "camera", accessToken: "token")
        XCTAssertEqual(workout.id, workoutID)
        XCTAssertEqual(workout.repetitions, 20)
    }

    func testRequestFriendNormalizesCodeAndParsesStatus() async throws {
        ServiceURLProtocol.handler = { request in
            XCTAssertEqual(try Self.body(request)["p_friend_code"] as? String, "ABCDEF1234")
            return (200, try Self.json("outgoing"))
        }
        let status = try await service.requestFriend(code: " abcdef1234\n", accessToken: "token")
        XCTAssertEqual(status, "outgoing")
    }

    func testLeaderboardUsesUTCDateAcrossLocalMidnight() async throws {
        let userID = userID
        ServiceURLProtocol.handler = { request in
            XCTAssertEqual(try Self.body(request)["p_day"] as? String, "2026-10-17")
            return (200, try Self.json([["user_id": userID.uuidString, "friend_code": "ABCDEF1234", "repetitions": 20, "rank": 1, "is_me": true]]))
        }
        let rows = try await service.leaderboard(day: ServiceDates.date("2026-10-18T00:20:00+03:00")!, accessToken: "token")
        XCTAssertEqual(rows.first?.userID, userID)
        XCTAssertEqual(rows.first?.isMe, true)
    }

    func testCloudHistoryPaginatesBeyondOneThousandWorkouts() async throws {
        let row = workoutRow()
        var page = 0
        ServiceURLProtocol.handler = { request in
            page += 1
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(query.contains(URLQueryItem(name: "order", value: "ended_at.desc,id.desc")))
            if page == 1 { return (200, try Self.json(Array(repeating: row, count: 1000))) }
            XCTAssertTrue(query.contains(URLQueryItem(name: "offset", value: "1000")))
            return (200, try Self.json([row]))
        }
        let records = try await service.workouts(accessToken: "token")
        XCTAssertEqual(records.count, 1001)
        XCTAssertEqual(page, 2)
    }

    func testServerErrorsNeverDisplayRawServerPayload() async throws {
        ServiceURLProtocol.handler = { _ in
            (400, try Self.json(["code": "22023", "message": "workout_time_overlap", "secret": "PRIVATE-DATA"]))
        }
        do {
            _ = try await service.profile(accessToken: "token")
            XCTFail("A failed server request must not succeed")
        } catch let error as ServiceError {
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE-DATA"))
            XCTAssertFalse(error.localizedDescription.contains("22023"))
        }
    }

    func testDeletionRequiresExplicitTrueConfirmation() async throws {
        ServiceURLProtocol.handler = { _ in (200, try Self.json(["deleted": false])) }
        do {
            try await service.deleteAccount(authorizationCode: "fresh-code", idToken: "fresh-token", accessToken: "token")
            XCTFail("Deletion false must not be treated as a successful account deletion")
        } catch ServiceError.invalidResponse {}
        ServiceURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/functions/v1/delete-account")
            XCTAssertEqual(try Self.body(request)["authorizationCode"] as? String, "fresh-code")
            return (200, try Self.json(["deleted": true]))
        }
        try await service.deleteAccount(authorizationCode: "fresh-code", idToken: "fresh-token", accessToken: "token")
    }

    func testMissingConfigurationCannotReturnFakeSuccess() async throws {
        let unconfigured = BackendService(baseURL: nil, anonKey: "")
        do {
            _ = try await unconfigured.profile(accessToken: "token")
            XCTFail("Cloud operations require deployed backend configuration")
        } catch ServiceError.notConfigured {}
    }

    private func workoutRow() -> [String: Any] {
        ["id": workoutID.uuidString, "started_at": "2026-10-18T12:00:00Z", "ended_at": "2026-10-18T12:01:00.123456+00:00",
         "repetitions": 20, "detection_mode": "camera", "day_utc": "2026-10-18", "received_at": "2026-10-18T12:01:01Z"]
    }

    private static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody { return try JSONSerialization.jsonObject(with: data) as! [String: Any] }
        guard let stream = request.httpBodyStream else { return [:] }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

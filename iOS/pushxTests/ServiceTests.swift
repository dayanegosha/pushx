import XCTest
import Security
@testable import pushx

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

@MainActor
private final class SessionStorageStub: AuthSessionStorage {
    var value: AuthSession?
    var failSave = false
    var saveCalls = 0

    init(_ session: AuthSession) { value = session }
    func load() throws -> AuthSession? { value }
    func save(_ session: AuthSession) throws {
        saveCalls += 1
        if failSave { throw ServiceError.secureStorage }
        value = session
    }
    func delete() throws { value = nil }
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
                                 baseURL: URL(string: "https://pushx-tests.invalid"), anonKey: "public-test-key")
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
                                  email: nil, appleUserID: "apple-subject", displayName: "Георгий Журик")
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
        XCTAssertEqual(refreshed.displayName, session.displayName)
    }

    func testAppleNameSurvivesRepeatedSignInAndIsIsolatedByAccount() throws {
        let status = SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword,
                                         kSecAttrService as String: "app.pushx.tests.entitlement-check"] as CFDictionary, nil)
        if status == errSecMissingEntitlement { throw XCTSkip("Keychain requires an app signature with application-identifier; this test build is unsigned.") }
        let cache = AppleNameKeychain(service: "app.pushx.tests.apple-names." + UUID().uuidString)
        defer { try? cache.delete(for: "apple-a"); try? cache.delete(for: "apple-b") }
        XCTAssertEqual(try cache.capture("  Георгий\u{3000}Журик  ", for: "apple-a"), "Георгий Журик")
        XCTAssertEqual(try cache.load(for: "apple-a"), "Георгий Журик")
        XCTAssertNil(try cache.load(for: "apple-b"))
        XCTAssertEqual(try cache.capture(nil, for: "apple-a"), "Георгий Журик")
        try cache.save("George", for: "apple-a")
        XCTAssertEqual(try cache.capture("Old Apple name", for: "apple-a"), "George")
        XCTAssertEqual(try cache.capture("小明", for: "apple-b"), "小明")
        try cache.delete(for: "apple-a")
        XCTAssertNil(try cache.load(for: "apple-a"))
        XCTAssertEqual(try cache.load(for: "apple-b"), "小明")
    }

    func testProfileNameNormalizesUnicodeAndRejectsInvisibleControls() {
        XCTAssertEqual(ProfileName.normalized("\t  Jose\u{0301}\u{00A0}\u{3000}林\n"), "José 林")
        XCTAssertEqual(ProfileName.normalized(String(repeating: "林", count: 64)), String(repeating: "林", count: 64))
        for value in [nil, "", "\u{00A0}\t", String(repeating: "林", count: 65), "A\u{0000}B", "A\u{200B}B", "A\u{202E}B", "A\u{FEFF}B"] {
            XCTAssertNil(ProfileName.normalized(value))
        }
    }

    func testDisplayNameRPCNormalizesInputAndCanImportOnlyWhenEmpty() async throws {
        let userID = userID
        var calls = 0
        ServiceURLProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/set_display_name")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            let payload = try Self.body(request)
            XCTAssertEqual(payload["p_display_name"] as? String, "Георгий Журик")
            XCTAssertEqual(payload["p_only_if_empty"] as? Bool, calls == 1)
            return (200, try Self.json(["id": userID.uuidString, "friend_code": "ABCDEF1234",
                                        "created_at": "2026-10-18T12:01:00Z", "display_name": "Георгий Журик"]))
        }
        let imported = try await service.setDisplayName(" Георгий\nЖурик ", onlyIfEmpty: true, accessToken: "token")
        XCTAssertEqual(imported.displayName, "Георгий Журик")
        _ = try await service.setDisplayName("Георгий Журик", accessToken: "token")
        XCTAssertEqual(calls, 2)
    }

    func testInvalidNameIsRejectedBeforeNetworkRequest() async throws {
        ServiceURLProtocol.handler = { _ in XCTFail("Invalid names must not reach the network"); return (500, Data()) }
        do {
            _ = try await service.setDisplayName("\u{200B}", accessToken: "token")
            XCTFail("Invalid name was accepted")
        } catch ServiceError.invalidDisplayName {}
    }

    func testFriendNamesDecodeAndLegacyProfilesRemainCompatible() throws {
        let decoder = ServiceDates.decoder()
        let common: [String: Any] = ["user_id": userID.uuidString, "friend_code": "ABCDEF1234", "display_name": "小明 王"]
        let friend = try decoder.decode(FriendRow.self, from: Self.json(common.merging(["status": "accepted", "requested_at": "2026-10-18T12:00:00Z"]) { _, new in new }))
        let rank = try decoder.decode(LeaderboardRow.self, from: Self.json(common.merging(["repetitions": 20, "rank": 1, "is_me": false]) { _, new in new }))
        let blocked = try decoder.decode(BlockedFriendRow.self, from: Self.json(common))
        XCTAssertEqual(friend.displayName, "小明 王")
        XCTAssertEqual(rank.displayName, friend.displayName)
        XCTAssertEqual(blocked.displayName, friend.displayName)
        let legacy: [String: Any] = ["id": userID.uuidString, "friend_code": "ABCDEF1234", "created_at": "2026-10-18T12:00:00Z"]
        XCTAssertNil(try decoder.decode(RemoteProfile.self, from: Self.json(legacy)).displayName)
        XCTAssertNil(try decoder.decode(RemoteProfile.self, from: Self.json(legacy.merging(["display_name": NSNull()]) { _, new in new })).displayName)
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

    func testSensitiveRequestsDisableCachesAndCookies() async throws {
        let userID = userID
        ServiceURLProtocol.handler = { request in
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertFalse(request.httpShouldHandleCookies)
            return (200, try Self.json(["id": userID.uuidString, "friend_code": "ABCDEF1234", "created_at": "2026-10-18T12:00:00Z"]))
        }
        _ = try await service.profile(accessToken: "token")
    }

    func testUnsafeBackendConfigurationCannotSendCredentials() async throws {
        ServiceURLProtocol.handler = { _ in XCTFail("Unsafe configurations must not send requests"); return (500, Data()) }
        for address in ["http://pushx-tests.invalid", "https://user:password@pushx-tests.invalid", "https://pushx-tests.invalid?key=value", "https://pushx-tests.invalid#fragment"] {
            let invalid = BackendService(baseURL: URL(string: address), anonKey: "public-test-key")
            do {
                _ = try await invalid.profile(accessToken: "token")
                XCTFail("Unsafe configuration was accepted: \(address)")
            } catch ServiceError.notConfigured {}
        }
    }

    func testMalformedOrDifferentAccountRefreshCannotReplaceCredentials() async throws {
        let current = AuthSession(userID: userID, accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast,
                                  email: nil, appleUserID: nil, displayName: nil)
        for (id, token, lifetime) in [(UUID(), "token", 3600), (userID, "", 3600), (userID, "bad\r\ntoken", 3600), (userID, "token", -1)] {
            ServiceURLProtocol.handler = { _ in
                (200, try Self.json(["access_token": token, "refresh_token": "rotated", "expires_in": lifetime, "user": ["id": id.uuidString]]))
            }
            do {
                _ = try await service.refresh(current)
                XCTFail("Malformed refresh was accepted")
            } catch ServiceError.invalidResponse {}
        }
    }

    func testAuthenticatedRedirectsAreRejectedBeforeFollowing() {
        let delegate = BackendRequestDelegate()
        let original = URL(string: "https://pushx-tests.invalid/auth/v1/token")!
        let redirected = URLRequest(url: URL(string: "https://another.invalid/capture")!)
        let response = HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: ["Location": redirected.url!.absoluteString])!
        var decided = false
        let task = URLSession.shared.dataTask(with: original)
        delegate.urlSession(.shared, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { request in
            decided = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(decided)
        task.cancel()
    }

    @MainActor
    func testSignOutDuringRefreshCannotRestoreSession() async throws {
        let session = AuthSession(userID: userID, accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast,
                                  email: nil, appleUserID: nil, displayName: nil)
        let storage = SessionStorageStub(session)
        let auth = AuthService(backend: service, sessionStorage: storage)
        let started = expectation(description: "Refresh is awaiting its response")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let userID = userID
        ServiceURLProtocol.handler = { request in
            if request.url?.path == "/auth/v1/logout" { return (204, Data()) }
            started.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            return (200, try Self.json(["access_token": "rotated", "refresh_token": "rotated-refresh", "expires_in": 3600, "user": ["id": userID.uuidString]]))
        }
        let restoring = Task { await auth.restoreSession() }
        await fulfillment(of: [started], timeout: 5)
        let signingOut = Task { await auth.signOut() }
        await Task.yield()
        XCTAssertNil(auth.session)
        release.signal()
        await signingOut.value
        await restoring.value
        XCTAssertNil(auth.session)
        XCTAssertNil(storage.value)
        XCTAssertEqual(storage.saveCalls, 0)
        XCTAssertNil(auth.errorMessage)
    }

    @MainActor
    func testSuppressedKeychainSessionCannotReturnAfterRestart() throws {
        let status = SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword,
                                         kSecAttrService as String: "app.pushx.tests.entitlement-check"] as CFDictionary, nil)
        if status == errSecMissingEntitlement { throw XCTSkip("This test requires a signed app with Keychain access.") }
        let suite = "pushx.session.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = SessionKeychain(service: suite, defaults: defaults)
        defer { try? storage.delete() }
        let session = AuthSession(userID: userID, accessToken: "token", refreshToken: "refresh",
                                  expiresAt: Date().addingTimeInterval(3600), email: nil, appleUserID: nil, displayName: nil)
        try storage.save(session)
        XCTAssertEqual(try storage.load()?.accessToken, "token")
        defaults.set(true, forKey: "authSessionSuppressed")
        let afterRestart = SessionKeychain(service: suite, defaults: defaults)
        XCTAssertNil(try afterRestart.load())
        try afterRestart.save(session)
        XCTAssertFalse(defaults.bool(forKey: "authSessionSuppressed"))
        XCTAssertEqual(try afterRestart.load()?.accessToken, "token")
    }

    @MainActor
    func testConcurrentRefreshWaitersCannotReceiveUnpersistedTokens() async throws {
        let session = AuthSession(userID: userID, accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast,
                                  email: nil, appleUserID: nil, displayName: nil)
        let storage = SessionStorageStub(session)
        storage.failSave = true
        let auth = AuthService(backend: service, sessionStorage: storage)
        let started = expectation(description: "Refresh is awaiting its response")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let userID = userID
        ServiceURLProtocol.handler = { _ in
            started.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            return (200, try Self.json(["access_token": "rotated", "refresh_token": "rotated-refresh", "expires_in": 3600, "user": ["id": userID.uuidString]]))
        }
        let restoring = Task { await auth.restoreSession() }
        await fulfillment(of: [started], timeout: 5)
        let waiter = Task { () -> Bool in
            do { _ = try await auth.validAccessToken(); return false }
            catch ServiceError.secureStorage { return true }
            catch { return false }
        }
        await Task.yield()
        release.signal()
        let failedSecurely = await waiter.value
        await restoring.value
        XCTAssertTrue(failedSecurely)
        XCTAssertEqual(storage.saveCalls, 1)
        XCTAssertEqual(auth.session?.accessToken, "old")
        XCTAssertEqual(storage.value?.refreshToken, "refresh")
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

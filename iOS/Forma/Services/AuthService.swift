import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security

private struct AppleCredential {
    let userID: String
    let idToken: String
    let authorizationCode: String?
    let email: String?
    let displayName: String?
    let rawNonce: String
    let forAccountDeletion: Bool
}

@MainActor
private final class AppleSignInCoordinator {
    private struct Request {
        let rawNonce: String
        let state: String
        let forAccountDeletion: Bool
    }
    private var pending: Request?

    func prepare(_ request: ASAuthorizationAppleIDRequest, forAccountDeletion: Bool) throws {
        let nonce = try randomString()
        let state = try randomString()
        pending = Request(rawNonce: nonce, state: state, forAccountDeletion: forAccountDeletion)
        request.requestedScopes = forAccountDeletion ? [] : [.fullName]
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        request.state = state
    }

    func consume(_ result: Result<ASAuthorization, Error>) throws -> AppleCredential {
        defer { pending = nil }
        let authorization = try result.get()
        guard let pending,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              credential.state == pending.state,
              let data = credential.identityToken,
              let idToken = String(data: data, encoding: .utf8), !idToken.isEmpty else {
            throw ServiceError.invalidAppleCredential
        }
        let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
        return AppleCredential(userID: credential.user, idToken: idToken,
                               authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
                               email: credential.email, displayName: ProfileName.normalized(name),
                               rawNonce: pending.rawNonce, forAccountDeletion: pending.forAccountDeletion)
    }

    private func randomString(length: Int = 32) throws -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        while result.count < length {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw ServiceError.secureStorage
            }
            for value in bytes where Int(value) < alphabet.count {
                result.append(alphabet[Int(value)])
                if result.count == length { break }
            }
        }
        return result
    }
}

@MainActor
protocol AuthSessionStorage {
    func load() throws -> AuthSession?
    func save(_ session: AuthSession) throws
    func delete() throws
}

struct SessionKeychain: AuthSessionStorage {
    private let service: String
    private let defaults: UserDefaults
    private let account = "supabase-session-v1"
    private let suppressedKey = "authSessionSuppressed"

    init(service: String = (Bundle.main.bundleIdentifier ?? "app.forma.pushups") + ".auth", defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() throws -> AuthSession? {
        if defaults.bool(forKey: suppressedKey) {
            try delete()
            return nil
        }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw ServiceError.secureStorage }
        do {
            let session = try JSONDecoder().decode(AuthSession.self, from: data)
            guard session.hasValidCredentials else { throw ServiceError.invalidResponse }
            return session
        }
        catch {
            try delete()
            return nil
        }
    }

    func save(_ session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let changes: [String: Any] = [kSecValueData as String: data,
                                      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if update == errSecItemNotFound {
            let new = query.merging(changes) { _, new in new }
            guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else { throw ServiceError.secureStorage }
        } else if update != errSecSuccess { throw ServiceError.secureStorage }
        defaults.set(false, forKey: suppressedKey)
    }

    func delete() throws {
        defaults.set(true, forKey: suppressedKey)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ServiceError.secureStorage }
    }
}

struct AppleNameKeychain {
    let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "app.forma.pushups") + ".apple-names") {
        self.service = service
    }

    func capture(_ name: String?, for appleUserID: String) throws -> String? {
        if let saved = try load(for: appleUserID) { return saved }
        guard let normalized = ProfileName.normalized(name) else { return nil }
        try save(normalized, for: appleUserID)
        return normalized
    }

    func load(for appleUserID: String) throws -> String? {
        var request = query(for: appleUserID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw ServiceError.secureStorage }
        return ProfileName.normalized(String(data: data, encoding: .utf8))
    }

    func save(_ name: String, for appleUserID: String) throws {
        guard let normalized = ProfileName.normalized(name), let data = normalized.data(using: .utf8) else {
            throw ServiceError.invalidDisplayName
        }
        let query = query(for: appleUserID)
        let changes: [String: Any] = [kSecValueData as String: data,
                                      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if update == errSecItemNotFound {
            guard SecItemAdd(query.merging(changes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw ServiceError.secureStorage
            }
        } else if update != errSecSuccess { throw ServiceError.secureStorage }
    }

    func delete(for appleUserID: String) throws {
        let status = SecItemDelete(query(for: appleUserID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ServiceError.secureStorage }
    }

    private func query(for appleUserID: String) -> [String: Any] {
        let account = SHA256.hash(data: Data(appleUserID.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account]
    }
}

@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()
    @Published private(set) var session: AuthSession?
    @Published private(set) var profile: RemoteProfile?
    @Published private(set) var isBusy = false
    @Published private(set) var lastDeletedUserID: UUID?
    @Published var errorMessage: String?

    private let backend: BackendService
    private let keychain: any AuthSessionStorage
    private let names = AppleNameKeychain()
    private let coordinator = AppleSignInCoordinator()
    private var refreshTask: Task<AuthSession, Error>?
    private var sessionVersion = 0
    private var profileRevision = 0
    private var restored = false
    private var revocationObserver: NSObjectProtocol?

    init(backend: BackendService = .shared, sessionStorage: (any AuthSessionStorage)? = nil) {
        self.backend = backend
        self.keychain = sessionStorage ?? SessionKeychain()
        revocationObserver = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.signOut()
            }
        }
    }

    func prepareAppleSignIn(_ request: ASAuthorizationAppleIDRequest, forAccountDeletion: Bool = false) {
        errorMessage = nil
        do { try coordinator.prepare(request, forAccountDeletion: forAccountDeletion) }
        catch { errorMessage = ServiceCopy.message(for: error) }
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        var version = sessionVersion
        defer { isBusy = false }
        do {
            let credential = try coordinator.consume(result)
            if credential.forAccountDeletion {
                guard let current = session,
                      current.appleUserID == nil || current.appleUserID == credential.userID,
                      let code = credential.authorizationCode, !code.isEmpty else { throw ServiceError.invalidAppleCredential }
                let token = try await validAccessToken()
                guard version == sessionVersion, session?.userID == current.userID else { throw CancellationError() }
                try await backend.deleteAccount(authorizationCode: code, idToken: credential.idToken, accessToken: token)
                lastDeletedUserID = current.userID
                let nameDeletion = Result { try names.delete(for: credential.userID) }
                guard version == sessionVersion, session?.userID == current.userID else { throw CancellationError() }
                version = sessionVersion + 1
                try clearSession()
                try nameDeletion.get()
            } else {
                let displayName = try names.capture(credential.displayName, for: credential.userID)
                let session = try await backend.exchangeAppleToken(idToken: credential.idToken, nonce: credential.rawNonce,
                                                                   appleUserID: credential.userID, displayName: displayName)
                guard version == sessionVersion else { throw CancellationError() }
                try keychain.save(session)
                sessionVersion += 1
                version = sessionVersion
                self.session = session
                profile = nil
                try await refreshProfile()
            }
        } catch let error as ASAuthorizationError where error.code == .canceled {
        } catch is CancellationError {
        } catch { if version == sessionVersion { errorMessage = ServiceCopy.message(for: error) } }
    }

    func restoreSession() async {
        guard !restored else { return }
        restored = true
        guard backend.isConfigured else { return }
        var version = sessionVersion
        isBusy = true
        defer { isBusy = false }
        do {
            session = try keychain.load()
            guard let stored = session else { return }
            if let appleID = stored.appleUserID {
                let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: appleID)
                guard version == sessionVersion, session?.userID == stored.userID else { throw CancellationError() }
                if state == .revoked || state == .notFound || state == .transferred {
                    version = sessionVersion + 1
                    try clearSession()
                    return
                }
            }
            _ = try await validAccessToken()
            guard version == sessionVersion else { throw CancellationError() }
            try await refreshProfile()
        } catch is CancellationError {
        } catch {
            if version == sessionVersion { errorMessage = ServiceCopy.message(for: error) }
        }
    }

    func validAccessToken() async throws -> String {
        guard let current = session else { throw ServiceError.notSignedIn }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        let version = sessionVersion
        if let refreshTask {
            let refreshed = try await refreshTask.value
            guard sessionVersion == version, session?.userID == current.userID else { throw CancellationError() }
            return refreshed.accessToken
        }
        let task = Task {
            let refreshed = try await backend.refresh(current)
            guard self.sessionVersion == version, let latest = self.session,
                  latest.userID == current.userID else { throw CancellationError() }
            let updated = AuthSession(userID: refreshed.userID, accessToken: refreshed.accessToken,
                                      refreshToken: refreshed.refreshToken, expiresAt: refreshed.expiresAt,
                                      email: refreshed.email, appleUserID: latest.appleUserID,
                                      displayName: latest.displayName)
            try self.keychain.save(updated)
            self.session = updated
            return updated
        }
        refreshTask = task
        defer { if sessionVersion == version { refreshTask = nil } }
        do {
            let refreshed = try await task.value
            guard sessionVersion == version, session?.userID == current.userID else { throw CancellationError() }
            return refreshed.accessToken
        } catch {
            if case ServiceError.server(let status, _) = error, status == 400 || status == 401 {
                if sessionVersion == version { try? clearSession() }
            }
            throw error
        }
    }

    func refreshProfile() async throws {
        let version = sessionVersion
        let revision = profileRevision
        let token = try await validAccessToken()
        guard version == sessionVersion else { throw CancellationError() }
        guard revision == profileRevision else { return }
        let result = try await backend.profile(accessToken: token)
        guard version == sessionVersion, result.id == session?.userID else { throw CancellationError() }
        guard revision == profileRevision else { return }
        if ProfileName.normalized(result.displayName) == nil,
           let name = ProfileName.normalized(session?.displayName) {
            let updated = try await backend.setDisplayName(name, onlyIfEmpty: true, accessToken: token)
            guard version == sessionVersion, updated.id == session?.userID else { throw CancellationError() }
            guard revision == profileRevision else { return }
            try saveProfile(updated)
        } else {
            try saveProfile(result)
        }
    }

    func updateDisplayName(_ name: String) async throws {
        guard let normalized = ProfileName.normalized(name) else { throw ServiceError.invalidDisplayName }
        profileRevision += 1
        let revision = profileRevision
        let version = sessionVersion
        let token = try await validAccessToken()
        guard version == sessionVersion else { throw CancellationError() }
        guard revision == profileRevision else { return }
        let result = try await backend.setDisplayName(normalized, accessToken: token)
        guard version == sessionVersion, result.id == session?.userID else { throw CancellationError() }
        guard revision == profileRevision else { return }
        profileRevision += 1
        try saveProfile(result)
    }

    private func saveProfile(_ result: RemoteProfile) throws {
        guard let current = session, result.id == current.userID else { throw CancellationError() }
        let name = ProfileName.normalized(result.displayName) ?? ProfileName.normalized(current.displayName)
        let updated = AuthSession(userID: current.userID, accessToken: current.accessToken, refreshToken: current.refreshToken,
                                  expiresAt: current.expiresAt, email: current.email, appleUserID: current.appleUserID,
                                  displayName: name)
        try keychain.save(updated)
        if let appleUserID = current.appleUserID, let name { try names.save(name, for: appleUserID) }
        session = updated
        profile = result
    }

    func signOut() async {
        let token = session?.accessToken
        do { try clearSession() }
        catch { errorMessage = ServiceCopy.message(for: error) }
        if let token { try? await backend.logout(accessToken: token) }
    }

    private func clearSession() throws {
        sessionVersion += 1
        refreshTask?.cancel()
        refreshTask = nil
        session = nil
        profile = nil
        try keychain.delete()
    }
}

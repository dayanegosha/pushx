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
        request.requestedScopes = []
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
                               email: credential.email, displayName: name.flatMap { $0.isEmpty ? nil : $0 },
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

private struct SessionKeychain {
    private var service: String { (Bundle.main.bundleIdentifier ?? "app.forma.pushups") + ".auth" }
    private let account = "supabase-session-v1"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() throws -> AuthSession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw ServiceError.secureStorage }
        do { return try JSONDecoder().decode(AuthSession.self, from: data) }
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
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ServiceError.secureStorage }
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

    private let backend = BackendService.shared
    private let keychain = SessionKeychain()
    private let coordinator = AppleSignInCoordinator()
    private var refreshTask: Task<AuthSession, Error>?
    private var sessionVersion = 0
    private var restored = false
    private var revocationObserver: NSObjectProtocol?

    private init() {
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
        defer { isBusy = false }
        do {
            let credential = try coordinator.consume(result)
            if credential.forAccountDeletion {
                guard let current = session,
                      current.appleUserID == nil || current.appleUserID == credential.userID,
                      let code = credential.authorizationCode, !code.isEmpty else { throw ServiceError.invalidAppleCredential }
                let token = try await validAccessToken()
                try await backend.deleteAccount(authorizationCode: code, idToken: credential.idToken, accessToken: token)
                lastDeletedUserID = current.userID
                try clearSession()
            } else {
                let session = try await backend.exchangeAppleToken(idToken: credential.idToken, nonce: credential.rawNonce,
                                                                   appleUserID: credential.userID, displayName: credential.displayName)
                try keychain.save(session)
                sessionVersion += 1
                self.session = session
                try await refreshProfile()
            }
        } catch let error as ASAuthorizationError where error.code == .canceled {
        } catch { errorMessage = ServiceCopy.message(for: error) }
    }

    func restoreSession() async {
        guard !restored else { return }
        restored = true
        isBusy = true
        defer { isBusy = false }
        do {
            session = try keychain.load()
            guard let stored = session else { return }
            if let appleID = stored.appleUserID {
                let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: appleID)
                if state == .revoked || state == .notFound || state == .transferred {
                    try clearSession()
                    return
                }
            }
            _ = try await validAccessToken()
            try await refreshProfile()
        } catch {
            errorMessage = ServiceCopy.message(for: error)
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
        let task = Task { try await backend.refresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let refreshed = try await task.value
            guard sessionVersion == version, session?.userID == current.userID else { throw CancellationError() }
            try keychain.save(refreshed)
            session = refreshed
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
        let token = try await validAccessToken()
        let result = try await backend.profile(accessToken: token)
        guard version == sessionVersion, result.id == session?.userID else { throw CancellationError() }
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

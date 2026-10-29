import SwiftUI
import AuthenticationServices

struct AppleLoginButton: View {
    @EnvironmentObject private var auth: AuthService
    @Environment(\.colorScheme) private var colorScheme
    var deletion = false
    var body: some View {
        NativeAppleLoginButton(auth: auth, deletion: deletion, dark: colorScheme == .dark,
                               enabled: !auth.isBusy && AppConfiguration.isBackendConfigured)
            .frame(height: 44)
    }
}

private struct NativeAppleLoginButton: UIViewRepresentable {
    let auth: AuthService
    let deletion: Bool
    let dark: Bool
    let enabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(auth: auth, deletion: deletion) }

    func makeUIView(context: Context) -> AppleButtonContainer {
        let view = AppleButtonContainer()
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: AppleButtonContainer, context: Context) {
        context.coordinator.deletion = deletion
        view.configure(dark: dark, enabled: enabled, target: context.coordinator, action: #selector(Coordinator.signIn))
    }

    @MainActor
    final class Coordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
        let auth: AuthService
        var deletion: Bool
        weak var view: AppleButtonContainer?
        private var controller: ASAuthorizationController?

        init(auth: AuthService, deletion: Bool) {
            self.auth = auth
            self.deletion = deletion
        }

        @objc func signIn() {
            guard !auth.isBusy, controller == nil, AppConfiguration.isBackendConfigured else { return }
            let request = ASAuthorizationAppleIDProvider().createRequest()
            auth.prepareAppleSignIn(request, forAccountDeletion: deletion)
            guard auth.errorMessage == nil else { return }
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            view?.window ?? ASPresentationAnchor()
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
            self.controller = nil
            Task { await auth.completeAppleSignIn(.success(authorization)) }
        }

        func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
            self.controller = nil
            Task { await auth.completeAppleSignIn(.failure(error)) }
        }
    }
}

private final class AppleButtonContainer: UIView {
    private var button: ASAuthorizationAppleIDButton?
    private var dark: Bool?

    func configure(dark: Bool, enabled: Bool, target: Any, action: Selector) {
        overrideUserInterfaceStyle = dark ? .dark : .light
        if self.dark != dark {
            button?.removeFromSuperview()
            let button = ASAuthorizationAppleIDButton(type: .continue, style: dark ? .white : .black)
            button.cornerRadius = 22
            button.translatesAutoresizingMaskIntoConstraints = false
            button.accessibilityIdentifier = "apple_sign_in"
            button.addTarget(target, action: action, for: .touchUpInside)
            addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: leadingAnchor),
                button.trailingAnchor.constraint(equalTo: trailingAnchor),
                button.topAnchor.constraint(equalTo: topAnchor),
                button.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            self.button = button
            self.dark = dark
        }
        button?.overrideUserInterfaceStyle = dark ? .dark : .light
        button?.isEnabled = enabled
    }
}

struct FriendsView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var model: AppModel
    @State private var friends: [FriendRow] = []
    @State private var blocked: [BlockedFriendRow] = []
    @State private var leaderboard: [LeaderboardRow] = []
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var yesterday = false
    @State private var loadVersion = 0
    private var boardDay: Date { Date.now.addingTimeInterval(yesterday ? -86400 : 0) }

    var body: some View {
        NavigationStack {
            ScrollView {
                AdaptiveContent {
                VStack(alignment: .leading, spacing: 24) {
                    PageTitle(title: L.text("friends"))
                    if auth.session == nil {
                        InfoCard(icon: "person.2", title: L.text("friendly_rivalry"), detail: L.text("friendly_rivalry_body"))
                        AppleLoginButton().frame(maxWidth: 420).frame(maxWidth: .infinity)
                        Text(L.text("sign_in_optional")).font(.footnote).foregroundStyle(.secondary)
                        if !AppConfiguration.isBackendConfigured { StatusNote(text: L.text("backend_not_configured")) }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(profileName).font(AppFont.text(25, weight: .semibold)).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("friend_profile_name")
                            HStack {
                                Text(L.text("your_id")).font(AppFont.text(12)).foregroundStyle(.secondary)
                                Text(auth.profile?.friendCode ?? "—").font(.system(size: 13, weight: .medium, design: .monospaced)).lineLimit(1).textSelection(.enabled).foregroundStyle(.secondary)
                                Spacer()
                                if let code = auth.profile?.friendCode { ShareLink(item: code) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel(L.text("share_id")) }
                            }
                        }.padding(22).background(Color.panel, in: RoundedRectangle(cornerRadius: 24))
                        HStack(spacing: 12) {
                            TextField(L.text("friend_id"), text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled().font(.system(.body, design: .monospaced)).onChange(of: code) { _, value in code = String(value.uppercased().filter { "0123456789ABCDEF".contains($0) }.prefix(10)) }
                            Button { perform { token in _ = try await BackendService.shared.requestFriend(code: code, accessToken: token); code = "" } } label: { Image(systemName: "plus").font(.headline).frame(width: 42, height: 42).background(Color.primary, in: Circle()).foregroundStyle(Color.canvas) }.disabled(code.count != 10 || busy).accessibilityLabel(L.text("add_friend"))
                        }.padding(14).background(Color.panel, in: RoundedRectangle(cornerRadius: 22))
                        Picker(L.text("competition_day"), selection: $yesterday) { Text(L.text("today")).tag(false); Text(L.text("yesterday")).tag(true) }.pickerStyle(.segmented).onChange(of: yesterday) { _, _ in Task { await refresh() } }
                        VStack(alignment: .leading, spacing: 16) {
                            HStack { Text(L.text("daily_board")).font(.headline); Spacer(); if busy { ProgressView() } }
                            Text(L.text("board_utc")).font(.caption).foregroundStyle(.secondary)
                            if leaderboard.isEmpty { Text(L.text("board_empty")).font(.subheadline).foregroundStyle(.secondary) }
                            ForEach(leaderboard, id: \.userID) { row in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(String(format: "%02d", row.rank)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 25)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(name(row.displayName ?? (row.isMe ? auth.profile?.displayName ?? auth.session?.displayName : nil))).font(AppFont.text(15, weight: row.isMe ? .semibold : .regular))
                                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                        if row.isMe { Text(L.text("you")).font(AppFont.text(11)).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Text("\(row.repetitions)").font(AppFont.numeric(28)).fixedSize()
                                }.padding(.vertical, 4)
                            }
                        }.padding(22).background(Color.panel, in: RoundedRectangle(cornerRadius: 24))
                        if !friends.isEmpty {
                            Text(L.text("connections")).font(.headline)
                            ForEach(friends, id: \.userID) { friend in
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(name(friend.displayName)).font(AppFont.text(15)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                        Text(L.text("friend_" + friend.status)).font(AppFont.text(12)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if friend.status == "incoming" {
                                        Button { perform { token in try await BackendService.shared.respondToFriend(userID: friend.userID, accept: true, accessToken: token) } } label: { Image(systemName: "checkmark.circle") }.accessibilityLabel(L.text("accept"))
                                        Button { perform { token in try await BackendService.shared.respondToFriend(userID: friend.userID, accept: false, accessToken: token) } } label: { Image(systemName: "xmark.circle") }.accessibilityLabel(L.text("decline"))
                                    } else {
                                        Menu {
                                            Button(L.text("remove_friend"), role: .destructive) { perform { token in try await BackendService.shared.removeFriend(userID: friend.userID, accessToken: token) } }
                                            Button(L.text("block_friend"), role: .destructive) { perform { token in try await BackendService.shared.blockUser(userID: friend.userID, accessToken: token) } }
                                        } label: { Image(systemName: "ellipsis").frame(width: 40, height: 40) }
                                    }
                                }.padding(18).background(Color.panel, in: RoundedRectangle(cornerRadius: 20)).disabled(busy)
                            }
                        }
                        if !blocked.isEmpty {
                            Text(L.text("blocked_users")).font(.headline)
                            ForEach(blocked) { user in
                                HStack {
                                    Text(name(user.displayName)).font(AppFont.text(15)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    Button(L.text("unblock")) { perform { token in try await BackendService.shared.unblockUser(userID: user.userID, accessToken: token) } }.font(.caption).disabled(busy)
                                }.padding(18).background(Color.panel, in: RoundedRectangle(cornerRadius: 20))
                            }
                        }
                        Text(L.text("guest_history_note")).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error { StatusNote(text: error) }
                    if let error = auth.errorMessage { StatusNote(text: error) }
                }
                }
            }.background(Color.canvas).toolbar(.hidden, for: .navigationBar).refreshable { await model.synchronize(); await refresh() }
                .task(id: auth.session?.userID) { if auth.session != nil { await refresh() } else { loadVersion += 1; friends = []; leaderboard = []; blocked = []; busy = false; error = nil } }
        }
    }
    private var profileName: String { name(auth.profile?.displayName ?? auth.session?.displayName) }

    private func name(_ value: String?) -> String {
        ProfileName.normalized(value) ?? L.text("participant_name")
    }

    private func perform(_ operation: @escaping (String) async throws -> Void) {
        Task {
            busy = true; error = nil
            do { let token = try await auth.validAccessToken(); try await operation(token) }
            catch { self.error = error.localizedDescription }
            busy = false
            await refresh()
        }
    }
    private func refresh() async {
        guard let owner = auth.session?.userID else { return }
        let selectedYesterday = yesterday
        let day = boardDay
        loadVersion += 1
        let version = loadVersion
        busy = true
        defer { if loadVersion == version { busy = false } }
        do {
            let token = try await auth.validAccessToken()
            try await auth.refreshProfile()
            guard auth.session?.userID == owner else { return }
            async let fetchedFriends = BackendService.shared.friends(accessToken: token)
            async let fetchedBoard = BackendService.shared.leaderboard(day: day, accessToken: token)
            async let fetchedBlocked = BackendService.shared.blockedFriends(accessToken: token)
            let result = try await (fetchedFriends, fetchedBoard, fetchedBlocked)
            guard auth.session?.userID == owner, loadVersion == version, yesterday == selectedYesterday else { return }
            (friends, leaderboard, blocked) = result
            error = nil
        } catch { if auth.session?.userID == owner, loadVersion == version { self.error = error.localizedDescription } }
    }
}

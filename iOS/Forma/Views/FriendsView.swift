import SwiftUI
import AuthenticationServices

struct AppleLoginButton: View {
    @EnvironmentObject private var auth: AuthService
    @Environment(\.colorScheme) private var colorScheme
    var deletion = false
    var body: some View {
        SignInWithAppleButton(.continue) { request in auth.prepareAppleSignIn(request, forAccountDeletion: deletion) } onCompletion: { result in Task { await auth.completeAppleSignIn(result) } }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 54).clipShape(Capsule()).disabled(auth.isBusy || !AppConfiguration.isBackendConfigured)
            .accessibilityIdentifier("apple_sign_in")
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
                            Text(L.text("your_id").uppercased()).font(AppFont.text(10, weight: .bold)).tracking(2).foregroundStyle(.secondary)
                            HStack {
                                Text(auth.profile?.friendCode ?? "—").font(.system(size: 25, weight: .medium, design: .monospaced)).tracking(2).minimumScaleFactor(0.65).lineLimit(1).textSelection(.enabled)
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
                                    Text(row.isMe ? L.text("you") : row.friendCode).font(.system(size: 14, weight: row.isMe ? .bold : .regular, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    Text("\(row.repetitions)").font(AppFont.numeric(28)).fixedSize()
                                }.padding(.vertical, 4)
                            }
                        }.padding(22).background(Color.panel, in: RoundedRectangle(cornerRadius: 24))
                        if !friends.isEmpty {
                            Text(L.text("connections")).font(.headline)
                            ForEach(friends, id: \.userID) { friend in
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) { Text(friend.friendCode).font(.system(.subheadline, design: .monospaced)); Text(L.text("friend_" + friend.status)).font(.caption).foregroundStyle(.secondary) }
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
                                    Text(user.friendCode).font(.system(.subheadline, design: .monospaced))
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

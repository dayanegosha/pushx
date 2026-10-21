import SwiftUI
import StoreKit

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthService
    @EnvironmentObject private var store: WorkoutStore
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var subscription: SubscriptionService
    @StateObject private var health = HealthService.shared
    @AppStorage("theme") private var theme = "system"
    @AppStorage("language") private var language = "system"
    @AppStorage("voiceEnabled") private var voice = false
    @AppStorage("hapticsEnabled") private var haptics = true
    @AppStorage("healthEnabled") private var healthEnabled = false
    @AppStorage("dailyGoal") private var goal = 50
    @State private var plus = false
    @State private var deletion = false
    @State private var privacy = false
    @State private var manageSubscriptions = false
    @State private var goalEditor = DevelopmentLaunch.goalEditor
    @State private var nameEditor = false

    private var profileName: String {
        ProfileName.normalized(auth.profile?.displayName ?? auth.session?.displayName) ?? L.text("participant_name")
    }

    var body: some View {
        NavigationStack {
            AdaptiveForm {
                Section { PageTitle(title: L.text("settings")).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 8, trailing: 0)) }
                Section(L.text("appearance")) {
                    AppearanceMenuRow(title: L.text("theme"), value: L.text(theme), selection: $theme, identifier: "appearance_theme") {
                        ForEach(AppTheme.allCases) { value in Text(L.text(value.rawValue)).tag(value.rawValue) }
                    }
                    AppearanceMenuRow(title: L.text("language"), value: (AppLanguage(rawValue: language) ?? .system).title, selection: $language, identifier: "appearance_language") {
                        ForEach(AppLanguage.allCases) { value in Text(value.title).tag(value.rawValue) }
                    }
                    AccentPickerRow()
                }
                Section(L.text("workout")) {
                    Toggle(L.text("voice"), isOn: $voice)
                    Toggle(L.text("haptics"), isOn: $haptics)
                    Button { goalEditor = true } label: {
                        HStack { Text(L.text("goal_title")); Spacer(); Text("\(goal)").foregroundStyle(.secondary).monospacedDigit(); Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }.foregroundStyle(.primary)
                    }.accessibilityIdentifier("daily_goal_editor")
                }
                Section {
                    Toggle("Apple Health", isOn: Binding(get: { healthEnabled }, set: { enabled in
                        if enabled {
                            Task {
                                healthEnabled = await health.requestAuthorization()
                                if healthEnabled { await model.synchronizeHealth() }
                            }
                        } else { healthEnabled = false; model.healthError = nil }
                    })).disabled(!health.isAvailable || health.isBusy)
                    if healthEnabled {
                        Button(L.text("sync_health")) { Task { await model.synchronizeHealth() } }.disabled(health.isBusy)
                    }
                    if let error = model.healthError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                    if let error = health.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("Apple Health") } footer: { Text(L.text("health_settings_body")) }
                Section {
                    if auth.session != nil {
                        Button { nameEditor = true } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text(L.text("profile_name"))
                                Spacer(minLength: 0)
                                Text(profileName).foregroundStyle(.secondary).multilineTextAlignment(.trailing).lineLimit(2)
                                Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                            }.font(AppFont.text(16)).foregroundStyle(.primary)
                        }.disabled(auth.isBusy).accessibilityLabel(L.text("edit_name"))
                            .accessibilityValue(profileName).accessibilityIdentifier("edit_profile_name")
                        LabeledContent(L.text("your_id"), value: auth.profile?.friendCode ?? "—")
                        Button(L.text("sync_now")) { Task { await model.synchronize() } }.disabled(model.syncing)
                        Button(L.text("sign_out")) { Task { await auth.signOut() } }.disabled(auth.isBusy)
                        Button(L.text("delete_account"), role: .destructive) { deletion = true }
                        if let error = auth.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            AppleLoginButton().frame(maxWidth: 420).frame(maxWidth: .infinity)
                            if !AppConfiguration.isBackendConfigured {
                                Text(L.text("backend_not_configured")).font(.footnote).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let error = auth.errorMessage {
                                Text(error).font(.footnote).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }.padding(.vertical, 8).listRowSeparator(.hidden)
                    }
                } header: { Text(L.text("account")) } footer: { Text(L.text("account_footer")) }
                Section {
                    Button { plus = true } label: { HStack { Text(subscription.isPremium ? L.text("plus_active") : "pushx Plus"); Spacer(); Image(systemName: "plus.circle") } }
                    Button(L.text("restore_purchases")) { Task { await subscription.restore() } }.disabled(subscription.isLoading)
                    Button(L.text("manage_subscription")) { manageSubscriptions = true }
                    if let error = subscription.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text(L.text("subscription")) } footer: { Text(L.text("free_core")) }
                Section {
                    Button(L.text("privacy")) { privacy = true }
                    if let url = AppConfiguration.termsURL { Link(L.text("terms"), destination: url) }
                    LabeledContent(L.text("version"), value: "1.0.0 (1)")
                }
            }.toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $plus) { PlusView().adaptiveSheet() }
                .sheet(isPresented: $deletion) { DeleteAccountView().adaptiveSheet() }
                .sheet(isPresented: $privacy) { PrivacyView().adaptiveSheet() }
                .sheet(isPresented: $goalEditor) { GoalEditorView(goal: $goal).adaptiveSheet() }
                .sheet(isPresented: $nameEditor) { NameEditorView(name: auth.profile?.displayName ?? auth.session?.displayName ?? "").adaptiveSheet() }
                .manageSubscriptionsSheet(isPresented: $manageSubscriptions)
                .onAppear { health.refreshAuthorization() }
        }
    }
}

struct DeleteAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthService
    var body: some View {
        NavigationStack {
            ScrollView {
                AdaptiveContent(maxWidth: 640) {
                VStack(alignment: .leading, spacing: 24) {
                PageTitle(title: L.text("delete_account"))
                Text(L.text("delete_account_body")).foregroundStyle(.secondary)
                StatusNote(text: L.text("delete_subscription_note"))
                AppleLoginButton(deletion: true).frame(maxWidth: 420).frame(maxWidth: .infinity)
                if auth.isBusy { ProgressView() }
                if let error = auth.errorMessage { StatusNote(text: error) }
                }
                }
            }.background(Color.canvas).toolbar { ToolbarItem(placement: .cancellationAction) { Button(L.text("cancel")) { dismiss() } } }
        }
    }
}

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                AdaptiveContent(maxWidth: 640) {
                VStack(alignment: .leading, spacing: 24) {
                    PageTitle(title: L.text("privacy"))
                    Text(L.text("privacy_body")).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                    if let url = AppConfiguration.privacyURL { Link(L.text("full_privacy"), destination: url) }
                }
                }
            }.background(Color.canvas).toolbar { ToolbarItem(placement: .confirmationAction) { Button(L.text("done")) { dismiss() } } }
        }
    }
}

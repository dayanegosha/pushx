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

    var body: some View {
        NavigationStack {
            Form {
                Section { PageTitle(eyebrow: L.text("make_it_yours"), title: L.text("settings")).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 8, trailing: 0)) }
                Section(L.text("appearance")) {
                    Picker(L.text("theme"), selection: $theme) { ForEach(AppTheme.allCases) { value in Text(L.text(value.rawValue)).tag(value.rawValue) } }
                    Picker(L.text("language"), selection: $language) { ForEach(AppLanguage.allCases) { value in Text(value.title).tag(value.rawValue) } }
                }
                Section(L.text("workout")) {
                    Toggle(L.text("voice"), isOn: $voice)
                    Toggle(L.text("haptics"), isOn: $haptics)
                    Stepper(L.format("daily_goal", goal), value: $goal, in: 5...500, step: 5)
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
                        LabeledContent(L.text("your_id"), value: auth.profile?.friendCode ?? "—")
                        Button(L.text("sync_now")) { Task { await model.synchronize() } }.disabled(model.syncing)
                        Button(L.text("sign_out")) { Task { await auth.signOut() } }.disabled(auth.isBusy)
                        Button(L.text("delete_account"), role: .destructive) { deletion = true }
                    } else {
                        AppleLoginButton().listRowBackground(Color.clear)
                        if !AppConfiguration.isBackendConfigured { Text(L.text("backend_not_configured")).font(.footnote).foregroundStyle(.secondary) }
                    }
                    if let error = auth.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text(L.text("account")) } footer: { Text(L.text("account_footer")) }
                Section {
                    Button { plus = true } label: { HStack { Text(subscription.isPremium ? L.text("plus_active") : "FORMA Plus"); Spacer(); Image(systemName: "plus.circle") } }
                    Button(L.text("restore_purchases")) { Task { await subscription.restore() } }.disabled(subscription.isLoading)
                    Button(L.text("manage_subscription")) { manageSubscriptions = true }
                    if let error = subscription.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text(L.text("subscription")) } footer: { Text(L.text("free_core")) }
                Section {
                    Button(L.text("privacy")) { privacy = true }
                    if let url = AppConfiguration.termsURL { Link(L.text("terms"), destination: url) }
                    LabeledContent(L.text("version"), value: "1.0.0 (1)")
                }
            }.tint(.primary).scrollContentBackground(.hidden).background(Color.canvas).toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $plus) { PlusView() }
                .sheet(isPresented: $deletion) { DeleteAccountView() }
                .sheet(isPresented: $privacy) { PrivacyView() }
                .manageSubscriptionsSheet(isPresented: $manageSubscriptions)
                .onAppear { health.refreshAuthorization() }
                .onChange(of: auth.lastDeletedUserID) { _, user in if let user { store.deleteOwned(by: user); deletion = false } }
        }
    }
}

struct DeleteAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthService
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                PageTitle(eyebrow: "FORMA", title: L.text("delete_account"))
                Text(L.text("delete_account_body")).foregroundStyle(.secondary)
                StatusNote(text: L.text("delete_subscription_note"))
                AppleLoginButton(deletion: true)
                if auth.isBusy { ProgressView() }
                if let error = auth.errorMessage { StatusNote(text: error) }
                Spacer()
            }.padding(26).toolbar { ToolbarItem(placement: .cancellationAction) { Button(L.text("cancel")) { dismiss() } } }
        }
    }
}

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PageTitle(eyebrow: "FORMA", title: L.text("privacy"))
                    Text(L.text("privacy_body")).lineSpacing(6)
                    if let url = AppConfiguration.privacyURL { Link(L.text("full_privacy"), destination: url) }
                }.padding(26)
            }.toolbar { ToolbarItem(placement: .confirmationAction) { Button(L.text("done")) { dismiss() } } }
        }
    }
}

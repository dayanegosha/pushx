import SwiftUI

@main struct FormaApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var auth = AuthService.shared
    @StateObject private var subscription = SubscriptionService.shared
    @AppStorage("theme") private var theme = "system"
    @AppStorage("language") private var language = "system"
    @AppStorage("accentColor") private var accentColor = "violet"
    @Environment(\.scenePhase) private var scenePhase
    @State private var startupComplete = false

    var body: some Scene {
        WindowGroup {
            Group {
                if startupComplete { RootView() }
                else { Brand().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.canvas) }
            }
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(auth)
                .environmentObject(subscription)
                .font(AppFont.text(15))
                .preferredColorScheme(theme == "system" ? nil : theme == "dark" ? .dark : .light)
                .tint((AccentChoice(rawValue: accentColor) ?? .violet).color)
                .accentColor((AccentChoice(rawValue: accentColor) ?? .violet).color)
                .environment(\.locale, Locale(identifier: L.language))
                .id(language)
                .task {
                    await auth.restoreSession()
                    startupComplete = true
                    await subscription.start()
                    await model.synchronize()
                }
                .onChange(of: scenePhase) { _, value in
                    if value == .active { Task { await subscription.refresh(); await model.synchronize() } }
                }
                .onChange(of: auth.session?.userID) { _, _ in
                    Task { await model.synchronize() }
                }
                .onChange(of: auth.lastDeletedUserID) { _, user in
                    if let user { model.store.deleteOwned(by: user) }
                }
        }
    }
}

import SwiftUI

@main struct FormaApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var auth = AuthService.shared
    @StateObject private var subscription = SubscriptionService.shared
    @AppStorage("theme") private var theme = "system"
    @AppStorage("language") private var language = "system"
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(auth)
                .environmentObject(subscription)
                .preferredColorScheme(theme == "system" ? nil : theme == "dark" ? .dark : .light)
                .environment(\.locale, Locale(identifier: L.language))
                .id(language)
                .task {
                    await auth.restoreSession()
                    await subscription.start()
                    await model.synchronize()
                }
                .onChange(of: scenePhase) { _, value in
                    if value == .active { Task { await subscription.refresh(); await model.synchronize() } }
                }
                .onChange(of: auth.session?.userID) { _, _ in
                    Task { await model.synchronize() }
                }
        }
    }
}

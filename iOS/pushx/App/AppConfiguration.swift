import Foundation

enum AppConfiguration {
    static var supabaseURL: URL? { configuredURL("SUPABASE_URL") }
    static var supabaseAnonKey: String { Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String ?? "" }
    static let subscriptionIDs = AppIdentifiers.subscriptionIDs
    static var privacyURL: URL? { configuredURL("PRIVACY_URL") }
    static var termsURL: URL? { configuredURL("TERMS_URL") }
    static var isBackendConfigured: Bool { supabaseURL != nil && !supabaseAnonKey.isEmpty }
    private static func configuredURL(_ key: String) -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, russian = "ru", english = "en", chinese = "zh-Hans"
    var id: String { rawValue }
    var title: String { switch self { case .system: return L.text("system"); case .russian: return "Русский"; case .english: return "English"; case .chinese: return "简体中文" } }
    var code: String { self == .system ? (Bundle.main.preferredLocalizations.first ?? "en") : rawValue }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
}

enum L {
    static var language: String { AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "system")?.code ?? "en" }
    static func text(_ key: String) -> String {
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: text(key), locale: Locale(identifier: language), arguments: args)
    }
}

enum DevelopmentLaunch {
    static var allowLocalSession: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PUSHX_LOCAL_PREVIEW"] == "1"
        #else
        return false
        #endif
    }
    static var tab: Int {
        #if DEBUG
        let value = ProcessInfo.processInfo.environment["PUSHX_SCREEN"] ?? "0"
        return value == "goal" ? 3 : Int(value) ?? 0
        #else
        return 0
        #endif
    }
    static var workout: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PUSHX_SCREEN"] == "workout"
        #else
        return false
        #endif
    }
    static var goalEditor: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PUSHX_SCREEN"] == "goal"
        #else
        return false
        #endif
    }
}

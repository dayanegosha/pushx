import Foundation

/// User-facing service failures are translated using the app's selected language.
/// Server response bodies are intentionally never presented verbatim.
enum ServiceError: LocalizedError {
    case notConfigured
    case notSignedIn
    case invalidAppleCredential
    case invalidResponse
    case secureStorage
    case verificationFailed
    case productsUnavailable
    case server(status: Int, code: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return ServiceCopy.text("Cloud features are not configured in this build.", "Облачные функции ещё не настроены в этой сборке.", "此版本尚未配置云功能。")
        case .notSignedIn:
            return ServiceCopy.text("Sign in with Apple to continue.", "Чтобы продолжить, войдите через Apple.", "请使用 Apple 登录后继续。")
        case .invalidAppleCredential:
            return ServiceCopy.text("Apple could not confirm this sign-in. Please try again.", "Apple не удалось подтвердить вход. Попробуйте снова.", "Apple 无法确认此次登录，请重试。")
        case .invalidResponse:
            return ServiceCopy.text("The server returned an unexpected response. Please try again.", "Сервер вернул неожиданный ответ. Попробуйте снова.", "服务器返回了意外响应，请重试。")
        case .secureStorage:
            return ServiceCopy.text("The session could not be saved securely on this iPhone.", "Не удалось безопасно сохранить сеанс на этом iPhone.", "无法在此 iPhone 上安全保存会话。")
        case .verificationFailed:
            return ServiceCopy.text("The App Store purchase could not be verified.", "Не удалось проверить покупку в App Store.", "无法验证 App Store 购买。")
        case .productsUnavailable:
            return ServiceCopy.text("Subscriptions are currently unavailable. You can keep using FORMA for free.", "Подписки сейчас недоступны. Вы можете продолжать пользоваться FORMA бесплатно.", "订阅暂不可用，您仍可免费使用 FORMA。")
        case .server(let status, let code):
            if code.contains("apple") || code.contains("reauth") || code.contains("identity") || code.contains("revoke") {
                return ServiceCopy.text("Please authorize the same Apple account again to delete your FORMA account.", "Для удаления аккаунта FORMA повторно подтвердите вход в тот же аккаунт Apple.", "请重新授权同一个 Apple 账户以删除 FORMA 账户。")
            }
            if status == 401 || ["session_expired", "refresh_token_not_found", "refresh_token_already_used", "bad_jwt", "invalid_jwt"].contains(where: { code.contains($0) }) {
                return ServiceCopy.text("Your session has expired. Please sign in again.", "Срок действия сеанса истёк. Войдите снова.", "会话已过期，请重新登录。")
            }
            if code.contains("friend_not_found") || code.contains("invalid_friend_code") || code.contains("friend_unavailable") {
                return ServiceCopy.text("No account was found with this friend ID.", "Аккаунт с таким ID друга не найден.", "未找到使用此好友 ID 的账户。")
            }
            if code.contains("self") {
                return ServiceCopy.text("Use another person's friend ID.", "Введите ID другого пользователя.", "请输入其他用户的好友 ID。")
            }
            if code.contains("blocked") {
                return ServiceCopy.text("This friend request is unavailable.", "Этот запрос в друзья недоступен.", "无法发送此好友请求。")
            }
            if code.contains("friend_limit") || code.contains("too_many_pending") || code.contains("friend_request_rate") {
                return ServiceCopy.text("The friend request limit has been reached. Please try again later or remove an existing request.", "Достигнут лимит запросов в друзья. Повторите попытку позже или удалите существующий запрос.", "已达到好友请求上限，请稍后重试或删除已有请求。")
            }
            if code.contains("workout") || code.contains("repetitions") || code.contains("overlap") || code.contains("daily_limit") {
                return ServiceCopy.text("This workout could not be synchronized. Check its duration, date and repetition count. Your local record is saved.", "Не удалось синхронизировать тренировку. Проверьте длительность, дату и число повторений. Локальная запись сохранена.", "无法同步此训练，请检查时长、日期和次数。本地记录已保存。")
            }
            if status == 429 {
                return ServiceCopy.text("Too many requests. Please try again shortly.", "Слишком много запросов. Повторите попытку чуть позже.", "请求过多，请稍后重试。")
            }
            return ServiceCopy.text("The operation could not be completed. Please try again. (\(status))", "Не удалось выполнить действие. Попробуйте снова. (\(status))", "无法完成操作，请重试。 (\(status))")
        }
    }
}

enum ServiceCopy {
    static func text(_ english: String, _ russian: String, _ chinese: String) -> String {
        if L.language.hasPrefix("ru") { return russian }
        if L.language.hasPrefix("zh") { return chinese }
        return english
    }

    static func message(for error: Error) -> String {
        if let error = error as? ServiceError { return error.localizedDescription }
        if let error = error as? URLError {
            if error.code == .notConnectedToInternet || error.code == .networkConnectionLost || error.code == .timedOut {
                return text("No connection. Your workouts remain saved on this iPhone. Try again when you're online.", "Нет соединения. Тренировки сохранены на этом iPhone. Повторите попытку, когда появится интернет.", "网络未连接，训练仍保存在此 iPhone 上。请联网后重试。")
            }
        }
        return text("Something went wrong. Please try again.", "Не удалось выполнить действие. Попробуйте снова.", "出现问题，请重试。")
    }
}

enum ServiceDates {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: string) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    static func dayUTC(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let result = date(value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date")
            }
            return result
        }
        return decoder
    }
}

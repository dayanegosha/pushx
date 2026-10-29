import Combine
import Foundation
import HealthKit

@MainActor
final class HealthService: ObservableObject {
    static let shared = HealthService()
    @Published private(set) var isAuthorized = false
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let store = HKHealthStore()
    private let workoutType = HKObjectType.workoutType()
    private var savingTasks: [UUID: Task<Void, Error>] = [:]

    private init() { refreshAuthorization() }

    func refreshAuthorization() {
        isAuthorized = isAvailable && store.authorizationStatus(for: workoutType) == .sharingAuthorized
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        guard isAvailable, !isBusy else { return isAuthorized }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await store.requestAuthorization(toShare: [workoutType], read: [])
            refreshAuthorization()
            if !isAuthorized {
                errorMessage = ServiceCopy.text("Allow pushx to add workouts in Health permissions to enable this feature.", "Разрешите pushx добавлять тренировки в настройках доступа приложения «Здоровье».", "请在“健康”权限中允许 pushx 添加训练。")
            }
        } catch { errorMessage = healthMessage(error) }
        return isAuthorized
    }

    func saveWorkout(id: UUID, start: Date, end: Date, repetitions: Int) async throws {
        refreshAuthorization()
        guard isAuthorized else { throw HealthFailure.permissionRequired }
        guard WorkoutRecord.isValid(start: start, end: end, repetitions: repetitions, mode: "camera") else { throw HealthFailure.invalidWorkout }
        if let task = savingTasks[id] { return try await task.value }
        let task = Task { try await self.writeWorkout(id: id, start: start, end: end, repetitions: repetitions) }
        savingTasks[id] = task
        defer { savingTasks[id] = nil }
        try await task.value
    }

    private func writeWorkout(id: UUID, start: Date, end: Date, repetitions: Int) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .unknown
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        do {
            try await builder.beginCollection(at: start)
            try await builder.addMetadata([
                HKMetadataKeySyncIdentifier: AppIdentifiers.healthSyncPrefix + id.uuidString.lowercased(),
                HKMetadataKeySyncVersion: 1,
                HKMetadataKeyWorkoutBrandName: "pushx",
                AppIdentifiers.repetitionsMetadataKey: repetitions
            ])
            try await builder.endCollection(at: end)
            guard try await builder.finishWorkout() != nil else { throw HealthFailure.saveFailed }
        } catch {
            builder.discardWorkout()
            let failure = HealthFailure.saveFailed
            errorMessage = healthMessage(error)
            if let known = error as? HealthFailure { throw known }
            throw failure
        }
    }

    private func healthMessage(_ error: Error) -> String {
        if let failure = error as? HealthFailure { return failure.localizedDescription }
        return ServiceCopy.text("The workout could not be saved to Apple Health. Your pushx record is saved; you can retry from history.", "Не удалось сохранить тренировку в Apple Health. Запись в pushx сохранена; повторите попытку в истории.", "无法将训练存入 Apple 健康。pushx 记录已保存，可在历史中重试。")
    }
}

private enum HealthFailure: LocalizedError {
    case permissionRequired, invalidWorkout, saveFailed
    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return ServiceCopy.text("Allow pushx to add workouts in Apple Health.", "Разрешите pushx добавлять тренировки в Apple Health.", "请允许 pushx 向 Apple 健康添加训练。")
        case .invalidWorkout:
            return ServiceCopy.text("Only a completed workout with repetitions can be added to Apple Health.", "В Apple Health можно добавить завершённую тренировку с повторениями.", "仅可将包含次数的已完成训练添加到 Apple 健康。")
        case .saveFailed:
            return ServiceCopy.text("The workout could not be saved to Apple Health. You can retry from history.", "Не удалось сохранить тренировку в Apple Health. Повторите попытку в истории.", "无法将训练存入 Apple 健康，可在历史中重试。")
        }
    }
}

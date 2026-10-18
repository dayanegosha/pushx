import Foundation
import SwiftUI

struct WorkoutRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var repetitions: Int
    var detectionMode: String
    var ownerID: UUID?
    var cloudSynced: Bool = false
    var healthSynced: Bool = false
    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
}

struct WorkoutDraft: Codable {
    var id: UUID
    var startedAt: Date
    var updatedAt: Date
    var repetitions: Int
    var detectionMode: String
    var ownerID: UUID?
}

@MainActor final class WorkoutStore: ObservableObject {
    @Published private(set) var records: [WorkoutRecord] = []
    @Published var storageError: String?
    @Published var recoveredWorkout = false
    private var draft: WorkoutDraft?
    private let url: URL
    private struct Archive: Codable { var records: [WorkoutRecord]; var draft: WorkoutDraft? }

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Forma", isDirectory: true)
        url = base.appendingPathComponent("workouts.json")
        #if DEBUG
        if ProcessInfo.processInfo.environment["FORMA_RESET_DATA"] == "1" { try? FileManager.default.removeItem(at: url) }
        #endif
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
                records = archive.records
                if let pending = archive.draft, pending.repetitions > 0 {
                    records.removeAll { $0.id == pending.id }
                    records.append(WorkoutRecord(id: pending.id, startedAt: pending.startedAt, endedAt: pending.updatedAt, repetitions: pending.repetitions, detectionMode: pending.detectionMode, ownerID: pending.ownerID))
                    recoveredWorkout = true
                }
                persist()
            }
        } catch { storageError = L.text("storage_error") }
    }

    func visible(for owner: UUID?) -> [WorkoutRecord] {
        records.filter { $0.ownerID == owner || $0.ownerID == nil }.sorted { $0.endedAt > $1.endedAt }
    }
    func updateDraft(_ value: WorkoutDraft) { draft = value; persist() }
    func clearDraft() { draft = nil; persist() }
    func save(_ record: WorkoutRecord) { records.removeAll { $0.id == record.id }; records.append(record); draft = nil; persist() }
    func markCloud(_ id: UUID) { if let i = records.firstIndex(where: { $0.id == id }) { records[i].cloudSynced = true; persist() } }
    func markHealth(_ id: UUID) { if let i = records.firstIndex(where: { $0.id == id }) { records[i].healthSynced = true; persist() } }
    func deleteOwned(by owner: UUID) {
        records.removeAll { $0.ownerID == owner }
        if draft?.ownerID == owner { draft = nil }
        persist()
    }
    func merge(_ remote: [RemoteWorkout], owner: UUID) {
        for record in remote where !records.contains(where: { $0.id == record.id }) {
            records.append(WorkoutRecord(id: record.id, startedAt: record.startedAt, endedAt: record.endedAt, repetitions: record.repetitions, detectionMode: record.detectionMode, ownerID: owner, cloudSynced: true))
        }
        persist()
    }
    private func persist() {
        do {
            let data = try JSONEncoder().encode(Archive(records: records, draft: draft))
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            storageError = nil
        } catch { storageError = L.text("storage_error") }
    }
    func csv(for owner: UUID?) -> String {
        let formatter = ISO8601DateFormatter()
        return "id,started_at,ended_at,repetitions,mode\n" + visible(for: owner).map {
            "\($0.id.uuidString),\(formatter.string(from: $0.startedAt)),\(formatter.string(from: $0.endedAt)),\($0.repetitions),\($0.detectionMode)"
        }.joined(separator: "\n")
    }
}

@MainActor final class AppModel: ObservableObject {
    let store: WorkoutStore
    @Published var syncing = false
    @Published var syncError: String?
    @Published var healthError: String?
    init(store: WorkoutStore? = nil) { self.store = store ?? WorkoutStore() }

    func synchronize() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        if UserDefaults.standard.bool(forKey: "healthEnabled") {
            await synchronizeHealth()
        }
        let auth = AuthService.shared
        guard let owner = auth.session?.userID else { return }
        do {
            let pending = store.records.filter { $0.ownerID == owner && !$0.cloudSynced }
            var failedUpload = false
            for item in pending {
                guard auth.session?.userID == owner else { return }
                do {
                    let token = try await auth.validAccessToken()
                    guard auth.session?.userID == owner else { return }
                    _ = try await BackendService.shared.uploadWorkout(id: item.id, startedAt: item.startedAt, endedAt: item.endedAt, repetitions: item.repetitions, detectionMode: item.detectionMode, accessToken: token)
                    store.markCloud(item.id)
                } catch { failedUpload = true }
            }
            guard auth.session?.userID == owner else { return }
            let token = try await auth.validAccessToken()
            guard auth.session?.userID == owner else { return }
            let remote = try await BackendService.shared.workouts(accessToken: token)
            guard auth.session?.userID == owner else { return }
            store.merge(remote, owner: owner)
            if UserDefaults.standard.bool(forKey: "healthEnabled") { await synchronizeHealth() }
            syncError = failedUpload ? L.text("sync_error") : nil
        } catch { syncError = L.text("sync_error") }
    }
    func synchronizeHealth() async {
        let health = HealthService.shared
        health.refreshAuthorization()
        guard health.isAuthorized else { healthError = L.text("health_denied"); return }
        healthError = nil
        let owner = AuthService.shared.session?.userID
        for item in store.visible(for: owner) where !item.healthSynced {
            guard UserDefaults.standard.bool(forKey: "healthEnabled") else { return }
            guard AuthService.shared.session?.userID == owner else { return }
            do {
                try await health.saveWorkout(id: item.id, start: item.startedAt, end: item.endedAt, repetitions: item.repetitions)
                store.markHealth(item.id)
            } catch { healthError = L.text("health_error"); break }
        }
    }
}

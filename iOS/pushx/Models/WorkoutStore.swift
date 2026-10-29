import Foundation
import CryptoKit
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
    var isValid: Bool {
        Self.isValid(start: startedAt, end: endedAt, repetitions: repetitions, mode: detectionMode)
    }

    static func isValid(start: Date, end: Date, repetitions: Int, mode: String) -> Bool {
        let duration = end.timeIntervalSince(start)
        return start.timeIntervalSince1970.isFinite && end.timeIntervalSince1970.isFinite
            && (1...600).contains(repetitions) && ["camera", "touch"].contains(mode)
            && duration > 0 && duration.isFinite
    }
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
    private let defaults: UserDefaults
    private let deletionKey: String
    private var deletedOwners: Set<UUID>
    private struct Archive: Codable { var records: [WorkoutRecord]; var draft: WorkoutDraft? }

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        var base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(AppIdentifiers.workoutDirectory, isDirectory: true)
        url = base.appendingPathComponent("workouts.json")
        self.defaults = defaults
        let archivePath = url.resolvingSymlinksInPath().path
        let containerPath = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().path + "/"
        let identity = archivePath.hasPrefix(containerPath) ? String(archivePath.dropFirst(containerPath.count)) : archivePath
        let archiveID = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        deletionKey = "workoutDeletedOwners." + archiveID
        deletedOwners = Set((defaults.stringArray(forKey: deletionKey) ?? []).compactMap(UUID.init(uuidString:)))
        #if DEBUG
        if ProcessInfo.processInfo.environment["PUSHX_RESET_DATA"] == "1" { try? FileManager.default.removeItem(at: url) }
        #endif
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try base.setResourceValues(values)
            if FileManager.default.fileExists(atPath: url.path) {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
                var seen = Set<UUID>()
                let retainedRecords = archive.records.filter { !isDeleted($0.ownerID) }
                records = retainedRecords.filter { $0.isValid && seen.insert($0.id).inserted }
                let invalidRecords = records.count != retainedRecords.count
                if let pending = archive.draft, !isDeleted(pending.ownerID), WorkoutRecord.isValid(start: pending.startedAt, end: pending.updatedAt, repetitions: pending.repetitions, mode: pending.detectionMode),
                   !records.contains(where: { $0.id == pending.id && $0.ownerID != pending.ownerID }) {
                    records.removeAll { $0.id == pending.id }
                    records.append(WorkoutRecord(id: pending.id, startedAt: pending.startedAt, endedAt: pending.updatedAt, repetitions: pending.repetitions, detectionMode: pending.detectionMode, ownerID: pending.ownerID))
                    recoveredWorkout = true
                }
                persist()
                if invalidRecords { storageError = L.text("storage_error") }
            }
        } catch { storageError = L.text("storage_error") }
    }

    func visible(for owner: UUID?) -> [WorkoutRecord] {
        records.filter { $0.ownerID == owner || $0.ownerID == nil }.sorted { $0.endedAt > $1.endedAt }
    }
    func updateDraft(_ value: WorkoutDraft) {
        guard value.repetitions == 0 || WorkoutRecord.isValid(start: value.startedAt, end: value.updatedAt, repetitions: value.repetitions, mode: value.detectionMode),
              !isDeleted(value.ownerID),
              !records.contains(where: { $0.id == value.id && $0.ownerID != value.ownerID }) else {
            storageError = L.text("storage_error")
            return
        }
        draft = value
        persist()
    }
    @discardableResult
    func clearDraft() -> Bool {
        let previous = draft
        draft = nil
        guard persist() else { draft = previous; return false }
        return true
    }
    @discardableResult
    func save(_ record: WorkoutRecord) -> Bool {
        guard record.isValid, !isDeleted(record.ownerID), !records.contains(where: { $0.id == record.id && $0.ownerID != record.ownerID }) else {
            storageError = L.text("storage_error")
            return false
        }
        let previousRecords = records
        let previousDraft = draft
        records.removeAll { $0.id == record.id }
        records.append(record)
        if draft?.id == record.id && draft?.ownerID == record.ownerID { draft = nil }
        guard persist() else {
            records = previousRecords
            draft = previousDraft
            return false
        }
        return true
    }
    func markCloud(_ id: UUID) { if let i = records.firstIndex(where: { $0.id == id }) { records[i].cloudSynced = true; persist() } }
    func markHealth(_ id: UUID) { if let i = records.firstIndex(where: { $0.id == id }) { records[i].healthSynced = true; persist() } }
    @discardableResult
    func deleteOwned(by owner: UUID) -> Bool {
        deletedOwners.insert(owner)
        defaults.set(deletedOwners.map(\.uuidString).sorted(), forKey: deletionKey)
        records.removeAll { $0.ownerID == owner }
        if draft?.ownerID == owner { draft = nil }
        return persist()
    }
    func merge(_ remote: [RemoteWorkout], owner: UUID) {
        guard !isDeleted(owner) else { return }
        for record in remote where WorkoutRecord.isValid(start: record.startedAt, end: record.endedAt, repetitions: record.repetitions, mode: record.detectionMode)
            && !records.contains(where: { $0.id == record.id }) {
            records.append(WorkoutRecord(id: record.id, startedAt: record.startedAt, endedAt: record.endedAt, repetitions: record.repetitions, detectionMode: record.detectionMode, ownerID: owner, cloudSynced: true))
        }
        persist()
    }
    private func isDeleted(_ owner: UUID?) -> Bool {
        owner.map { deletedOwners.contains($0) } ?? false
    }
    @discardableResult
    private func persist() -> Bool {
        do {
            let data = try JSONEncoder().encode(Archive(records: records, draft: draft))
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            deletedOwners.removeAll()
            defaults.removeObject(forKey: deletionKey)
            storageError = nil
            return true
        } catch { storageError = L.text("storage_error"); return false }
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
                    guard auth.session?.userID == owner else { return }
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
                guard AuthService.shared.session?.userID == owner else { return }
                store.markHealth(item.id)
            } catch { healthError = L.text("health_error"); break }
        }
    }
}

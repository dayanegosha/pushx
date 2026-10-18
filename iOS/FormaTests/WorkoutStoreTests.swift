import XCTest
@testable import Forma

final class WorkoutStoreTests: XCTestCase {
    private let ownerA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let ownerB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let baseDate = Date(timeIntervalSince1970: 1_792_320_000)

    @MainActor
    func testSavedWorkoutSurvivesReloadWithAllFields() async throws {
        try withTemporaryDirectory { directory in
            let store = WorkoutStore(directory: directory)
            let original = record(repetitions: 27, owner: ownerA, offset: 60, mode: "touch")
            store.save(original)

            let reloaded = WorkoutStore(directory: directory)
            XCTAssertNil(store.storageError)
            XCTAssertNil(reloaded.storageError)
            XCTAssertEqual(reloaded.records, [original])
            XCTAssertEqual(reloaded.records.first?.duration, 60)
            XCTAssertFalse(reloaded.recoveredWorkout)
        }
    }

    @MainActor
    func testCloudAndHealthFlagsAreDurableAndScopedToTheirUUID() async throws {
        try withTemporaryDirectory { directory in
            let store = WorkoutStore(directory: directory)
            let synced = record(repetitions: 20, owner: ownerA)
            let untouched = record(repetitions: 9, owner: nil, offset: 120)
            store.save(synced)
            store.save(untouched)
            store.markCloud(synced.id)
            store.markHealth(synced.id)
            store.markCloud(UUID())

            let reloaded = WorkoutStore(directory: directory)
            let saved = try XCTUnwrap(reloaded.records.first { $0.id == synced.id })
            XCTAssertTrue(saved.cloudSynced)
            XCTAssertTrue(saved.healthSynced)
            let other = try XCTUnwrap(reloaded.records.first { $0.id == untouched.id })
            XCTAssertFalse(other.cloudSynced)
            XCTAssertFalse(other.healthSynced)
            XCTAssertEqual(reloaded.records.count, 2)
        }
    }

    @MainActor
    func testOwnerVisibilityKeepsGuestWorkoutsAndIsolatesAccounts() async throws {
        try withTemporaryDirectory { directory in
            let store = WorkoutStore(directory: directory)
            let guest = record(repetitions: 7, owner: nil)
            let alice = record(repetitions: 20, owner: ownerA, offset: 120)
            let bob = record(repetitions: 30, owner: ownerB, offset: 240)
            [guest, alice, bob].forEach(store.save)

            let reloaded = WorkoutStore(directory: directory)
            XCTAssertEqual(reloaded.visible(for: nil).map(\.id), [guest.id])
            XCTAssertEqual(reloaded.visible(for: ownerA).map(\.id), [alice.id, guest.id])
            XCTAssertEqual(reloaded.visible(for: ownerB).map(\.id), [bob.id, guest.id])
            XCTAssertEqual(reloaded.visible(for: UUID()).map(\.id), [guest.id])
            XCTAssertEqual(reloaded.records.count, 3)
        }
    }

    @MainActor
    func testRemoteMergeDeduplicatesUUIDsAcrossPagesAndRepeatedSyncs() async throws {
        try withTemporaryDirectory { directory in
            let store = WorkoutStore(directory: directory)
            var local = record(repetitions: 20, owner: ownerA)
            local.healthSynced = true
            store.save(local)
            let matching = remote(id: local.id, repetitions: 99)
            let newRemote = remote(repetitions: 35, offset: 180)

            store.merge([matching, newRemote, newRemote], owner: ownerA)
            store.merge([matching, newRemote], owner: ownerA)

            let reloaded = WorkoutStore(directory: directory)
            XCTAssertEqual(reloaded.records.count, 2)
            XCTAssertEqual(reloaded.records.first { $0.id == local.id }, local)
            let merged = try XCTUnwrap(reloaded.records.first { $0.id == newRemote.id })
            XCTAssertEqual(merged.ownerID, ownerA)
            XCTAssertEqual(merged.repetitions, 35)
            XCTAssertEqual(merged.startedAt, newRemote.startedAt)
            XCTAssertEqual(merged.endedAt, newRemote.endedAt)
            XCTAssertTrue(merged.cloudSynced)
            XCTAssertFalse(merged.healthSynced)
        }
    }

    @MainActor
    func testLatestPerRepDraftRecoversOnceWithoutDuplicatingSavedUUID() async throws {
        try withTemporaryDirectory { directory in
            let store = WorkoutStore(directory: directory)
            let original = record(repetitions: 2, owner: ownerA)
            store.save(original)
            for repetitions in 3...5 {
                store.updateDraft(WorkoutDraft(
                    id: original.id, startedAt: original.startedAt,
                    updatedAt: baseDate.addingTimeInterval(Double(repetitions) * 20),
                    repetitions: repetitions, detectionMode: "camera", ownerID: ownerA
                ))
            }

            let recovered = WorkoutStore(directory: directory)
            XCTAssertTrue(recovered.recoveredWorkout)
            XCTAssertEqual(recovered.records.count, 1)
            XCTAssertEqual(recovered.records.first?.id, original.id)
            XCTAssertEqual(recovered.records.first?.ownerID, ownerA)
            XCTAssertEqual(recovered.records.first?.repetitions, 5)
            XCTAssertEqual(recovered.records.first?.endedAt, baseDate.addingTimeInterval(100))

            let openedAgain = WorkoutStore(directory: directory)
            XCTAssertFalse(openedAgain.recoveredWorkout)
            XCTAssertEqual(openedAgain.records, recovered.records)
        }
    }

    @MainActor
    func testClearedAndZeroRepDraftsDoNotCreatePhantomWorkouts() async throws {
        try withTemporaryDirectory { directory in
            let store = WorkoutStore(directory: directory)
            let id = UUID()
            store.updateDraft(WorkoutDraft(id: id, startedAt: baseDate, updatedAt: baseDate,
                                           repetitions: 0, detectionMode: "touch", ownerID: nil))
            let zeroRepReload = WorkoutStore(directory: directory)
            XCTAssertTrue(zeroRepReload.records.isEmpty)
            XCTAssertFalse(zeroRepReload.recoveredWorkout)

            zeroRepReload.updateDraft(WorkoutDraft(id: id, startedAt: baseDate,
                                                   updatedAt: baseDate.addingTimeInterval(30),
                                                   repetitions: 10, detectionMode: "touch", ownerID: nil))
            zeroRepReload.clearDraft()
            let clearedReload = WorkoutStore(directory: directory)
            XCTAssertTrue(clearedReload.records.isEmpty)
            XCTAssertFalse(clearedReload.recoveredWorkout)
        }
    }

    @MainActor
    func testDeletingOwnerRemovesOwnedRecordsAndOwnedDraftDurably() async throws {
        try withTemporaryDirectory { directory in
            let store = WorkoutStore(directory: directory)
            let owned = record(repetitions: 20, owner: ownerA)
            let other = record(repetitions: 30, owner: ownerB, offset: 120)
            let guest = record(repetitions: 10, owner: nil, offset: 240)
            [owned, other, guest].forEach(store.save)
            store.updateDraft(WorkoutDraft(id: UUID(), startedAt: baseDate,
                                           updatedAt: baseDate.addingTimeInterval(30),
                                           repetitions: 7, detectionMode: "camera", ownerID: ownerA))

            store.deleteOwned(by: ownerA)

            let reloaded = WorkoutStore(directory: directory)
            XCTAssertFalse(reloaded.recoveredWorkout)
            XCTAssertEqual(Set(reloaded.records.map(\.id)), Set([other.id, guest.id]))
            XCTAssertEqual(reloaded.visible(for: ownerA).map(\.id), [guest.id])
            XCTAssertFalse(reloaded.records.contains { $0.ownerID == ownerA })
        }
    }

    @MainActor
    func testDeletingOwnerPreservesAndRecoversAnUnrelatedGuestDraft() async throws {
        try withTemporaryDirectory { directory in
            let store = WorkoutStore(directory: directory)
            let owned = record(repetitions: 20, owner: ownerA)
            let guest = record(repetitions: 10, owner: nil, offset: 120)
            let draftID = UUID()
            [owned, guest].forEach(store.save)
            store.updateDraft(WorkoutDraft(id: draftID, startedAt: baseDate,
                                           updatedAt: baseDate.addingTimeInterval(30),
                                           repetitions: 6, detectionMode: "touch", ownerID: nil))

            store.deleteOwned(by: ownerA)

            let reloaded = WorkoutStore(directory: directory)
            XCTAssertTrue(reloaded.recoveredWorkout)
            XCTAssertEqual(Set(reloaded.records.map(\.id)), Set([guest.id, draftID]))
            XCTAssertTrue(reloaded.records.allSatisfy { $0.ownerID == nil })
            XCTAssertEqual(reloaded.records.first { $0.id == draftID }?.repetitions, 6)
            XCTAssertEqual(reloaded.visible(for: nil).count, 2)
        }
    }

    private func record(repetitions: Int, owner: UUID?, offset: TimeInterval = 0,
                        mode: String = "camera") -> WorkoutRecord {
        WorkoutRecord(id: UUID(), startedAt: baseDate.addingTimeInterval(offset),
                      endedAt: baseDate.addingTimeInterval(offset + 60), repetitions: repetitions,
                      detectionMode: mode, ownerID: owner)
    }

    private func remote(id: UUID = UUID(), repetitions: Int, offset: TimeInterval = 0) -> RemoteWorkout {
        RemoteWorkout(id: id, startedAt: baseDate.addingTimeInterval(offset),
                      endedAt: baseDate.addingTimeInterval(offset + 60), repetitions: repetitions,
                      detectionMode: "camera", dayUTC: "2026-10-18",
                      receivedAt: baseDate.addingTimeInterval(offset + 61))
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FormaStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

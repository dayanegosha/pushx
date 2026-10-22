import AVFoundation
import QuartzCore
import XCTest
@testable import Forma

@MainActor
final class FaceDistanceCounterTests: XCTestCase {
    func testFailureFromAnEarlierRunCannotInterruptAResumedWorkout() async throws {
        let stream = TestFaceDistanceStream()
        let counter = makeCounter(stream)
        counter.prepare()
        counter.begin()
        let first = try XCTUnwrap(stream.tokens.first)
        counter.pause()
        XCTAssertTrue(counter.resume())
        let resumed = try XCTUnwrap(stream.tokens.last)
        XCTAssertNotEqual(first, resumed)
        stream.onFailure?(first)
        try await flushCallbacks()
        XCTAssertEqual(counter.status, .measuring)
        stream.onFailure?(resumed)
        try await flushCallbacks()
        XCTAssertEqual(counter.status, .interrupted)
        XCTAssertFalse(counter.faceVisible)
    }

    func testSamplesFromAnEarlierRunAreRejectedEvenWithFreshTimestamps() async throws {
        let stream = TestFaceDistanceStream()
        let counter = makeCounter(stream)
        counter.prepare()
        let first = try XCTUnwrap(stream.tokens.first)
        counter.pause()
        XCTAssertTrue(counter.resume())
        stream.onSample?(0.5, UUID(), CACurrentMediaTime(), first)
        try await flushCallbacks()
        XCTAssertFalse(counter.faceVisible)
        XCTAssertFalse(counter.isCalibrated)
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(counter.status, .measuring)
    }

    func testStoppingRejectsQueuedSamplesAndFailures() async throws {
        let stream = TestFaceDistanceStream()
        let counter = makeCounter(stream)
        counter.prepare()
        let token = try XCTUnwrap(stream.tokens.first)
        counter.begin()
        counter.stop()
        stream.onSample?(0.5, UUID(), CACurrentMediaTime(), token)
        stream.onFailure?(token)
        try await flushCallbacks()
        XCTAssertEqual(counter.status, .idle)
        XCTAssertFalse(counter.faceVisible)
        XCTAssertEqual(counter.count, 0)
        XCTAssertGreaterThanOrEqual(stream.stopCount, 1)
    }

    func testOutOfRangeSamplesCannotDisplaySuccessfulFaceTracking() async throws {
        let stream = TestFaceDistanceStream()
        let counter = makeCounter(stream)
        counter.prepare()
        let token = try XCTUnwrap(stream.tokens.first)
        for distance in [Double.nan, .infinity, -1, 0.07, 1.6] {
            stream.onSample?(distance, UUID(), CACurrentMediaTime(), token)
            try await flushCallbacks()
            XCTAssertFalse(counter.faceVisible)
        }
        stream.onSample?(0.5, UUID(), CACurrentMediaTime(), token)
        try await flushCallbacks()
        XCTAssertTrue(counter.faceVisible)
        counter.stop()
    }

    func testRevokedCameraPermissionPreventsRestartAfterPause() {
        let stream = TestFaceDistanceStream()
        var permission = AVAuthorizationStatus.authorized
        let counter = FaceDistanceCounter(pipeline: stream, supportsFaceTracking: { true }, cameraAuthorization: { permission })
        counter.prepare()
        counter.begin()
        counter.pause()
        permission = .denied
        XCTAssertFalse(counter.resume())
        XCTAssertEqual(counter.status, .permissionDenied)
        XCTAssertEqual(stream.tokens.count, 1)
    }

    func testMissingARFramesInterruptsTheSessionInsteadOfWaitingForever() async throws {
        let stream = TestFaceDistanceStream()
        var now: TimeInterval = 100
        let counter = FaceDistanceCounter(pipeline: stream, supportsFaceTracking: { true },
                                          cameraAuthorization: { .authorized }, clock: { now })
        counter.prepare()
        counter.begin()
        now = 104
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(counter.status, .interrupted)
        XCTAssertGreaterThanOrEqual(stream.stopCount, 1)
    }

    func testIdenticalFramesDoNotPublishRepeatedUIUpdates() async throws {
        let stream = TestFaceDistanceStream()
        let counter = makeCounter(stream)
        counter.prepare()
        counter.begin()
        let token = try XCTUnwrap(stream.tokens.first)
        let face = UUID()
        var updates = 0
        let observation = counter.objectWillChange.sink { updates += 1 }
        stream.onSample?(0.5, face, CACurrentMediaTime(), token)
        try await flushCallbacks()
        stream.onSample?(0.5, face, CACurrentMediaTime(), token)
        try await flushCallbacks()
        XCTAssertEqual(updates, 1)
        observation.cancel()
        counter.stop()
    }

    func testElapsedTimeHandlesInvalidAndVeryLargeImportedDurations() {
        XCTAssertEqual(WorkoutView.elapsed(.nan), "00:00")
        XCTAssertEqual(WorkoutView.elapsed(.infinity), "00:00")
        XCTAssertEqual(WorkoutView.elapsed(-1), "00:00")
        XCTAssertEqual(WorkoutView.elapsed(125.9), "02:05")
        XCTAssertEqual(WorkoutView.elapsed(Double(Int.max)), "153722867280912930:07")
        XCTAssertEqual(WorkoutView.elapsed(128_849_018_880), "2147483648:00")
    }

    private func makeCounter(_ stream: TestFaceDistanceStream) -> FaceDistanceCounter {
        FaceDistanceCounter(pipeline: stream, supportsFaceTracking: { true }, cameraAuthorization: { .authorized })
    }

    private func flushCallbacks() async throws {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

private final class TestFaceDistanceStream: FaceDistanceStreaming {
    var onSample: ((Double?, UUID?, TimeInterval, UUID) -> Void)?
    var onFailure: ((UUID) -> Void)?
    private(set) var tokens: [UUID] = []
    private(set) var stopCount = 0
    func start(token: UUID) { tokens.append(token) }
    func stop() { stopCount += 1 }
}

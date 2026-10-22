import XCTest
@testable import Forma

final class FaceDistanceTests: XCTestCase {
    private let face = UUID()

    func testStableUpperPositionIsLearnedWithoutCounting() {
        var engine = FaceDistanceEngine()
        warmUp(&engine)
        XCTAssertEqual(engine.baseline ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(engine.count, 0)
    }

    func testCompleteDistanceCycleCountsOnce() {
        var engine = FaceDistanceEngine()
        warmUp(&engine)
        feed(&engine, [(1.1, 0.5), (1.25, 0.5), (1.4, 0.30), (1.55, 0.30),
                       (1.75, 0.5), (1.9, 0.5), (2.1, 0.5)])
        XCTAssertEqual(engine.count, 1)
    }

    func testUnsteadyAndTooCloseSetupCannotEstablishBaseline() {
        var engine = FaceDistanceEngine()
        for index in 0...30 {
            engine.update(distance: index.isMultiple(of: 2) ? 0.3 : 0.6, faceID: face, at: Double(index) * 0.05)
        }
        XCTAssertNil(engine.baseline)
        engine.reset()
        for index in 0...30 { engine.update(distance: 0.15, faceID: face, at: Double(index) * 0.05) }
        XCTAssertNil(engine.baseline)
        XCTAssertEqual(engine.count, 0)
    }

    func testTrackingLossAtTheUpperPositionCannotCreateARep() {
        var engine = FaceDistanceEngine()
        warmUp(&engine)
        feed(&engine, [(1.1, 0.5), (1.25, 0.5), (1.4, nil), (1.55, nil),
                       (1.6, nil), (1.75, 0.5), (1.9, 0.5)])
        XCTAssertEqual(engine.count, 0)
        feed(&engine, [(2.1, 0.3), (2.25, 0.3), (2.45, 0.5), (2.6, 0.5)])
        XCTAssertEqual(engine.count, 1)
    }

    func testAnotherFaceRequiresNewBaseline() {
        var engine = FaceDistanceEngine()
        warmUp(&engine)
        feed(&engine, [(1.1, 0.5), (1.25, 0.5), (1.4, 0.3), (1.55, 0.3)])
        engine.update(distance: 0.5, faceID: UUID(), at: 1.7)
        XCTAssertNil(engine.baseline)
        XCTAssertEqual(engine.count, 0)
    }

    func testPausePreservesCountAndNeedsNewSetup() {
        var engine = FaceDistanceEngine()
        warmUp(&engine)
        feed(&engine, [(1.1, 0.5), (1.25, 0.5), (1.4, 0.3), (1.55, 0.3), (1.75, 0.5), (1.9, 0.5)])
        engine.reset(preservingCount: true)
        XCTAssertEqual(engine.count, 1)
        XCTAssertNil(engine.baseline)
        warmUp(&engine, offset: 2)
        feed(&engine, [(3.1, 0.5), (3.25, 0.5), (3.4, 0.3), (3.55, 0.3), (3.75, 0.5), (3.9, 0.5)])
        XCTAssertEqual(engine.count, 2)
    }

    func testInvalidDistancesAndStaleSamplesNeverCount() {
        var engine = FaceDistanceEngine()
        warmUp(&engine)
        feed(&engine, [(1.1, .nan), (1.2, .infinity), (1.3, -1), (1.4, 2)])
        XCTAssertFalse(engine.update(distance: 0.3, faceID: face, at: 0.5))
        XCTAssertFalse(engine.update(distance: 0.5, faceID: face, at: .nan))
        XCTAssertEqual(engine.count, 0)
    }

    func testLongGapCannotCompleteAnOldRep() {
        var engine = FaceDistanceEngine()
        warmUp(&engine)
        feed(&engine, [(1.1, 0.5), (1.25, 0.5), (1.4, 0.3), (1.55, 0.3), (2.5, 0.5), (2.65, 0.5)])
        XCTAssertEqual(engine.count, 0)
    }

    func testShortTrackingLossAtTheBottomPreservesTheRep() {
        var engine = FaceDistanceEngine()
        warmUp(&engine)
        feed(&engine, [(1.1, 0.5), (1.25, 0.5), (1.4, 0.3), (1.55, 0.3),
                       (1.7, nil), (1.85, nil), (2.0, 0.5), (2.15, 0.5)])
        XCTAssertEqual(engine.count, 1)
    }

    func testFaceAnchorCanBeReacquiredAfterBriefBottomOcclusion() {
        var engine = FaceDistanceEngine()
        warmUp(&engine)
        feed(&engine, [(1.1, 0.5), (1.25, 0.5), (1.4, 0.3), (1.55, 0.3), (1.7, nil)])
        let reacquired = UUID()
        engine.update(distance: 0.5, faceID: reacquired, at: 1.9)
        engine.update(distance: 0.5, faceID: reacquired, at: 2.05)
        XCTAssertEqual(engine.count, 1)
        XCTAssertEqual(engine.baseline ?? 0, 0.5, accuracy: 0.001)
    }

    func testProlongedBottomOcclusionDoesNotCountOnReturn() {
        var engine = FaceDistanceEngine()
        warmUp(&engine)
        feed(&engine, [(1.1, 0.5), (1.25, 0.5), (1.4, 0.3), (1.55, 0.3),
                       (1.7, nil), (1.9, nil), (2.1, nil), (2.3, nil), (2.5, nil),
                       (2.7, 0.5), (2.85, 0.5)])
        XCTAssertEqual(engine.count, 0)
    }

    func testOcclusionBeforeReachingTheBottomCannotCount() {
        var engine = FaceDistanceEngine()
        warmUp(&engine)
        feed(&engine, [(1.1, 0.5), (1.25, 0.5), (1.4, 0.43), (1.55, 0.43),
                       (1.7, nil), (1.9, 0.5), (2.05, 0.5)])
        XCTAssertEqual(engine.count, 0)
    }

    func testOneLowOutlierFollowedByTrackingLossCannotSatisfyTheLowerDwell() {
        var engine = FaceDistanceEngine()
        warmUp(&engine)
        feed(&engine, [(1.1, 0.5), (1.25, 0.5), (1.4, 0.3), (1.55, nil),
                       (1.7, nil), (1.9, 0.5), (2.05, 0.5)])
        XCTAssertEqual(engine.count, 0)
    }

    private func warmUp(_ engine: inout FaceDistanceEngine, offset: Double = 0) {
        for index in 0...20 { engine.update(distance: 0.5, faceID: face, at: offset + Double(index) * 0.05) }
    }

    private func feed(_ engine: inout FaceDistanceEngine, _ values: [(Double, Double?)]) {
        for (time, value) in values { engine.update(distance: value, faceID: value == nil ? nil : face, at: time) }
    }
}

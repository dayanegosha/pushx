import XCTest
@testable import Forma

final class RepCycleTests: XCTestCase {
    private let calibration = RepCalibration(upperScale: 0.15, lowerScale: 0.35)

    func testCompleteUpperLowerUpperCountsExactlyOneRep() {
        var engine = RepCycleEngine(calibration: calibration)
        feed(&engine, [(0, 0.15), (0.15, 0.15), (0.3, 0.35), (0.45, 0.35),
                       (0.65, 0.15), (0.8, 0.15), (1.0, 0.15), (1.2, 0.15)])
        XCTAssertEqual(engine.count, 1)
        XCTAssertEqual(engine.phase, .upperReady)
    }

    func testStartingInLowerPositionDoesNotCountTheFirstRise() {
        var engine = RepCycleEngine(calibration: calibration)
        feed(&engine, [(0, 0.35), (0.2, 0.35), (0.4, 0.15), (0.6, 0.15)])
        XCTAssertEqual(engine.count, 0)
        XCTAssertEqual(engine.phase, .upperReady)
    }

    func testThresholdJitterAndOneFrameLowerSpikeDoNotCount() {
        var engine = RepCycleEngine(calibration: calibration)
        feed(&engine, [(0, 0.15), (0.15, 0.15), (0.3, 0.35), (0.36, 0.24),
                       (0.5, 0.30), (0.55, 0.28), (0.65, 0.15), (0.8, 0.15)])
        XCTAssertEqual(engine.count, 0)
    }

    func testTrackingLossCancelsThePartialRep() {
        var engine = RepCycleEngine(calibration: calibration)
        feed(&engine, [(0, 0.15), (0.15, 0.15), (0.3, 0.35), (0.45, 0.35)])
        engine.update(faceScale: nil, at: 0.5)
        feed(&engine, [(0.65, 0.15), (0.8, 0.15)])
        XCTAssertEqual(engine.count, 0)
        feed(&engine, [(0.95, 0.35), (1.10, 0.35), (1.30, 0.15), (1.45, 0.15)])
        XCTAssertEqual(engine.count, 1)
    }

    func testMissingFramesCannotCompleteAnOldMovement() {
        var engine = RepCycleEngine(calibration: calibration)
        feed(&engine, [(0, 0.15), (0.15, 0.15), (0.3, 0.35), (0.45, 0.35),
                       (1.2, 0.15), (1.35, 0.15)])
        XCTAssertEqual(engine.count, 0)
        XCTAssertEqual(engine.phase, .upperReady)
    }

    func testPauseAndResumePreserveTotalButRequireANewFullCycle() {
        var engine = RepCycleEngine(calibration: calibration)
        feed(&engine, [(0, 0.15), (0.15, 0.15), (0.3, 0.35), (0.45, 0.35),
                       (0.65, 0.15), (0.8, 0.15), (0.95, 0.35), (1.1, 0.35)])
        engine.reset(preservingCount: true)
        feed(&engine, [(1.3, 0.15), (1.45, 0.15)])
        XCTAssertEqual(engine.count, 1)
        feed(&engine, [(1.6, 0.35), (1.75, 0.35), (1.95, 0.15), (2.1, 0.15)])
        XCTAssertEqual(engine.count, 2)
        engine.reset()
        XCTAssertEqual(engine.count, 0)
        XCTAssertEqual(engine.phase, .seekingUpper)
    }

    func testNonMonotonicAndInvalidSamplesNeverEmitReps() {
        var engine = RepCycleEngine(calibration: calibration)
        feed(&engine, [(0, 0.15), (0.15, 0.15), (0.3, 0.35), (0.45, 0.35)])
        XCTAssertFalse(engine.update(faceScale: 0.15, at: 0.2))
        XCTAssertFalse(engine.update(faceScale: .nan, at: 0.5))
        feed(&engine, [(0.65, 0.15), (0.8, 0.15)])
        XCTAssertEqual(engine.count, 0)
    }

    func testARepNeedsAStableReturnToUpperPosition() {
        var engine = RepCycleEngine(calibration: calibration)
        feed(&engine, [(0, 0.15), (0.15, 0.15), (0.3, 0.35), (0.45, 0.35),
                       (0.6, 0.15), (0.65, 0.27), (0.8, 0.15), (0.85, 0.28)])
        XCTAssertEqual(engine.count, 0)
        feed(&engine, [(1.0, 0.15), (1.15, 0.15)])
        XCTAssertEqual(engine.count, 1)
    }

    func testLongAbandonedCycleIsDiscarded() {
        var configuration = RepCycleEngine.Configuration()
        configuration.maximumCycleDuration = 0.8
        var engine = RepCycleEngine(calibration: calibration, configuration: configuration)
        feed(&engine, [(0, 0.15), (0.15, 0.15), (0.3, 0.35), (0.45, 0.35),
                       (0.7, 0.35), (0.95, 0.35), (1.2, 0.35), (1.4, 0.15), (1.6, 0.15)])
        XCTAssertEqual(engine.count, 0)
    }

    func testCalibrationUsesMedianToResistOutliers() throws {
        let result = try RepCalibration.make(
            upperSamples: Array(repeating: 0.15, count: 15) + [0.8, 0.7],
            lowerSamples: Array(repeating: 0.35, count: 15) + [0.05, 0.1]
        )
        XCTAssertEqual(result.upperScale, 0.15, accuracy: 0.0001)
        XCTAssertEqual(result.lowerScale, 0.35, accuracy: 0.0001)
        XCTAssertLessThan(result.upperThreshold, result.lowerThreshold)
    }

    func testCalibrationRejectsMissingTrackingAndInsufficientMovement() {
        XCTAssertThrowsError(try RepCalibration.make(
            upperSamples: [0.15], lowerSamples: Array(repeating: 0.35, count: 20)
        )) { XCTAssertEqual($0 as? RepCalibration.ValidationError, .insufficientSamples) }
        XCTAssertThrowsError(try RepCalibration.make(
            upperSamples: Array(repeating: 0.15, count: 20),
            lowerSamples: Array(repeating: 0.16, count: 20)
        )) { XCTAssertEqual($0 as? RepCalibration.ValidationError, .insufficientRange) }
        XCTAssertThrowsError(try RepCalibration.make(
            upperSamples: Array(repeating: 0.35, count: 20),
            lowerSamples: Array(repeating: 0.15, count: 20)
        )) { XCTAssertEqual($0 as? RepCalibration.ValidationError, .insufficientRange) }
    }

    private func feed(_ engine: inout RepCycleEngine, _ samples: [(Double, Double)]) {
        for (time, scale) in samples { engine.update(faceScale: scale, at: time) }
    }
}

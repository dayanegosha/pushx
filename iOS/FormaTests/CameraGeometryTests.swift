import XCTest
@testable import Forma

final class CameraGeometryTests: XCTestCase {
    func testFirstViewportIsABaselineAndLayoutJitterIsIgnored() {
        var geometry = CameraGeometryTracker()
        XCTAssertFalse(geometry.updateViewportSize(CGSize(width: 820, height: 1180)))
        XCTAssertFalse(geometry.updateViewportSize(CGSize(width: 820.6, height: 1180.4)))
        XCTAssertTrue(geometry.updateViewportSize(CGSize(width: 1180, height: 820)))
        XCTAssertFalse(geometry.updateViewportSize(CGSize(width: 1180, height: 820)))
    }

    func testSplitViewAndFoldedViewportsInvalidateGeometry() {
        var geometry = CameraGeometryTracker()
        XCTAssertFalse(geometry.updateViewportSize(CGSize(width: 1180, height: 820)))
        XCTAssertTrue(geometry.updateViewportSize(CGSize(width: 590, height: 820)))
        XCTAssertTrue(geometry.updateViewportSize(CGSize(width: 440, height: 956)))
        XCTAssertTrue(geometry.updateViewportSize(CGSize(width: 824, height: 956)))
    }

    func testTransientInvalidViewportDoesNotReplaceTheLastValidGeometry() {
        var geometry = CameraGeometryTracker()
        let initial = CGSize(width: 820, height: 1180)
        XCTAssertFalse(geometry.updateViewportSize(initial))
        XCTAssertFalse(geometry.updateViewportSize(.zero))
        XCTAssertFalse(geometry.updateViewportSize(CGSize(width: CGFloat.nan, height: 1180)))
        XCTAssertFalse(geometry.updateViewportSize(CGSize(width: 820, height: -CGFloat.infinity)))
        XCTAssertEqual(geometry.viewportSize, initial)
        XCTAssertFalse(geometry.updateViewportSize(initial))
    }

    func testEveryInterfaceOrientationChangeIsDetectedExactlyOnce() {
        var geometry = CameraGeometryTracker()
        XCTAssertFalse(geometry.updateOrientation(.portrait))
        for orientation in [CameraInterfaceOrientation.landscapeLeft, .portraitUpsideDown, .landscapeRight, .portrait] {
            XCTAssertTrue(geometry.updateOrientation(orientation))
            XCTAssertFalse(geometry.updateOrientation(orientation))
        }
    }

    func testDisplayMigrationChangesGeometryWithoutRequiringANewOrientation() {
        var geometry = CameraGeometryTracker()
        XCTAssertFalse(geometry.updateOrientation(.portrait))
        XCTAssertFalse(geometry.updateDisplayID("outer"))
        XCTAssertFalse(geometry.updateDisplayID("outer"))
        XCTAssertTrue(geometry.updateDisplayID("inner"))
        XCTAssertFalse(geometry.updateOrientation(.portrait))
        XCTAssertFalse(geometry.updateDisplayID(""))
        XCTAssertEqual(geometry.displayID, "inner")
    }

    func testFramesQueuedBeforeGeometryInvalidationAreDiscarded() {
        var gate = CameraFrameGate()
        XCTAssertEqual(gate.evaluate(generation: 1, timestamp: 10, now: 10.1), .accept)
        gate.invalidate(at: 10.2)
        XCTAssertEqual(gate.evaluate(generation: 1, timestamp: 10.15, now: 10.3), .discard)
        XCTAssertEqual(gate.evaluate(generation: 1, timestamp: 10.25, now: 10.3), .accept)
    }

    func testCameraGenerationChangeIsReportedBeforeAcceptingMoreFrames() {
        var gate = CameraFrameGate()
        XCTAssertEqual(gate.evaluate(generation: 4, timestamp: 10, now: 10.1), .accept)
        XCTAssertEqual(gate.evaluate(generation: 5, timestamp: 10.2, now: 10.3), .geometryChanged)
        XCTAssertEqual(gate.evaluate(generation: 4, timestamp: 10.25, now: 10.3), .discard)
        XCTAssertEqual(gate.evaluate(generation: 5, timestamp: 10.3, now: 10.4), .accept)
    }

    func testStaleFutureAndInvalidFrameTimesCannotResetTheGeneration() {
        var gate = CameraFrameGate()
        XCTAssertEqual(gate.evaluate(generation: 1, timestamp: 10, now: 10.1), .accept)
        XCTAssertEqual(gate.evaluate(generation: 2, timestamp: 8, now: 10.2), .discard)
        XCTAssertEqual(gate.evaluate(generation: 2, timestamp: 11, now: 10.2), .discard)
        XCTAssertEqual(gate.evaluate(generation: 2, timestamp: .nan, now: 10.2), .discard)
        XCTAssertEqual(gate.evaluate(generation: 1, timestamp: 10.3, now: 10.4), .accept)
    }

    func testRotationDuringARepPreservesTheTotalAndRequiresAFullNewCycle() {
        let calibration = RepCalibration(upperScale: 0.15, lowerScale: 0.35)
        var engine = RepCycleEngine(calibration: calibration)
        var geometry = CameraGeometryTracker()
        _ = geometry.updateOrientation(.portrait)
        for (time, scale) in [(0.0, 0.15), (0.15, 0.15), (0.3, 0.35), (0.45, 0.35),
                              (0.65, 0.15), (0.8, 0.15), (0.95, 0.35), (1.1, 0.35)] {
            engine.update(faceScale: scale, at: time)
        }
        XCTAssertEqual(engine.count, 1)
        if geometry.updateOrientation(.landscapeLeft) { engine.reset(preservingCount: true) }
        engine.update(faceScale: 0.15, at: 1.3)
        engine.update(faceScale: 0.15, at: 1.45)
        XCTAssertEqual(engine.count, 1)
        for (time, scale) in [(1.6, 0.35), (1.75, 0.35), (1.95, 0.15), (2.1, 0.15)] {
            engine.update(faceScale: scale, at: time)
        }
        XCTAssertEqual(engine.count, 2)
    }
}

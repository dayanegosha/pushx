import XCTest
@testable import Forma

final class DeviceStabilityTests: XCTestCase {
    func testSustainedAccelerationAndRotationBothDetectMovement() {
        for (acceleration, rotation) in [(0.25, 0.0), (0.0, 1.0)] {
            var tracker = DeviceStabilityTracker()
            XCTAssertFalse(tracker.update(userAcceleration: acceleration, rotationRate: rotation, at: 1))
            XCTAssertFalse(tracker.update(userAcceleration: acceleration, rotationRate: rotation, at: 1.05))
            XCTAssertTrue(tracker.update(userAcceleration: acceleration, rotationRate: rotation, at: 1.11))
            XCTAssertTrue(tracker.isMoving)
        }
    }

    func testFloorVibrationsAndBriefSpikesDoNotDetectMovement() {
        var tracker = DeviceStabilityTracker()
        for index in 0...20 {
            XCTAssertFalse(tracker.update(userAcceleration: 0.08, rotationRate: 0.15, at: Double(index) * 0.05))
        }
        XCTAssertFalse(tracker.update(userAcceleration: 0.3, rotationRate: 0, at: 1.05))
        XCTAssertFalse(tracker.update(userAcceleration: 0.3, rotationRate: 0, at: 1.10))
        XCTAssertFalse(tracker.update(userAcceleration: 0.02, rotationRate: 0, at: 1.15))
        XCTAssertFalse(tracker.update(userAcceleration: 0, rotationRate: 1.2, at: 1.20))
        XCTAssertFalse(tracker.update(userAcceleration: 0, rotationRate: 0.1, at: 1.25))
        XCTAssertFalse(tracker.isMoving)
    }

    func testMovementNeedsAnUninterruptedSteadyPeriodToClear() {
        var tracker = DeviceStabilityTracker()
        detectMovement(&tracker)
        for time in [1.2, 1.4, 1.6, 1.8] {
            XCTAssertTrue(tracker.update(userAcceleration: 0.02, rotationRate: 0.1, at: time))
        }
        XCTAssertTrue(tracker.update(userAcceleration: 0.3, rotationRate: 0, at: 1.9))
        for time in [2.0, 2.2, 2.4, 2.6] {
            XCTAssertTrue(tracker.update(userAcceleration: 0.02, rotationRate: 0.1, at: time))
        }
        XCTAssertFalse(tracker.update(userAcceleration: 0.02, rotationRate: 0.1, at: 2.75))
        XCTAssertFalse(tracker.isMoving)
    }

    func testInvalidAndNonMonotonicSamplesCannotChangeStability() {
        var tracker = DeviceStabilityTracker()
        XCTAssertFalse(tracker.update(userAcceleration: 0.3, rotationRate: 0, at: 1))
        for (acceleration, rotation, time) in [
            (Double.nan, 0.0, 1.2), (.infinity, 0, 1.2), (-0.1, 0, 1.2),
            (0.3, Double.nan, 1.2), (0.3, .infinity, 1.2), (0.3, -0.1, 1.2),
            (0.3, 0, Double.nan), (0.3, 0, .infinity), (0.3, 0, -1),
            (0.3, 0, 1), (0.3, 0, 0.9)
        ] {
            XCTAssertFalse(tracker.update(userAcceleration: acceleration, rotationRate: rotation, at: time))
        }
        XCTAssertTrue(tracker.update(userAcceleration: 0.3, rotationRate: 0, at: 1.11))
        XCTAssertTrue(tracker.update(userAcceleration: 0, rotationRate: 0, at: 1.2))
        XCTAssertTrue(tracker.update(userAcceleration: .nan, rotationRate: 0, at: 2))
        XCTAssertTrue(tracker.update(userAcceleration: 0, rotationRate: 0, at: 1.1))
        XCTAssertTrue(tracker.isMoving)
    }

    func testMissingSamplesCannotProveMovementOrSteadiness() {
        var tracker = DeviceStabilityTracker()
        XCTAssertFalse(tracker.update(userAcceleration: 0.3, rotationRate: 0, at: 1))
        XCTAssertFalse(tracker.update(userAcceleration: 0.3, rotationRate: 0, at: 1.5))
        XCTAssertFalse(tracker.update(userAcceleration: 0.3, rotationRate: 0, at: 1.55))
        XCTAssertTrue(tracker.update(userAcceleration: 0.3, rotationRate: 0, at: 1.61))
        XCTAssertTrue(tracker.update(userAcceleration: 0, rotationRate: 0, at: 2))
        XCTAssertTrue(tracker.update(userAcceleration: 0, rotationRate: 0, at: 2.2))
        XCTAssertTrue(tracker.update(userAcceleration: 0, rotationRate: 0, at: 3))
        for time in [3.2, 3.4, 3.6] {
            XCTAssertTrue(tracker.update(userAcceleration: 0, rotationRate: 0, at: time))
        }
        XCTAssertFalse(tracker.update(userAcceleration: 0, rotationRate: 0, at: 3.76))
    }

    func testResetDiscardsMovementAndPendingConfirmation() {
        var tracker = DeviceStabilityTracker()
        detectMovement(&tracker)
        tracker.reset()
        XCTAssertFalse(tracker.isMoving)
        XCTAssertFalse(tracker.update(userAcceleration: 0.3, rotationRate: 0, at: 5))
        tracker.reset()
        XCTAssertFalse(tracker.update(userAcceleration: 0.3, rotationRate: 0, at: 5.05))
        XCTAssertFalse(tracker.update(userAcceleration: 0.3, rotationRate: 0, at: 5.10))
        XCTAssertTrue(tracker.update(userAcceleration: 0.3, rotationRate: 0, at: 5.16))
    }

    private func detectMovement(_ tracker: inout DeviceStabilityTracker) {
        for time in [1.0, 1.05, 1.11] {
            tracker.update(userAcceleration: 0.3, rotationRate: 0, at: time)
        }
        XCTAssertTrue(tracker.isMoving)
    }
}

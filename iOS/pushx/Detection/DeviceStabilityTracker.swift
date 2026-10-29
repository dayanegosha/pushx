import Foundation

struct DeviceStabilityTracker {
    private(set) var isMoving = false
    private var lastSample: TimeInterval?
    private var movementSince: TimeInterval?
    private var steadySince: TimeInterval?

    mutating func reset() {
        isMoving = false
        lastSample = nil
        movementSince = nil
        steadySince = nil
    }

    @discardableResult
    mutating func update(userAcceleration: Double, rotationRate: Double, at time: TimeInterval) -> Bool {
        guard time.isFinite, time >= 0, lastSample.map({ time > $0 }) ?? true,
              userAcceleration.isFinite, userAcceleration >= 0,
              rotationRate.isFinite, rotationRate >= 0 else { return isMoving }
        if let lastSample, time - lastSample > 0.25 {
            movementSince = nil
            steadySince = nil
        }
        lastSample = time
        if userAcceleration > 0.18 || rotationRate > 0.8 {
            steadySince = nil
            if movementSince == nil { movementSince = time }
            if time - (movementSince ?? time) >= 0.10 { isMoving = true }
        } else {
            movementSince = nil
            if isMoving {
                if steadySince == nil { steadySince = time }
                if time - (steadySince ?? time) >= 0.75 {
                    isMoving = false
                    steadySince = nil
                }
            }
        }
        return isMoving
    }
}

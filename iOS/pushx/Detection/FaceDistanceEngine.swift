import Foundation

struct FaceDistanceEngine {
    private(set) var count = 0
    private(set) var baseline: Double?
    private var samples: [(time: TimeInterval, distance: Double)] = []
    private var cycle = RepCycleEngine(calibration: RepCalibration(upperScale: 0.001, lowerScale: 0.999))
    private var lastSample: TimeInterval?
    private var faceID: UUID?
    private var occludedSince: TimeInterval?
    private var lastMovement: Double?
    private var lastVisibleAt: TimeInterval?
    private let occlusionGrace: TimeInterval = 0.85
    var isBridgingTrackingLoss: Bool { occludedSince != nil }

    mutating func reset(preservingCount: Bool = false) {
        if !preservingCount { count = 0 }
        baseline = nil
        samples.removeAll(keepingCapacity: true)
        cycle.reset()
        lastSample = nil
        faceID = nil
        clearOcclusion()
    }

    @discardableResult
    mutating func update(distance: Double?, faceID: UUID?, at time: TimeInterval) -> Bool {
        guard time.isFinite, lastSample.map({ time > $0 }) ?? true else { return false }
        let gap = lastSample.map { time - $0 > 0.4 } ?? false
        lastSample = time
        guard let distance, let faceID, distance.isFinite, (0.08...1.5).contains(distance) else {
            samples.removeAll(keepingCapacity: true)
            if distance == nil, let movement = lastMovement, movement >= cycle.calibration.lowerThreshold,
               cycle.phase == .lowerReached,
               let visibleAt = lastVisibleAt, time - visibleAt <= occlusionGrace {
                if occludedSince == nil { occludedSince = time }
                cycle.update(faceScale: movement, at: time)
            } else {
                cycle.reset(preservingCount: true)
                clearOcclusion()
            }
            return false
        }
        let bridged = occludedSince != nil && lastVisibleAt.map { time - $0 <= occlusionGrace } == true
        if let previous = self.faceID, previous != faceID, !bridged {
            baseline = nil
            samples.removeAll(keepingCapacity: true)
            cycle.reset(preservingCount: true)
            clearOcclusion()
        }
        self.faceID = faceID
        if gap {
            samples.removeAll(keepingCapacity: true)
            cycle.reset(preservingCount: true)
            clearOcclusion()
        }
        if baseline == nil {
            guard (0.25...1.0).contains(distance) else {
                samples.removeAll(keepingCapacity: true)
                return false
            }
            samples.append((time, distance))
            samples.removeAll { time - $0.time > 1.1 }
            guard samples.count >= 15, let first = samples.first, time - first.time >= 0.8 else { return false }
            let sorted = samples.map(\.distance).sorted()
            let median = sorted[sorted.count / 2]
            guard let minimum = sorted.first, let maximum = sorted.last, maximum - minimum <= median * 0.10 else {
                return false
            }
            baseline = median
            samples.removeAll(keepingCapacity: true)
            return false
        }
        guard let baseline else { return false }
        let movement = min(0.999, max(0.001, (1 - distance / baseline) / 0.40))
        lastMovement = movement
        lastVisibleAt = time
        occludedSince = nil
        if cycle.update(faceScale: movement, at: time) {
            count += 1
            return true
        }
        return false
    }
    private mutating func clearOcclusion() {
        occludedSince = nil
        lastMovement = nil
        lastVisibleAt = nil
    }
}

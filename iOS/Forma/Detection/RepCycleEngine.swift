import Foundation

/// A dimensionless face scale: sqrt(normalized bounding-box width × height).
/// Calibration belongs to a particular phone placement and should be repeated after moving it.
struct RepCalibration: Codable, Equatable {
    let upperScale: Double
    let lowerScale: Double

    var upperThreshold: Double { upperScale + (lowerScale - upperScale) * 0.30 }
    var lowerThreshold: Double { upperScale + (lowerScale - upperScale) * 0.72 }

    enum ValidationError: Error, Equatable {
        case insufficientSamples
        case insufficientRange
    }

    static func make(upperSamples: [Double], lowerSamples: [Double]) throws -> RepCalibration {
        let upper = upperSamples.filter { $0.isFinite && $0 >= 0.035 && $0 <= 0.95 }
        let lower = lowerSamples.filter { $0.isFinite && $0 >= 0.035 && $0 <= 0.95 }
        guard upper.count >= 12, lower.count >= 12 else {
            throw ValidationError.insufficientSamples
        }
        let upperMedian = median(upper)
        let lowerMedian = median(lower)
        // Both a relative and an absolute margin are necessary: a tiny distant face is noisy.
        guard lowerMedian - upperMedian >= max(0.025, upperMedian * 0.18) else {
            throw ValidationError.insufficientRange
        }
        return RepCalibration(upperScale: upperMedian, lowerScale: lowerMedian)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}

/// Pure state machine with no camera, UI, or wall-clock dependencies.
/// A rep is emitted only after a stable upper → lower → upper movement.
struct RepCycleEngine {
    struct Configuration {
        var upperDwell: TimeInterval = 0.12
        var lowerDwell: TimeInterval = 0.12
        var minimumCycleDuration: TimeInterval = 0.35
        var minimumRepInterval: TimeInterval = 0.60
        var maximumCycleDuration: TimeInterval = 8
        var maximumSampleGap: TimeInterval = 0.40
    }

    enum Phase: Equatable {
        case seekingUpper
        case upperReady
        case lowerReached
    }

    private(set) var count = 0
    private(set) var phase: Phase = .seekingUpper
    let calibration: RepCalibration
    private let configuration: Configuration
    private var upperSince: TimeInterval?
    private var lowerSince: TimeInterval?
    private var cycleSince: TimeInterval?
    private var lastSampleAt: TimeInterval?
    private var lastRepAt: TimeInterval?

    init(calibration: RepCalibration, configuration: Configuration = Configuration()) {
        self.calibration = calibration
        self.configuration = configuration
    }

    /// Resuming always reacquires the upper position. Count can be preserved across a pause.
    mutating func reset(preservingCount: Bool = false) {
        if !preservingCount { count = 0 }
        resetMotion()
        lastSampleAt = nil
        lastRepAt = nil
    }

    /// Nil immediately cancels a partial movement, so losing and reacquiring a face cannot count.
    /// Timestamps must be monotonic seconds (for example CACurrentMediaTime()).
    @discardableResult
    mutating func update(faceScale: Double?, at timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite else { return false }
        if let lastSampleAt, timestamp <= lastSampleAt { return false }
        if let lastSampleAt, timestamp - lastSampleAt > configuration.maximumSampleGap {
            resetMotion()
        }
        lastSampleAt = timestamp
        guard let faceScale, faceScale.isFinite, faceScale > 0, faceScale < 1 else {
            resetMotion()
            return false
        }

        if let cycleSince, timestamp - cycleSince > configuration.maximumCycleDuration {
            resetMotion()
        }

        switch phase {
        case .seekingUpper:
            if faceScale <= calibration.upperThreshold {
                if upperSince == nil { upperSince = timestamp }
                if timestamp - (upperSince ?? timestamp) >= configuration.upperDwell {
                    phase = .upperReady
                    upperSince = nil
                }
            } else {
                upperSince = nil
            }
        case .upperReady:
            if faceScale >= calibration.lowerThreshold {
                if lowerSince == nil {
                    lowerSince = timestamp
                    cycleSince = timestamp
                }
                if timestamp - (lowerSince ?? timestamp) >= configuration.lowerDwell {
                    phase = .lowerReached
                    upperSince = nil
                }
            } else {
                lowerSince = nil
                cycleSince = nil
            }
        case .lowerReached:
            if faceScale <= calibration.upperThreshold {
                if upperSince == nil { upperSince = timestamp }
                let stableUpper = timestamp - (upperSince ?? timestamp) >= configuration.upperDwell
                let longEnough = timestamp - (cycleSince ?? timestamp) >= configuration.minimumCycleDuration
                let debounced = lastRepAt.map { timestamp - $0 >= configuration.minimumRepInterval } ?? true
                if stableUpper && longEnough && debounced {
                    count += 1
                    lastRepAt = timestamp
                    phase = .upperReady
                    upperSince = nil
                    lowerSince = nil
                    cycleSince = nil
                    return true
                }
            } else {
                upperSince = nil
            }
        }
        return false
    }

    private mutating func resetMotion() {
        phase = .seekingUpper
        upperSince = nil
        lowerSince = nil
        cycleSince = nil
    }
}

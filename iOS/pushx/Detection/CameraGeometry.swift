import Foundation

enum CameraInterfaceOrientation: Equatable {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight
}

struct CameraGeometryTracker {
    private(set) var viewportSize: CGSize?
    private(set) var orientation: CameraInterfaceOrientation?
    private(set) var displayID: String?

    mutating func updateViewportSize(_ size: CGSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return false }
        guard let previous = viewportSize else { viewportSize = size; return false }
        guard abs(previous.width - size.width) > 1 || abs(previous.height - size.height) > 1 else { return false }
        viewportSize = size
        return true
    }

    mutating func updateOrientation(_ value: CameraInterfaceOrientation) -> Bool {
        defer { orientation = value }
        return orientation.map { $0 != value } ?? false
    }

    mutating func updateDisplayID(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        defer { displayID = value }
        return displayID.map { $0 != value } ?? false
    }
}

struct CameraFrameGate {
    enum Decision: Equatable {
        case discard, accept, geometryChanged
    }

    private var generation: Int?
    private var validAfter: TimeInterval = 0

    mutating func invalidate(at timestamp: TimeInterval) {
        if timestamp.isFinite { validAfter = max(validAfter, timestamp) }
    }

    mutating func evaluate(generation incoming: Int, timestamp: TimeInterval, now: TimeInterval) -> Decision {
        guard timestamp.isFinite, now.isFinite, timestamp >= validAfter,
              timestamp <= now, now - timestamp < 0.5 else { return .discard }
        if let generation {
            guard incoming >= generation else { return .discard }
            if incoming != generation {
                self.generation = incoming
                return .geometryChanged
            }
        } else {
            generation = incoming
        }
        return .accept
    }
}

import ARKit
import AVFoundation
import Combine
import Foundation
import QuartzCore
import UIKit

@MainActor
final class FaceDistanceCounter: ObservableObject {
    enum Status: Equatable {
        case idle, requestingPermission, ready, measuring, counting, paused
        case permissionDenied, unavailable, interrupted
    }

    @Published private(set) var count = 0
    @Published private(set) var status: Status = .idle
    @Published private(set) var faceVisible = false
    @Published private(set) var isCalibrated = false
    private let pipeline = FaceDistancePipeline()
    private var engine = FaceDistanceEngine()
    private var desiredRunning = false
    private var generation = UUID()
    private var geometry = CameraGeometryTracker()
    private var acceptAfter: TimeInterval = 0
    private var lastDelivery: TimeInterval?
    private var watchdog: Task<Void, Never>?

    var canStart: Bool { status == .ready }

    init() {
        pipeline.onSample = { [weak self] distance, id, time in
            Task { @MainActor in self?.receive(distance: distance, id: id, time: time) }
        }
        pipeline.onFailure = { [weak self] in
            Task { @MainActor in self?.interrupt() }
        }
    }

    func prepare() {
        guard status == .idle || status == .interrupted || status == .paused || status == .permissionDenied else { return }
        guard ARFaceTrackingConfiguration.isSupported else { status = .unavailable; return }
        desiredRunning = true
        let token = UUID()
        generation = token
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: run(token: token)
        case .notDetermined:
            status = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self, self.generation == token, self.desiredRunning else { return }
                    if granted { self.run(token: token) } else { self.status = .permissionDenied }
                }
            }
        case .denied, .restricted: status = .permissionDenied
        @unknown default: status = .unavailable
        }
    }

    func begin() {
        guard canStart else { return }
        engine.reset()
        count = 0
        isCalibrated = false
        acceptAfter = CACurrentMediaTime()
        status = .measuring
    }

    func pause() {
        engine.reset(preservingCount: true)
        isCalibrated = false
        stopPipeline()
        status = .paused
    }

    @discardableResult
    func resume() -> Bool {
        guard status == .paused || status == .interrupted else { return false }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            status = .permissionDenied
            return false
        }
        engine.reset(preservingCount: true)
        isCalibrated = false
        desiredRunning = true
        generation = UUID()
        run(token: generation, measuring: true)
        return true
    }

    func stop() {
        engine.reset(preservingCount: true)
        isCalibrated = false
        stopPipeline()
        status = .idle
    }

    func updateViewportSize(_ size: CGSize) {
        guard geometry.updateViewportSize(size), status == .counting || status == .measuring else { return }
        pause()
    }

    private func run(token: UUID, measuring: Bool = false) {
        guard generation == token, desiredRunning else { return }
        acceptAfter = CACurrentMediaTime()
        lastDelivery = nil
        pipeline.start()
        status = measuring ? .measuring : .ready
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self else { return }
                if let last = self.lastDelivery, CACurrentMediaTime() - last > 0.4 {
                    self.faceVisible = false
                    self.engine.update(distance: nil, faceID: nil, at: CACurrentMediaTime())
                }
            }
        }
    }

    private func receive(distance: Double?, id: UUID?, time: TimeInterval) {
        guard desiredRunning, time >= acceptAfter, time <= CACurrentMediaTime() + 0.05,
              CACurrentMediaTime() - time <= 0.4 else { return }
        lastDelivery = time
        faceVisible = distance != nil
        guard status == .measuring || status == .counting else { return }
        if engine.update(distance: distance, faceID: id, at: time) { count = engine.count }
        isCalibrated = engine.baseline != nil
        status = isCalibrated ? .counting : .measuring
    }

    private func interrupt() {
        guard desiredRunning else { return }
        engine.reset(preservingCount: true)
        isCalibrated = false
        stopPipeline()
        status = .interrupted
    }

    private func stopPipeline() {
        desiredRunning = false
        generation = UUID()
        acceptAfter = CACurrentMediaTime()
        watchdog?.cancel()
        watchdog = nil
        faceVisible = false
        pipeline.stop()
    }
}

private final class FaceDistancePipeline: NSObject, ARSessionDelegate {
    var onSample: ((Double?, UUID?, TimeInterval) -> Void)?
    var onFailure: (() -> Void)?
    private let session = ARSession()
    private let queue = DispatchQueue(label: "app.forma.face-distance", qos: .userInitiated)

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    func start() {
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = false
        configuration.maximumNumberOfTrackedFaces = min(2, ARFaceTrackingConfiguration.supportedNumberOfTrackedFaces)
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() { session.pause() }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let faces = frame.anchors.compactMap { $0 as? ARFaceAnchor }.filter(\.isTracked)
        guard faces.count == 1, let face = faces.first else {
            onSample?(nil, nil, frame.timestamp)
            return
        }
        let relative = simd_mul(simd_inverse(frame.camera.transform), face.transform)
        let translation = relative.columns.3
        let distance = Double(simd_length(SIMD3<Float>(translation.x, translation.y, translation.z)))
        onSample?(distance, face.identifier, frame.timestamp)
    }

    func session(_ session: ARSession, didFailWithError error: Error) { onFailure?() }
    func sessionWasInterrupted(_ session: ARSession) { onFailure?() }
}

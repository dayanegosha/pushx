import ARKit
import AVFoundation
import Combine
import CoreMotion
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
    @Published private(set) var isPhoneMoving = false
    private let pipeline: FaceDistanceStreaming
    private let supportsFaceTracking: () -> Bool
    private let cameraAuthorization: () -> AVAuthorizationStatus
    private let clock: () -> TimeInterval
    private var engine = FaceDistanceEngine()
    private let motion = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.forma.device-stability"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var stability = DeviceStabilityTracker()
    private var backgroundObserver: NSObjectProtocol?
    private var desiredRunning = false
    private var generation = UUID()
    private var geometry = CameraGeometryTracker()
    private var acceptAfter: TimeInterval = 0
    private var lastDelivery: TimeInterval?
    private var watchdog: Task<Void, Never>?

    var canStart: Bool { status == .ready && !isPhoneMoving }

    convenience init() {
        self.init(pipeline: FaceDistancePipeline(), supportsFaceTracking: { ARFaceTrackingConfiguration.isSupported },
                  cameraAuthorization: { AVCaptureDevice.authorizationStatus(for: .video) })
    }

    init(pipeline: FaceDistanceStreaming, supportsFaceTracking: @escaping () -> Bool,
         cameraAuthorization: @escaping () -> AVAuthorizationStatus, clock: @escaping () -> TimeInterval = CACurrentMediaTime) {
        self.pipeline = pipeline
        self.supportsFaceTracking = supportsFaceTracking
        self.cameraAuthorization = cameraAuthorization
        self.clock = clock
        pipeline.onSample = { [weak self] distance, id, time, token in
            Task { @MainActor in self?.receive(distance: distance, id: id, time: time, token: token) }
        }
        pipeline.onFailure = { [weak self] token in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.interrupt()
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.interrupt() }
        }
    }

    deinit {
        watchdog?.cancel()
        motion.stopDeviceMotionUpdates()
        motionQueue.cancelAllOperations()
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }

    func prepare() {
        guard status == .idle || status == .interrupted || status == .paused || status == .permissionDenied else { return }
        guard supportsFaceTracking() else { status = .unavailable; return }
        desiredRunning = true
        let token = UUID()
        generation = token
        switch cameraAuthorization() {
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
        acceptAfter = clock()
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
        guard status == .paused || status == .interrupted || status == .permissionDenied else { return false }
        guard cameraAuthorization() == .authorized else {
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
        acceptAfter = clock()
        lastDelivery = nil
        pipeline.start(token: token)
        status = measuring ? .measuring : .ready
        startMotion(token: token)
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self else { return }
                let now = self.clock()
                let silence = now - (self.lastDelivery ?? self.acceptAfter)
                if silence > 3 {
                    self.interrupt()
                    return
                }
                if !self.isPhoneMoving, self.lastDelivery != nil, silence > 0.4 {
                    self.engine.update(distance: nil, faceID: nil, at: now)
                    let visible = self.engine.isBridgingTrackingLoss
                    if self.faceVisible != visible { self.faceVisible = visible }
                }
            }
        }
    }

    private func receive(distance: Double?, id: UUID?, time: TimeInterval, token: UUID) {
        guard desiredRunning, generation == token, time >= acceptAfter, time <= clock() + 0.05,
              clock() - time <= 0.4 else { return }
        lastDelivery = time
        guard !isPhoneMoving else {
            if faceVisible { faceVisible = false }
            return
        }
        guard status == .measuring || status == .counting else {
            let visible = validDistance(distance)
            if faceVisible != visible { faceVisible = visible }
            return
        }
        if engine.update(distance: distance, faceID: id, at: time) { count = engine.count }
        let visible = validDistance(distance) || engine.isBridgingTrackingLoss
        if faceVisible != visible { faceVisible = visible }
        let calibrated = engine.baseline != nil
        if isCalibrated != calibrated { isCalibrated = calibrated }
        let nextStatus: Status = calibrated ? .counting : .measuring
        if status != nextStatus { status = nextStatus }
    }

    private func validDistance(_ distance: Double?) -> Bool {
        guard let distance else { return false }
        return distance.isFinite && (0.08...1.5).contains(distance)
    }

    private func startMotion(token: UUID) {
        motion.stopDeviceMotionUpdates()
        motionQueue.cancelAllOperations()
        stability.reset()
        isPhoneMoving = false
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.05
        motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] sample, _ in
            guard let sample else { return }
            let acceleration = sample.userAcceleration
            let rotation = sample.rotationRate
            let accelerationMagnitude = sqrt(acceleration.x * acceleration.x + acceleration.y * acceleration.y + acceleration.z * acceleration.z)
            let rotationMagnitude = sqrt(rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z)
            let time = sample.timestamp
            Task { @MainActor [weak self] in
                self?.receiveMotion(acceleration: accelerationMagnitude, rotation: rotationMagnitude, at: time, token: token)
            }
        }
    }

    private func receiveMotion(acceleration: Double, rotation: Double, at time: TimeInterval, token: UUID) {
        let now = clock()
        guard desiredRunning, generation == token, time >= acceptAfter,
              time <= now + 0.05, now - time <= 0.25 else { return }
        let moving = stability.update(userAcceleration: acceleration, rotationRate: rotation, at: time)
        guard moving != isPhoneMoving else { return }
        isPhoneMoving = moving
        engine.reset(preservingCount: true)
        isCalibrated = false
        faceVisible = false
        acceptAfter = now
        if status == .measuring || status == .counting { status = .measuring }
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
        acceptAfter = clock()
        watchdog?.cancel()
        watchdog = nil
        motion.stopDeviceMotionUpdates()
        motionQueue.cancelAllOperations()
        stability.reset()
        isPhoneMoving = false
        faceVisible = false
        pipeline.stop()
    }
}

protocol FaceDistanceStreaming: AnyObject {
    var onSample: ((Double?, UUID?, TimeInterval, UUID) -> Void)? { get set }
    var onFailure: ((UUID) -> Void)? { get set }
    func start(token: UUID)
    func stop()
}

private final class FaceDistancePipeline: NSObject, ARSessionDelegate, FaceDistanceStreaming {
    var onSample: ((Double?, UUID?, TimeInterval, UUID) -> Void)?
    var onFailure: ((UUID) -> Void)?
    private var session: ARSession?
    private var token: UUID?
    private let queue = DispatchQueue(label: "app.forma.face-distance", qos: .userInitiated)
    private var lastTracked: (id: UUID, distance: Double, time: TimeInterval)?
    private var anchorID: UUID?
    private var continuityID: UUID?
    private var usedDepth = false

    deinit { session?.pause() }

    func start(token: UUID) {
        let configuration = ARFaceTrackingConfiguration()
        configuration.isLightEstimationEnabled = false
        if let format = ARFaceTrackingConfiguration.supportedVideoFormats.first(where: { $0.captureDeviceType == .builtInTrueDepthCamera }) {
            configuration.videoFormat = format
        }
        configuration.maximumNumberOfTrackedFaces = min(2, ARFaceTrackingConfiguration.supportedNumberOfTrackedFaces)
        queue.sync {
            session?.pause()
            session?.delegate = nil
            let session = ARSession()
            self.session = session
            self.token = token
            session.delegate = self
            session.delegateQueue = queue
            lastTracked = nil
            anchorID = nil
            continuityID = nil
            usedDepth = false
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    func stop() {
        queue.sync {
            token = nil
            session?.delegate = nil
            session?.pause()
            session = nil
            lastTracked = nil
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard session === self.session, let token else { return }
        let faces = frame.anchors.compactMap { $0 as? ARFaceAnchor }.filter(\.isTracked)
        guard faces.count == 1, let face = faces.first else {
            if faces.count > 1 {
                lastTracked = nil
                onSample?(.nan, nil, frame.timestamp, token)
                return
            }
            if let previous = lastTracked, frame.timestamp - previous.time <= 0.85,
               let captured = frame.capturedDepthData,
               abs(frame.timestamp - frame.capturedDepthDataTimestamp) <= 0.1,
               let distance = DepthDistanceSampler.distance(in: captured.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32).depthDataMap),
               distance < min(0.4, previous.distance - 0.03) {
                usedDepth = true
                onSample?(distance, previous.id, frame.timestamp, token)
            } else {
                onSample?(nil, nil, frame.timestamp, token)
            }
            return
        }
        if anchorID != face.identifier {
            if !usedDepth || lastTracked.map({ frame.timestamp - $0.time > 0.85 }) ?? true {
                continuityID = face.identifier
            }
            anchorID = face.identifier
        }
        usedDepth = false
        let relative = simd_mul(simd_inverse(frame.camera.transform), face.transform)
        let translation = relative.columns.3
        let distance = Double(simd_length(SIMD3<Float>(translation.x, translation.y, translation.z)))
        let id = continuityID ?? face.identifier
        lastTracked = (id, distance, frame.timestamp)
        onSample?(distance, id, frame.timestamp, token)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        guard session === self.session, let token else { return }
        onFailure?(token)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        guard session === self.session, let token else { return }
        onFailure?(token)
    }
}

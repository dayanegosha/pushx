import AVFoundation
import Combine
import Foundation
import QuartzCore
import UIKit
import Vision

enum CounterStatus: Equatable {
    case idle, requestingPermission, cameraReady, calibrating, ready, counting, paused
    case permissionDenied, cameraUnavailable, failed
}

enum CalibrationPhase: Equatable {
    case idle, upperCountdown(Int), captureUpper, lowerCountdown(Int), captureLower, ready, failed
}

enum CameraCounterError: String, Error {
    case permissionDenied, cameraUnavailable, cameraConfiguration
    case insufficientSamples, insufficientRange, interrupted, recalibrationRequired
}

@MainActor
final class CameraCounter: ObservableObject {
    @Published private(set) var count = 0
    @Published private(set) var status: CounterStatus = .idle
    @Published private(set) var calibration: CalibrationPhase = .idle
    @Published private(set) var faceRect: CGRect?
    @Published private(set) var faceVisible = false
    @Published private(set) var progress = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var errorCode: CameraCounterError?
    @Published private(set) var geometryRevision = 0

    var isCalibrated: Bool { engine != nil }
    var canStartWorkout: Bool { cameraReady && isCalibrated && status != .calibrating }
    var captureSession: AVCaptureSession { pipeline.session }

    private let pipeline = FaceCapturePipeline()
    private let rotation = CameraRotationObserver()
    private var geometry = CameraGeometryTracker()
    private var frameGate = CameraFrameGate()
    private var engine: RepCycleEngine?
    private var upperSamples: [Double] = []
    private var lowerSamples: [Double] = []
    private var calibrationTask: Task<Void, Never>?
    private var desiredRunning = false
    private var cameraReady = false
    private var runToken = UUID()

    init() {
        pipeline.onSample = { [weak self] sample in
            Task { @MainActor in self?.receive(sample) }
        }
        pipeline.onFailure = { [weak self] error in
            Task { @MainActor in self?.handleFailure(error) }
        }
        pipeline.onDeviceConfigured = { [weak self] device in
            Task { @MainActor in self?.rotation.setDevice(device) }
        }
        pipeline.onGeometryChanged = { [weak self] in
            Task { @MainActor in self?.invalidateCalibrationForGeometryChange() }
        }
        rotation.onCaptureRotation = { [weak self] angle, orientation in
            self?.pipeline.updateCaptureRotation(angle: angle, orientation: orientation)
        }
    }

    func updateViewportSize(_ size: CGSize) {
        if geometry.updateViewportSize(size) { invalidateCalibrationForGeometryChange() }
    }

    func updatePreviewGeometry(layer: AVCaptureVideoPreviewLayer, orientation: UIInterfaceOrientation,
                               displayID: String, didMoveToWindow: Bool = false) {
        var changed = geometry.updateDisplayID(displayID)
        if let orientation = CameraInterfaceOrientation(orientation) {
            changed = geometry.updateOrientation(orientation) || changed
            rotation.setOrientation(orientation)
        }
        if changed { invalidateCalibrationForGeometryChange() }
        rotation.setPreviewLayer(layer, forceRefresh: didMoveToWindow)
    }

    func detachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        rotation.detachPreviewLayer(layer)
    }

    func requestAndStart() {
        desiredRunning = true
        guard !cameraReady, status != .requestingPermission else { return }
        runToken = UUID()
        let token = runToken
        clearError()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startPipeline(token: token)
        case .notDetermined:
            status = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self, self.desiredRunning, self.runToken == token else { return }
                    if granted { self.startPipeline(token: token) }
                    else { self.handleFailure(.permissionDenied) }
                }
            }
        case .denied, .restricted:
            handleFailure(.permissionDenied)
        @unknown default:
            handleFailure(.cameraUnavailable)
        }
    }

    func stop() {
        desiredRunning = false
        cameraReady = false
        runToken = UUID()
        calibrationTask?.cancel()
        calibrationTask = nil
        calibration = isCalibrated ? .ready : .idle
        engine?.reset(preservingCount: true)
        frameGate.invalidate(at: CACurrentMediaTime())
        faceVisible = false
        faceRect = nil
        status = .idle
        pipeline.stop()
    }

    func beginCalibration() {
        guard cameraReady else { return }
        calibrationTask?.cancel()
        clearError()
        engine = nil
        upperSamples.removeAll(keepingCapacity: true)
        lowerSamples.removeAll(keepingCapacity: true)
        progress = 0
        status = .calibrating
        calibrationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for remaining in stride(from: 3, through: 1, by: -1) {
                    try Task.checkCancellation()
                    self.calibration = .upperCountdown(remaining)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                self.progress = 0
                self.calibration = .captureUpper
                try await self.captureWindow()
                for remaining in stride(from: 3, through: 1, by: -1) {
                    try Task.checkCancellation()
                    self.calibration = .lowerCountdown(remaining)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                self.progress = 0
                self.calibration = .captureLower
                try await self.captureWindow()
                try Task.checkCancellation()
                do {
                    let result = try RepCalibration.make(
                        upperSamples: self.upperSamples, lowerSamples: self.lowerSamples
                    )
                    self.engine = RepCycleEngine(calibration: result)
                    self.calibration = .ready
                    self.status = .ready
                    self.progress = 1
                } catch RepCalibration.ValidationError.insufficientSamples {
                    self.failCalibration(.insufficientSamples)
                } catch {
                    self.failCalibration(.insufficientRange)
                }
            } catch {
            }
        }
    }

    func startWorkout() {
        guard canStartWorkout else { return }
        clearError()
        engine?.reset(preservingCount: true)
        status = .counting
    }

    func pauseWorkout() {
        calibrationTask?.cancel()
        calibrationTask = nil
        if status == .calibrating { calibration = isCalibrated ? .ready : .idle }
        engine?.reset(preservingCount: true)
        if cameraReady { status = isCalibrated ? .paused : .cameraReady }
    }

    func resetCount() {
        count = 0
        engine?.reset()
    }

    private func startPipeline(token: UUID) {
        status = .requestingPermission
        pipeline.start { [weak self] result in
            Task { @MainActor in
                guard let self, self.desiredRunning, self.runToken == token else { return }
                switch result {
                case .success:
                    self.cameraReady = true
                    self.status = self.isCalibrated ? .ready : .cameraReady
                case .failure(let error):
                    self.handleFailure(error)
                }
            }
        }
    }

    private func captureWindow() async throws {
        for tick in 1...20 {
            try await Task.sleep(nanoseconds: 100_000_000)
            try Task.checkCancellation()
            progress = Double(tick) / 20
        }
    }

    private func receive(_ sample: FaceCapturePipeline.Sample) {
        guard desiredRunning, cameraReady else { return }
        switch frameGate.evaluate(generation: sample.generation, timestamp: sample.timestamp, now: CACurrentMediaTime()) {
        case .discard: return
        case .geometryChanged:
            invalidateCalibrationForGeometryChange()
            return
        case .accept: break
        }
        faceRect = sample.rect
        faceVisible = sample.rect != nil
        if let scale = sample.scale {
            switch calibration {
            case .captureUpper: upperSamples.append(scale)
            case .captureLower: lowerSamples.append(scale)
            default: break
            }
        }
        if status == .counting {
            if engine?.update(faceScale: sample.scale, at: sample.timestamp) == true {
                count += 1
            }
        }
    }

    private func invalidateCalibrationForGeometryChange() {
        frameGate.invalidate(at: CACurrentMediaTime())
        guard isCalibrated || status == .calibrating || status == .counting else { return }
        calibrationTask?.cancel()
        calibrationTask = nil
        engine = nil
        upperSamples.removeAll(keepingCapacity: true)
        lowerSamples.removeAll(keepingCapacity: true)
        calibration = .idle
        progress = 0
        faceVisible = false
        faceRect = nil
        errorCode = .recalibrationRequired
        errorMessage = CameraCounterError.recalibrationRequired.rawValue
        if cameraReady { status = .cameraReady }
        geometryRevision += 1
    }

    private func failCalibration(_ error: CameraCounterError) {
        calibration = .failed
        progress = 0
        status = .cameraReady
        errorCode = error
        errorMessage = error.rawValue
    }

    private func clearError() {
        errorCode = nil
        errorMessage = nil
    }

    private func handleFailure(_ error: CameraCounterError) {
        guard desiredRunning else { return }
        calibrationTask?.cancel()
        calibrationTask = nil
        engine?.reset(preservingCount: true)
        cameraReady = false
        faceVisible = false
        faceRect = nil
        errorCode = error
        errorMessage = error.rawValue
        calibration = isCalibrated ? .ready : .idle
        switch error {
        case .permissionDenied: status = .permissionDenied
        case .cameraUnavailable: status = .cameraUnavailable
        default: status = .failed
        }
        pipeline.stop()
    }
}

private extension CameraInterfaceOrientation {
    init?(_ orientation: UIInterfaceOrientation) {
        switch orientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: return nil
        }
    }

    var captureOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        }
    }
}

@MainActor
private final class CameraRotationObserver {
    var onCaptureRotation: ((CGFloat?, AVCaptureVideoOrientation) -> Void)?
    private var device: AVCaptureDevice?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []
    private var orientation: CameraInterfaceOrientation = .portrait

    func setDevice(_ device: AVCaptureDevice) {
        self.device = device
        rebuild()
    }

    func setPreviewLayer(_ layer: AVCaptureVideoPreviewLayer, forceRefresh: Bool) {
        guard previewLayer !== layer || forceRefresh else { applyPreviewRotation(); return }
        previewLayer = layer
        rebuild()
    }

    func detachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        guard previewLayer === layer else { return }
        previewLayer = nil
        rebuild()
    }

    func setOrientation(_ value: CameraInterfaceOrientation) {
        guard orientation != value else { return }
        orientation = value
        applyCaptureRotation()
        applyPreviewRotation()
    }

    private func rebuild() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        guard let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        self.coordinator = coordinator
        applyCaptureRotation()
        applyPreviewRotation()
        observations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: .new) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.applyCaptureRotation() }
        })
        observations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: .new) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.applyPreviewRotation() }
        })
    }

    private func applyCaptureRotation() {
        guard let coordinator else { return }
        let angle: CGFloat?
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            angle = coordinator.videoRotationAngleRelative(toDeviceOrientation: orientation.captureOrientation)
        } else {
            angle = nil
        }
        #else
        angle = nil
        #endif
        onCaptureRotation?(angle, orientation.captureOrientation)
    }

    private func applyPreviewRotation() {
        guard let coordinator, let connection = previewLayer?.connection else { return }
        let angle = coordinator.videoRotationAngleForHorizonLevelPreview
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}

private final class FaceCapturePipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Sample {
        let rect: CGRect?
        let timestamp: TimeInterval
        let generation: Int
        var scale: Double? { rect.map { sqrt(Double($0.width * $0.height)) } }
    }

    let session = AVCaptureSession()
    var onSample: ((Sample) -> Void)?
    var onFailure: ((CameraCounterError) -> Void)?
    var onDeviceConfigured: ((AVCaptureDevice) -> Void)?
    var onGeometryChanged: (() -> Void)?
    private let sessionQueue = DispatchQueue(label: "app.upra.camera.session", qos: .userInitiated)
    private let visionQueue = DispatchQueue(label: "app.upra.camera.vision", qos: .userInitiated)
    private let frameLock = NSLock()
    private var generation = 0
    private var discardFramesUntil: TimeInterval = 0
    private var frameDimensions: CGSize?
    private var captureAngle: CGFloat?
    private var captureOrientation: AVCaptureVideoOrientation = .portrait
    private var configured = false
    private var device: AVCaptureDevice?
    private var output: AVCaptureVideoDataOutput?
    private var lastAnalysisAt: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var deviceObservations: [NSKeyValueObservation] = []
    private var centerStageState: (AVCaptureDevice.CenterStageControlMode, Bool)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.onFailure?(.interrupted)
            })
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        deviceObservations.forEach { $0.invalidate() }
    }

    func start(completion: @escaping (Result<Void, CameraCounterError>) -> Void) {
        sessionQueue.async { [self] in
            do {
                disableAutomaticFraming()
                if !configured { try configure() }
                if let device { try lockZoom(device) }
                applyCaptureRotation()
                if !session.isRunning { session.startRunning() }
                if session.isRunning {
                    if let device { onDeviceConfigured?(device) }
                    completion(.success(()))
                } else { completion(.failure(.cameraConfiguration)) }
            } catch let error as CameraCounterError {
                restoreAutomaticFraming()
                completion(.failure(error))
            } catch {
                restoreAutomaticFraming()
                completion(.failure(.cameraConfiguration))
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
            restoreAutomaticFraming()
        }
    }

    func updateCaptureRotation(angle: CGFloat?, orientation: AVCaptureVideoOrientation) {
        sessionQueue.async { [self] in
            captureAngle = angle
            captureOrientation = orientation
            applyCaptureRotation()
        }
    }

    private func applyCaptureRotation() {
        guard let connection = output?.connection(with: .video) else { return }
        let before = connection.videoRotationAngle
        if let captureAngle, connection.isVideoRotationAngleSupported(captureAngle) {
            connection.videoRotationAngle = captureAngle
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = captureOrientation
        }
        if abs(before - connection.videoRotationAngle) > 0.5 { invalidateFrames() }
    }

    private func disableAutomaticFraming() {
        if centerStageState == nil {
            centerStageState = (AVCaptureDevice.centerStageControlMode, AVCaptureDevice.isCenterStageEnabled)
        }
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
    }

    private func restoreAutomaticFraming() {
        guard let (mode, enabled) = centerStageState else { return }
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = enabled
        AVCaptureDevice.centerStageControlMode = mode
        centerStageState = nil
    }

    private func lockZoom(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
        let zoom = min(max(1, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        if abs(device.videoZoomFactor - zoom) > 0.001 { device.videoZoomFactor = zoom }
    }

    private func configure() throws {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera], mediaType: .video, position: .front)
        guard let device = discovery.devices.first else { throw CameraCounterError.cameraUnavailable }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: visionQueue)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .medium
        guard session.canAddInput(input) else { throw CameraCounterError.cameraConfiguration }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw CameraCounterError.cameraConfiguration
        }
        session.addOutput(output)
        self.device = device
        self.output = output
        if let connection = output.connection(with: .video) {
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
        configured = true
        deviceObservations.append(device.observe(\.activePrimaryConstituent, options: .new) { [weak self] _, _ in
            self?.cameraGeometryChanged()
        })
        deviceObservations.append(device.observe(\.activeFormat, options: .new) { [weak self] _, _ in
            self?.cameraGeometryChanged()
        })
        deviceObservations.append(device.observe(\.videoZoomFactor, options: [.old, .new]) { [weak self] _, change in
            guard let old = change.oldValue, let new = change.newValue, abs(old - new) > 0.001 else { return }
            self?.cameraGeometryChanged()
        })
    }

    private func cameraGeometryChanged() {
        invalidateFrames()
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning, let device = self.device else { return }
            do { try self.lockZoom(device) }
            catch { self.onFailure?(.cameraConfiguration) }
            self.onDeviceConfigured?(device)
        }
    }

    private func invalidateFrames() {
        frameLock.lock()
        generation += 1
        discardFramesUntil = CACurrentMediaTime() + 0.25
        frameDimensions = nil
        frameLock.unlock()
        onGeometryChanged?()
    }

    private func captureGeneration(for pixelBuffer: CVPixelBuffer, at timestamp: TimeInterval) -> Int? {
        let dimensions = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        frameLock.lock()
        guard timestamp >= discardFramesUntil else { frameLock.unlock(); return nil }
        if let frameDimensions, frameDimensions != dimensions {
            generation += 1
            self.frameDimensions = dimensions
            discardFramesUntil = timestamp + 0.25
            frameLock.unlock()
            onGeometryChanged?()
            return nil
        }
        frameDimensions = dimensions
        let acceptedGeneration = generation
        frameLock.unlock()
        return acceptedGeneration
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let timestamp = CACurrentMediaTime()
        guard timestamp - lastAnalysisAt >= 1.0 / 15.0 else { return }
        lastAnalysisAt = timestamp
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let generation = captureGeneration(for: pixelBuffer, at: timestamp) else { return }
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            let faces = (request.results ?? []).filter { $0.confidence >= 0.7 }
            let rect = faces.count == 1 ? faces.first?.boundingBox : nil
            onSample?(Sample(rect: rect, timestamp: timestamp, generation: generation))
        } catch {
            onSample?(Sample(rect: nil, timestamp: timestamp, generation: generation))
        }
    }
}

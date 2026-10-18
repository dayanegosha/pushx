import AVFoundation
import Combine
import Foundation
import QuartzCore
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
    case insufficientSamples, insufficientRange, interrupted
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

    var isCalibrated: Bool { engine != nil }
    var canStartWorkout: Bool { cameraReady && isCalibrated && status != .calibrating }
    var captureSession: AVCaptureSession { pipeline.session }

    private let pipeline = FaceCapturePipeline()
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
        guard CACurrentMediaTime() - sample.timestamp < 0.5 else { return }
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

private final class FaceCapturePipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Sample {
        let rect: CGRect?
        let timestamp: TimeInterval
        var scale: Double? { rect.map { sqrt(Double($0.width * $0.height)) } }
    }

    let session = AVCaptureSession()
    var onSample: ((Sample) -> Void)?
    var onFailure: ((CameraCounterError) -> Void)?
    private let sessionQueue = DispatchQueue(label: "app.forma.camera.session", qos: .userInitiated)
    private let visionQueue = DispatchQueue(label: "app.forma.camera.vision", qos: .userInitiated)
    private var configured = false
    private var lastAnalysisAt: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []

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
    }

    func start(completion: @escaping (Result<Void, CameraCounterError>) -> Void) {
        sessionQueue.async { [self] in
            do {
                if !configured { try configure() }
                if !session.isRunning { session.startRunning() }
                if session.isRunning { completion(.success(())) }
                else { completion(.failure(.cameraConfiguration)) }
            } catch let error as CameraCounterError {
                completion(.failure(error))
            } catch {
                completion(.failure(.cameraConfiguration))
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw CameraCounterError.cameraUnavailable
        }
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
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let timestamp = CACurrentMediaTime()
        guard timestamp - lastAnalysisAt >= 1.0 / 15.0 else { return }
        lastAnalysisAt = timestamp
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            onSample?(Sample(rect: nil, timestamp: timestamp))
            return
        }
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            let faces = (request.results ?? []).filter { $0.confidence >= 0.7 }
            let rect = faces.count == 1 ? faces.first?.boundingBox : nil
            onSample?(Sample(rect: rect, timestamp: timestamp))
        } catch {
            onSample?(Sample(rect: nil, timestamp: timestamp))
        }
    }
}

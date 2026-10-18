import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let counter: CameraCounter

    func makeUIView(context: Context) -> CameraPreviewSurface {
        let view = CameraPreviewSurface()
        view.counter = counter
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = counter.captureSession
        return view
    }

    func updateUIView(_ uiView: CameraPreviewSurface, context: Context) {
        uiView.counter = counter
        uiView.previewLayer.session = counter.captureSession
        DispatchQueue.main.async { uiView.reportGeometry() }
    }

    static func dismantleUIView(_ uiView: CameraPreviewSurface, coordinator: ()) {
        uiView.counter?.detachPreviewLayer(uiView.previewLayer)
    }
}

final class CameraPreviewSurface: UIView {
    weak var counter: CameraCounter?
    private var orientationObserver: NSObjectProtocol?
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportGeometry()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if orientationObserver == nil {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                orientationObserver = NotificationCenter.default.addObserver(
                    forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.async { self?.reportGeometry() }
                }
            }
            reportGeometry(didMoveToWindow: true)
        } else {
            counter?.detachPreviewLayer(previewLayer)
            stopObservingOrientation()
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        reportGeometry()
    }

    func reportGeometry(didMoveToWindow: Bool = false) {
        guard let window, let scene = window.windowScene else { return }
        let displayID = String(describing: ObjectIdentifier(window.screen))
        counter?.updatePreviewGeometry(layer: previewLayer, orientation: scene.interfaceOrientation,
                                       displayID: displayID, didMoveToWindow: didMoveToWindow)
    }

    private func stopObservingOrientation() {
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
            self.orientationObserver = nil
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
    }

    deinit {
        if let orientationObserver { NotificationCenter.default.removeObserver(orientationObserver) }
    }
}

import Cocoa
import AVFoundation
import os.log

private class PreviewView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        super.init(frame: .zero)
        wantsLayer = true
        layer = previewLayer
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}

private let previewLogger = Logger(subsystem: "org.ptpwebcam.PtpWebcamApp", category: "CameraPreview")
private func log(_ msg: String) { previewLogger.fault("\(msg, privacy: .public)") }

class CameraPreviewWindowController: NSWindowController, NSWindowDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let captureSession = AVCaptureSession()
    private let cameraName: String
    private var videoOutput: AVCaptureVideoDataOutput?
    private var aspectSet = false
    var onClose: (() -> Void)?

    init(cameraName: String) {
        self.cameraName = cameraName
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = cameraName
        window.center()
        super.init(window: window)
        window.delegate = self

        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        log("CameraPreview: auth=\(auth.rawValue) for '\(cameraName)'")
        switch auth {
        case .authorized:
            setupCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                log("CameraPreview: access request result=\(granted)")
                if granted { DispatchQueue.main.async { self?.setupCapture() } }
            }
        case .denied, .restricted:
            log("CameraPreview: camera access denied/restricted")
        @unknown default:
            break
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupCapture() {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.externalUnknown, .builtInWideAngleCamera]
        if #available(macOS 14.0, *) { deviceTypes.append(.external) }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified)
        let allDevices = discovery.devices
        log("CameraPreview: \(allDevices.count) device(s): \(allDevices.map(\.localizedName).joined(separator: ", "))")

        guard let device = allDevices.first(where: { $0.localizedName == cameraName })
                        ?? allDevices.first(where: {
                            $0.localizedName.contains(cameraName) || cameraName.contains($0.localizedName)
                        }) else {
            log("CameraPreview: no device matching '\(cameraName)'")
            return
        }
        log("CameraPreview: matched '\(device.localizedName)' uid=\(device.uniqueID)")

        guard let input = try? AVCaptureDeviceInput(device: device) else {
            log("CameraPreview: AVCaptureDeviceInput failed")
            return
        }
        guard captureSession.canAddInput(input) else {
            log("CameraPreview: canAddInput returned false")
            return
        }
        captureSession.addInput(input)

        // Sample frames to read actual pixel buffer dimensions for the window aspect ratio.
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        if captureSession.canAddOutput(output) {
            output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "org.ptpwebcam.preview.frameq"))
            captureSession.addOutput(output)
            videoOutput = output
        }

        NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: captureSession, queue: .main) { note in
            let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            log("CameraPreview: runtime error: \(err?.localizedDescription ?? "nil")")
        }

        let previewView = PreviewView(session: captureSession)
        previewView.autoresizingMask = [.width, .height]
        previewView.frame = window!.contentView!.bounds
        window!.contentView!.addSubview(previewView)

        captureSession.startRunning()
        log("CameraPreview: startRunning isRunning=\(captureSession.isRunning)")
    }

    // Called on every frame — read dimensions from the first one, then detach.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !aspectSet, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        aspectSet = true
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        log("CameraPreview: first frame \(w)×\(h)")
        DispatchQueue.main.async { [weak self] in
            guard let self, let win = self.window, w > 0, h > 0 else { return }
            win.contentAspectRatio = NSSize(width: w, height: h)
            let currentW = win.contentRect(forFrameRect: win.frame).size.width
            win.setContentSize(NSSize(width: currentW, height: currentW * CGFloat(h) / CGFloat(w)))
        }
        // Detach delegate — no need to process further frames just for sizing.
        DispatchQueue.main.async { [weak self] in
            self?.videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        captureSession.stopRunning()
        onClose?()
    }
}

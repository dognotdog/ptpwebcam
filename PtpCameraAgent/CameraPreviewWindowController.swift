import Cocoa
import AVKit
import AVFoundation

class CameraPreviewWindowController: NSWindowController, NSWindowDelegate {
    private let captureSession = AVCaptureSession()
    private let cameraName: String
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

        // Request camera access, then set up capture on main thread.
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        AppDelegate.log("CameraPreview: auth=\(auth.rawValue) for '\(cameraName)'")
        switch auth {
        case .authorized:
            setupCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                AppDelegate.log("CameraPreview: access request result=\(granted)")
                if granted { DispatchQueue.main.async { self?.setupCapture() } }
            }
        case .denied, .restricted:
            AppDelegate.log("CameraPreview: camera access denied/restricted — cannot preview")
        @unknown default:
            break
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupCapture() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified)
        let allDevices = discovery.devices
        AppDelegate.log("CameraPreview: \(allDevices.count) device(s): \(allDevices.map(\.localizedName).joined(separator: ", "))")

        guard let device = allDevices.first(where: { $0.localizedName == cameraName })
                        ?? allDevices.first(where: {
                            $0.localizedName.contains(cameraName) || cameraName.contains($0.localizedName)
                        }) else {
            AppDelegate.log("CameraPreview: no device matching '\(cameraName)'")
            return
        }
        AppDelegate.log("CameraPreview: matched '\(device.localizedName)'")

        guard let input = try? AVCaptureDeviceInput(device: device) else {
            AppDelegate.log("CameraPreview: AVCaptureDeviceInput failed for '\(device.localizedName)'")
            return
        }

        captureSession.addInput(input)

        let captureView = AVCaptureView(frame: window!.contentView!.bounds)
        captureView.autoresizingMask = [.width, .height]
        captureView.setSession(captureSession, showVideoPreview: true, showAudioPreview: false)
        window?.contentView?.addSubview(captureView)

        captureSession.startRunning()
        AppDelegate.log("CameraPreview: session started for '\(device.localizedName)'")
    }

    func windowWillClose(_ notification: Notification) {
        captureSession.stopRunning()
        onClose?()
    }
}

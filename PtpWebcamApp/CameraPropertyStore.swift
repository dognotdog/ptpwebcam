// CameraPropertyStore.swift
//
// Host-app singleton that mirrors the extension's camera property state
// into a `@Published` dictionary so SwiftUI views (currently the
// preview-window HUD) can render the same values the agent shows in
// its menu bar — without depending on the agent process at all.
//
// Subscribes directly to the same Darwin notify channels the agent uses
// (`kDarwinCameraPropertyState`), reuses the shared
// `CameraPropertyStatePageReassembler` + `ExtCamera.parse` from
// CameraModel.swift, and asks the extension to republish current state
// on first init via `kDarwinCameraStateRepublish` so we don't have to
// wait for the next camera plug event.
//
// Single-instance: there's only ever one extension producing state, and
// Darwin notify dispatch tokens are process-global anyway. Constructing
// multiple stores would just multiply the parsing work without any
// behavioral difference.

import Foundation
import Combine
import os.log

final class CameraPropertyStore: ObservableObject {
    static let shared = CameraPropertyStore()

    /// Latest known state for every camera the extension has published.
    /// Keyed by `ExtCamera.cameraId` (e.g. "usb-000000010001c930"),
    /// the same key the agent uses internally. SwiftUI views typically
    /// look up by `name` (the user-visible camera label) since that's
    /// what `AVCaptureDevice.localizedName` matches against — see
    /// `camera(matchingName:)` below.
    @Published private(set) var cameras: [String: ExtCamera] = [:]

    private let logger = Logger(subsystem: "org.ptpwebcam.PtpWebcamApp", category: "CameraPropertyStore")

    /// Tokens registered with notifyd. Kept alive for the process
    /// lifetime — no unsubscribe path since this is a singleton tied
    /// to the host-app process.
    /// Stream receiver for the property-state channel. Replaces the
    /// per-page slot-chain reassembler that used to live here; the
    /// per-slot-notify stream protocol removes the inter-page
    /// coalescing window that was producing torn reads under
    /// `.main` UI contention.
    private var streamReceiver: CameraStreamReceiver?
    private let receiverQueue = DispatchQueue(
        label: "org.ptpwebcam.PtpWebcamApp.CameraPropertyStore.receiver",
        qos: .userInteractive)

    private init() {
        let log = self.logger
        let receiver = CameraStreamReceiver(queue: receiverQueue)
        receiver.onError = { msg in log.error("\(msg, privacy: .public)") }
        receiver.onPayload = { [weak self] payload in
            self?.handlePayload(payload)
        }
        receiver.start()
        self.streamReceiver = receiver

        // The extension only sends camera state on attach / on change,
        // and Darwin notify doesn't replay for late subscribers. If the
        // host-app window opens after a camera was already enumerated,
        // the store would stay empty until the next plug event without
        // this republish kick. (The agent does the same handshake on
        // its own launch — see kDarwinCameraStateRepublish docs.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            darwin_notify_post(kDarwinCameraStateRepublish)
        }
    }

    /// Called on `receiverQueue` once `CameraStreamReceiver` has a
    /// fully-validated transmission to hand off. Parses the JSON
    /// here (heavy work off `.main`), then dispatches the
    /// `@Published` mutation back to `.main` for SwiftUI / Combine
    /// observers.
    private func handlePayload(_ payload: Data) {
        let result = ExtCamera.parse(jsonData: payload)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch result {
            case .invalid:
                self.logger.error("invalid property-state JSON payload (\(payload.count) bytes)")
            case .disconnected(let cameraId):
                self.cameras.removeValue(forKey: cameraId)
            case .camera(let cam):
                self.cameras[cam.cameraId] = cam
            }
        }
    }

    // MARK: - Lookup helpers

    /// Returns the `ExtCamera` whose user-visible name matches the
    /// given AVCapture device name. Uses the same exact-then-substring
    /// fallback `CameraPreviewWindowController` already uses for its
    /// AVCaptureDevice match — so HUD lookups stay consistent with
    /// which camera the preview is actually pointed at.
    func camera(matchingName name: String) -> ExtCamera? {
        if let exact = cameras.values.first(where: { $0.name == name }) {
            return exact
        }
        return cameras.values.first(where: {
            $0.name.contains(name) || name.contains($0.name)
        })
    }
}

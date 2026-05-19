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
    private var propSlotTokens: [Int32] = []
    private var propStateToken: Int32 = 0

    /// Reassembles the slot-chain pages into one JSON blob per publish.
    /// Same class the agent uses (see CameraModel.swift) so any bug in
    /// the wire format gets fixed in one place.
    private let reassembler: CameraPropertyStatePageReassembler

    private init() {
        let r = CameraPropertyStatePageReassembler()
        let log = self.logger
        r.onError = { msg in log.error("\(msg, privacy: .public)") }
        self.reassembler = r

        // Register every property-state slot for reads (we don't get
        // dispatched on slot writes — only on the parent notify name —
        // but `darwin_notify_get_state` needs a token per slot).
        for i in 0..<kDarwinPropertySlotCount {
            var token: Int32 = 0
            darwin_notify_register_check(kDarwinPropertySlotPrefix + "\(i)", &token)
            propSlotTokens.append(token)
        }

        // Subscribe to the publish notification — fired by the
        // extension once per page during a state update. The handler
        // pulls slot values and feeds them to the reassembler;
        // when the reassembler returns a complete payload we parse +
        // republish on the main queue (caller dispatch is .main).
        darwin_notify_register_dispatch(kDarwinCameraPropertyState, &propStateToken, .main) { [weak self] _ in
            self?.handlePage()
        }

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

    private func handlePage() {
        guard let payload = reassembler.handlePage(slotTokens: propSlotTokens) else { return }
        switch ExtCamera.parse(jsonData: payload) {
        case .invalid:
            logger.error("invalid property-state JSON payload (\(payload.count) bytes)")
        case .disconnected(let cameraId):
            cameras.removeValue(forKey: cameraId)
        case .camera(let cam):
            cameras[cam.cameraId] = cam
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

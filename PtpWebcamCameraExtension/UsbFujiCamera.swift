// UsbFujiCamera.swift
// Fujifilm X / GFX PTP integration.
//
// Fuji bodies advertise the standard PTP property model — `GetDevicePropDesc`
// (0x1014) works directly after OpenSession, so discovery and property
// setting both inherit from `UsbPtpCameraBase` defaults.
//
// Live view is the only piece that needs a Fuji-specific path:
//
//   1. Start: InitiateOpenCapture(0, 0) — standard PTP 0x101C with both
//      parameters zero. Retried up to 5 times because Fuji bodies will
//      respond DeviceBusy if they're still in playback mode.
//
//   2. Per frame:
//        GetObjectInfo(0x80000001)   — handle 0x80000001 is the live-view
//                                       slot. Returns InvalidObjectHandle
//                                       (0x2009) until the camera has a
//                                       fresh frame queued; loop with a
//                                       5 ms sleep.
//        GetObject(0x80000001)        — fetches the JPEG (FF D8 … FF D9
//                                       with no header to strip). May
//                                       return DeviceBusy if polled too
//                                       fast — retry with 1 ms sleep.
//        DeleteObject(0x80000001, 0)  — clears the slot so the camera
//                                       refills it.
//
//   3. Stop: Fuji.CancelInitiateCapture (0x9030).
//
// The handle (0x80000001) is the convention sigma-ptpy / libgphoto2 / the
// official Fuji SDK all use. Newer bodies (X-S10, X-H2, X-T5, GFX 100 II)
// support the same protocol; the wire format hasn't changed.

import Foundation

private let PTP_CMD_FUJI_CANCEL_INITIATE_CAPTURE: UInt16 = 0x9030

/// Live-view slot. Fuji exposes the latest viewfinder JPEG at this
/// synthetic ObjectHandle. Same value across the X- and GFX-series.
private let FUJI_LIVEVIEW_HANDLE: UInt32 = 0x80000001

/// Fuji "Camera Action" property. Standard `SetDevicePropValue` (0x1016)
/// writes a UINT16 enum here to drive the shutter state machine:
///   0x0200 = trigger AF / half-press  (then poll 0xD209 for lock)
///   0x0304 = full press / take picture
///   0x0004 = "shoot anyway" override after AF fail
private let PTP_DPC_FUJI_CAMERA_ACTION: UInt32 = 0xD208
private let FUJI_ACTION_AF_TRIGGER:     UInt32 = 0x0200

/// Fuji AF status, read-only enum:
///   0x0001 = AF in progress
///   0x0002 = AF locked
///   0x0003 = AF failed (out of focus / nothing to focus on)
///   0x0004 = idle / unknown
private let PTP_DPC_FUJI_AF_STATUS:    UInt32 = 0xD209

final class UsbFujiCamera: UsbPtpCameraBase {

    /// True once we've successfully issued InitiateOpenCapture. We can
    /// only stop the capture once we've started — without this guard the
    /// `runCleanUpPhase` (which calls stopLiveViewSession unconditionally)
    /// would send CancelInitiateCapture on a fresh-attached camera and
    /// the firmware may reply with a spurious error code.
    private var fujiInLiveView = false

    init(transport: UsbPtpTransport) {
        super.init(transport: transport, logTag: "UsbFujiCamera")
    }

    // MARK: - Live view

    override func startLiveViewSession() -> Bool {
        guard supportedOps.contains(PTP_CMD_INITIATEOPENCAPTURE) else {
            liveViewStartError = "Fuji camera doesn't advertise InitiateOpenCapture (0x101C). Body may need a firmware update — Fuji's USB Tether requires it from firmware ~3.x onwards."
            return false
        }
        // Up to 5 retries. Fuji bodies that haven't finished waking from
        // playback / sleep can answer DeviceBusy on the first attempt.
        var lastCode: UInt16 = 0
        for attempt in 1...5 {
            if closing { return false }
            let cmd = transport.buildCommand(code: PTP_CMD_INITIATEOPENCAPTURE,
                                              parameters: [0, 0])
            guard let (_, rsp) = try? transport.sendPtpCommand(cmd) else {
                lastCode = 0xFFFF
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            lastCode = transport.responseCode(from: rsp)
            cameraLog.fault("Fuji InitiateOpenCapture attempt \(attempt, privacy: .public) → 0x\(String(lastCode, radix: 16), privacy: .public)")
            if lastCode == PTP_RSP_OK {
                fujiInLiveView = true
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        liveViewStartError = "Fuji refused InitiateOpenCapture after 5 attempts (last response 0x\(String(lastCode, radix: 16))). Check that the camera is on, not in playback mode, and not actively recording video."
        return false
    }

    override func stopLiveViewSession() {
        guard fujiInLiveView else { return }
        fujiInLiveView = false
        // CancelInitiateCapture takes a single transaction-ID parameter
        // that identifies which capture to cancel. Track the
        // initiating txn ID (`opencapture_transid`) and pass it on. We
        // don't have that ID handy in our transport API, so we issue
        // with param=0 — Fuji accepts this as "cancel current capture".
        let cmd = transport.buildCommand(code: PTP_CMD_FUJI_CANCEL_INITIATE_CAPTURE,
                                          parameters: [0])
        _ = try? transport.sendPtpCommand(cmd)
    }

    override func fetchOneFrame() throws -> Data? {
        // Phase 1: poll for a ready frame via GetObjectInfo. The camera
        // returns InvalidObjectHandle while the next preview is being
        // assembled, so we tolerate that for up to ~200 ms before giving
        // up on this frame (the LV loop will call us again).
        let oiCmd = transport.buildCommand(code: PTP_CMD_GETOBJECTINFO,
                                            parameters: [FUJI_LIVEVIEW_HANDLE])
        var oiReady = false
        for _ in 0..<40 {  // 40 × 5 ms = 200 ms cap
            if stopLv || closing { return nil }
            let (_, oiRsp) = try transport.sendPtpCommand(oiCmd)
            let oiCode = transport.responseCode(from: oiRsp)
            if oiCode == PTP_RSP_OK {
                oiReady = true
                break
            }
            if oiCode == PTP_RSP_INVALIDOBJECTHANDLE {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            // Anything else (e.g. DeviceBusy) — bail out on this frame.
            cameraLog.fault("Fuji GetObjectInfo → 0x\(String(oiCode, radix: 16), privacy: .public)")
            return nil
        }
        guard oiReady else { return nil }

        // Phase 2: fetch the JPEG. DeviceBusy means we polled too fast;
        // a short retry sleep is enough.
        let goCmd = transport.buildCommand(code: PTP_CMD_GETOBJECT,
                                            parameters: [FUJI_LIVEVIEW_HANDLE])
        var jpegData: Data?
        for _ in 0..<5 {
            if stopLv || closing { return nil }
            let (inData, goRsp) = try transport.sendPtpCommand(goCmd)
            let goCode = transport.responseCode(from: goRsp)
            if goCode == PTP_RSP_OK, let data = inData, !data.isEmpty {
                jpegData = data
                break
            }
            if goCode == PTP_RSP_DEVICEBUSY || goCode == PTP_RSP_ACCESSDENIED {
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }
            cameraLog.fault("Fuji GetObject(0x80000001) → 0x\(String(goCode, radix: 16), privacy: .public)")
            return nil
        }

        // Phase 3: clear the slot so the camera makes a new frame.
        // Failures here aren't fatal — the next iteration will time out
        // on InvalidObjectHandle and reset.
        let delCmd = transport.buildCommand(code: PTP_CMD_DELETEOBJECT,
                                             parameters: [FUJI_LIVEVIEW_HANDLE, 0])
        _ = try? transport.sendPtpCommand(delCmd)

        // Fuji returns raw JPEG with no header. Defensive
        // extractJpegFromLiveViewData fallback in case a body prepends
        // a metadata block — it scans for SOI markers.
        return jpegData.flatMap { extractJpegFromLiveViewData($0) ?? $0 }
    }

    // MARK: - Autofocus

    /// Fuji AF trigger via the "Camera Action" property (0xD208). The wire pattern preserves the user's
    /// on-camera AF zone selection — no focus-point coordinates needed:
    ///
    ///   1. SetDevicePropValue(0xD208 = 0x0200, UINT16)   — arm AF
    ///   2. InitiateCapture(0, 0)                          — fire the action
    ///   3. Poll GetDevicePropValue(0xD209) until != 1     — wait for lock
    ///        0x0002 = locked, 0x0003 = failed (no contrast)
    ///
    /// We do NOT take the picture (the 0x0304 "shoot" follow-up step) — this is a webcam tool, autofocus only.
    override func performAutofocus() {
        guard sessionOpen else { return }
        guard supportedOps.contains(PTP_CMD_SETPROPVAL),
              supportedOps.contains(PTP_CMD_INITIATECAPTURE) else {
            cameraLog.fault("Fuji AF skipped — needs SetDevicePropValue (0x1016) + InitiateCapture (0x100E).")
            return
        }
        // Step 1: arm AF via Camera Action property.
        let payload = encodeStandardPtpValue(FUJI_ACTION_AF_TRIGGER, dataType: 4 /* UINT16 */)
        let setCmd = transport.buildCommand(code: PTP_CMD_SETPROPVAL,
                                             parameters: [PTP_DPC_FUJI_CAMERA_ACTION])
        guard let (_, setRsp) = try? transport.sendPtpCommand(setCmd, outData: payload) else {
            cameraLog.fault("Fuji AF: SetDevicePropValue(0xD208=0x0200) transport error.")
            return
        }
        let setCode = transport.responseCode(from: setRsp)
        cameraLog.fault("Fuji AF arm (0xD208=0x0200) → 0x\(String(setCode, radix: 16), privacy: .public)")
        guard setCode == PTP_RSP_OK else { return }

        // Step 2: trigger via InitiateCapture(0, 0).
        let icCmd = transport.buildCommand(code: PTP_CMD_INITIATECAPTURE,
                                            parameters: [0, 0])
        let icRsp = (try? transport.sendPtpCommand(icCmd))?.1
        let icCode = icRsp.map { transport.responseCode(from: $0) } ?? 0xFFFF
        cameraLog.fault("Fuji AF fire (InitiateCapture 0,0) → 0x\(String(icCode, radix: 16), privacy: .public)")
        guard icCode == PTP_RSP_OK else { return }

        // Step 3: poll AF status. Cap at ~3 s — beyond that the camera is
        // probably stuck (subject too dark / no contrast).
        let pollCmd = transport.buildCommand(code: PTP_CMD_GETPROPVAL,
                                              parameters: [PTP_DPC_FUJI_AF_STATUS])
        for _ in 0..<60 {  // 60 × 50 ms = 3 s
            Thread.sleep(forTimeInterval: 0.05)
            guard let (data, pollRsp) = try? transport.sendPtpCommand(pollCmd) else { break }
            let pollCode = transport.responseCode(from: pollRsp)
            guard pollCode == PTP_RSP_OK, let d = data, d.count >= 2 else { continue }
            let status = UInt16(d[0]) | (UInt16(d[1]) << 8)
            if status == 0x0001 { continue }   // still hunting
            cameraLog.fault("Fuji AF status (0xD209) → 0x\(String(status, radix: 16), privacy: .public) (\(status == 2 ? "locked" : status == 3 ? "failed" : "idle", privacy: .public))")
            return
        }
        cameraLog.fault("Fuji AF timed out waiting for 0xD209 ≠ 1.")
    }
}

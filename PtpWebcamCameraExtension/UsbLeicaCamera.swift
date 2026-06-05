// UsbLeicaCamera.swift
// Modern Leica PTP integration (VID 0x1A98).
//
// Covers M9 / M10 / M11 / M11 Monochrom, Q-series (Q / Q2 / Q3), and
// SL-series (SL / SL2 / SL3) plus the S3. These bodies speak standard PTP
// for discovery and property setting; the base class default takes care
// of `GetDevicePropDesc` (0x1014) and `SetDevicePropValue` (0x1016).
//
// Live view rides PTP 1.1's stream API plus a Leica-specific frame-fetch
// opcode:
//   1. Set PTP_DPC_EnabledStreams (0x5021) = 1 via standard
//      SetDevicePropValue (0x1016). This switches the camera into
//      "streaming" mode and starts populating its preview pipeline.
//   2. Per-frame: PTP_OC_LEICA_LEGetStreamData (0x9025) returns a binary
//      blob with a ~0xC0 byte Leica header followed by a raw JPEG
//      (FF D8 ... FF D9). `extractJpegFromLiveViewData` strips the header
//      by scanning for SOI/EOI markers.
//   3. Stop: write EnabledStreams = 0 to release the stream.
//
// Legacy Leica D-LUX / V-Lux / C-Lux bodies on VID 0x04DA are rebadged
// Panasonic firmware and dispatch to `UsbPanasonicCamera` instead via
// `protocolFamily(forVid:pid:)` — they never reach this class.

import Foundation

private let PTP_CMD_LEICA_GET_STREAM_DATA: UInt16 = 0x9025
private let PTP_PROP_ENABLED_STREAMS:      UInt32 = 0x5021

/// Leica's release ladder opcode. The parameter selects the stage:
///   1     = push AF control       (equivalent to half-press shutter)
///   2     = release AF control    (release half-press)
///   0x0C  = continuous burst start
///   0x0D  = continuous burst end
private let PTP_CMD_LEICA_RELEASE_STAGES:  UInt16 = 0x9004
private let LEICA_RELEASE_AF_PUSH:        UInt32 = 1
private let LEICA_RELEASE_AF_RELEASE:     UInt32 = 2

final class UsbLeicaCamera: UsbPtpCameraBase {

    /// True once we've issued the SetDevicePropValue that flipped
    /// PTP_DPC_EnabledStreams to 1. Used to guard the cleanup write — we
    /// don't want to send `EnabledStreams=0` on a body that never got a
    /// proper start (e.g. we bailed because the opcode wasn't advertised).
    private var leicaStreamActive = false

    init(transport: UsbPtpTransport) {
        super.init(transport: transport, logTag: "UsbLeicaCamera")
    }

    // MARK: - Live view

    override func startLiveViewSession() -> Bool {
        guard supportedOps.contains(PTP_CMD_LEICA_GET_STREAM_DATA) else {
            liveViewStartError = "Leica camera doesn't advertise LEGetStreamData (0x9025). Live view requires a body in the M11 / Q3 / SL3 family with current firmware."
            return false
        }
        guard supportedOps.contains(PTP_CMD_SETPROPVAL) else {
            liveViewStartError = "Leica camera doesn't advertise standard SetDevicePropValue (0x1016) — can't enable the video stream."
            return false
        }
        // Flip EnabledStreams to 1. The PTP 1.1 stream API spec says
        // this property is a 32-bit bitfield of enabled stream IDs; bit
        // 0 = video.
        let payload = encodeStandardPtpValue(1, dataType: 6 /* UINT32 */)
        let cmd = transport.buildCommand(code: PTP_CMD_SETPROPVAL,
                                          parameters: [PTP_PROP_ENABLED_STREAMS])
        guard let (_, rsp) = try? transport.sendPtpCommand(cmd, outData: payload) else {
            liveViewStartError = "Leica EnabledStreams=1 (0x5021) transport error."
            return false
        }
        let code = transport.responseCode(from: rsp)
        cameraLog.fault("Leica EnabledStreams=1 → 0x\(String(code, radix: 16), privacy: .public)")
        if code != PTP_RSP_OK {
            liveViewStartError = "Leica refused EnabledStreams=1 (response 0x\(String(code, radix: 16))). The body may be in playback mode, or this firmware doesn't support tethered streaming."
            return false
        }
        leicaStreamActive = true
        Thread.sleep(forTimeInterval: 0.15)   // settle for first frame
        return true
    }

    override func stopLiveViewSession() -> Bool {
        guard leicaStreamActive else { return true }
        leicaStreamActive = false
        // Release the stream. Camera tolerates a non-polling host but
        // explicit disable lets the body return to whatever idle state
        // it was in (saves battery and clears the preview pipeline).
        let payload = encodeStandardPtpValue(0, dataType: 6 /* UINT32 */)
        let cmd = transport.buildCommand(code: PTP_CMD_SETPROPVAL,
                                          parameters: [PTP_PROP_ENABLED_STREAMS])
        do {
            _ = try transport.sendPtpCommand(cmd, outData: payload)
            return true
        } catch {
            cameraLog.fault("Leica ENABLED_STREAMS=0 error: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    override func fetchOneFrame() throws -> Data? {
        let cmd = transport.buildCommand(code: PTP_CMD_LEICA_GET_STREAM_DATA)
        // This is a plain GETDATA
        // transaction with no parameters and no retry loop — Leica's
        // streaming pipeline is expected to have a frame ready by the
        // time we ask. If we polled too fast and get DeviceBusy, the
        // outer LV loop will call us again on the next iteration.
        let (inData, rsp) = try transport.sendPtpCommand(cmd)
        let code = transport.responseCode(from: rsp)
        guard code == PTP_RSP_OK, let data = inData, data.count > 0xC0 else {
            // Short payload = camera still preparing first frame, or
            // post-stop straggler. Nil signals the outer loop to retry.
            if code != PTP_RSP_OK {
                cameraLog.fault("Leica LEGetStreamData (0x9025) → 0x\(String(code, radix: 16), privacy: .public) size=\(inData?.count ?? -1, privacy: .public)")
            }
            return nil
        }
        // Leica prepends a ~0xC0 byte vendor frame header before the
        // JPEG SOI marker. `extractJpegFromLiveViewData` scans for
        // FF D8 ... FF D9 so it naturally strips both that header and
        // anything else the camera might tack on.
        return extractJpegFromLiveViewData(data) ?? data
    }

    // MARK: - Autofocus

    /// Leica AF trigger via the release ladder. Push the AF "button" (stage 1),
    /// give the camera ~250 ms to converge, then release (stage 2).
    override func performAutofocus() {
        guard sessionOpen else { return }
        guard supportedOps.contains(PTP_CMD_LEICA_RELEASE_STAGES) else {
            cameraLog.fault("Leica AF skipped — body doesn't advertise LEReleaseStages (0x9004).")
            return
        }
        let push = transport.buildCommand(code: PTP_CMD_LEICA_RELEASE_STAGES,
                                           parameters: [LEICA_RELEASE_AF_PUSH])
        let pushRsp = (try? transport.sendPtpCommand(push))?.1
        let pushCode = pushRsp.map { transport.responseCode(from: $0) } ?? 0xFFFF
        cameraLog.fault("Leica AF push (0x9004 stage=1) → 0x\(String(pushCode, radix: 16), privacy: .public)")
        Thread.sleep(forTimeInterval: 0.25)
        let release = transport.buildCommand(code: PTP_CMD_LEICA_RELEASE_STAGES,
                                              parameters: [LEICA_RELEASE_AF_RELEASE])
        let relRsp = (try? transport.sendPtpCommand(release))?.1
        let relCode = relRsp.map { transport.responseCode(from: $0) } ?? 0xFFFF
        cameraLog.fault("Leica AF release (0x9004 stage=2) → 0x\(String(relCode, radix: 16), privacy: .public)")
    }
}

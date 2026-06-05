// UsbNikonCamera.swift
// Nikon PTP session running directly over USB inside the CMIO extension.
// All lifecycle, queue, pacing, and pending-set logic lives in UsbPtpCameraBase.

import Foundation
import CoreGraphics
import ImageIO
import CoreVideo
import os.log

// MARK: - Nikon PTP constants

private let PTP_CMD_NIKON_GETVENDORPROPS:    UInt16 = 0x90CA
private let PTP_CMD_NIKON_AFDRIVE:           UInt16 = 0x90C1
private let PTP_CMD_NIKON_CHANGECAMERAMODE:  UInt16 = 0x90C2  // param 0=PC camera, 1=remote/tethered
private let PTP_CMD_NIKON_STARTLIVEVIEW:     UInt16 = 0x9201
private let PTP_CMD_NIKON_STOPLIVEVIEW:      UInt16 = 0x9202
private let PTP_CMD_NIKON_GETLIVEVIEWIMG:    UInt16 = 0x9203
private let PTP_CMD_NIKON_DEVICEREADY:       UInt16 = 0x90C8
private let PTP_CMD_NIKON_GETVENDORCODES:    UInt16 = 0x9439
private let PTP_CMD_NIKON_GETLIVEVIEWIMGEX:  UInt16 = 0x9428  // Z-series

private let PTP_RSP_NIKON_NOTLIVEVIEW:       UInt16 = 0xA00B

// MARK: - Nikon vendor property codes (PTP_DPC_NIKON_*)
//
// Where Nikon overloaded a single property ID across body generations, the
// constant name carries both meanings joined by `_OR_`. The second name is
// prefixed `Z_` when the divergence is DSLR-vs-Z body.

private let PTP_PROP_NIKON_WB_AUTO_BIAS:         UInt16 = 0xD017
private let PTP_PROP_NIKON_WB_TUNGSTEN_BIAS:     UInt16 = 0xD018
private let PTP_PROP_NIKON_WB_FLUORESCENT_BIAS:  UInt16 = 0xD019
private let PTP_PROP_NIKON_WB_DAYLIGHT_BIAS:     UInt16 = 0xD01A
private let PTP_PROP_NIKON_WB_FLASH_BIAS:        UInt16 = 0xD01B
private let PTP_PROP_NIKON_WB_CLOUDY_BIAS:       UInt16 = 0xD01C
private let PTP_PROP_NIKON_WB_SHADE_BIAS:        UInt16 = 0xD01D
private let PTP_PROP_NIKON_WB_COLOR_TEMP:        UInt16 = 0xD01E
private let PTP_PROP_NIKON_ISO_AUTO:             UInt16 = 0xD054
/// DSLR: LiveViewAFArea. Z bodies: StillFocusMeteringMode.
private let PTP_PROP_NIKON_LV_AF_AREA_OR_Z_STILL_FOCUS_METERING_MODE: UInt16 = 0xD05D
/// DSLR: LiveViewAFFocus (AfModeAtLiveView). Z bodies: StillFocusMode.
private let PTP_PROP_NIKON_LV_AF_FOCUS_OR_Z_STILL_FOCUS_MODE:        UInt16 = 0xD061
private let PTP_PROP_NIKON_SHUTTER_SPEED:        UInt16 = 0xD100
private let PTP_PROP_NIKON_WB_AUTO_TYPE:         UInt16 = 0xD141
private let PTP_PROP_NIKON_FLUORESCENT_TYPE:     UInt16 = 0xD14F
private let PTP_PROP_NIKON_TUNE_COLOR_TEMP:      UInt16 = 0xD150
private let PTP_PROP_NIKON_APPLY_LV_SETTING:     UInt16 = 0xD17B
private let PTP_PROP_NIKON_LV_MODE:              UInt16 = 0xD1A0
private let PTP_PROP_NIKON_LV_STATUS:            UInt16 = 0xD1A2
private let PTP_PROP_NIKON_LV_ZOOM_RATIO:        UInt16 = 0xD1A3
private let PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW:  UInt16 = 0xD1A5
private let PTP_PROP_NIKON_LV_SELECTOR:          UInt16 = 0xD1A6
private let PTP_PROP_NIKON_MOVIE_SHUTTER_SPEED:  UInt16 = 0xD1A8
private let PTP_PROP_NIKON_MOVIE_FNUMBER:        UInt16 = 0xD1A9
private let PTP_PROP_NIKON_MOVIE_EXPOSURE_BIAS:  UInt16 = 0xD1AB
/// Older DSLR: LiveViewMovieMode. D850 and later: LiveViewImageSize.
/// Not a DSLR-vs-Z split — both meanings are DSLR-era, just different
/// generations — so no `_Z_` prefix.
private let PTP_PROP_NIKON_LV_MOVIE_MODE_OR_LV_IMAGE_SIZE: UInt16 = 0xD1AC

// Header bytes to skip before the JPEG payload, keyed on USB product ID.
// All D800-era and later Nikon bodies use 384 bytes; older bodies use 64 or 128.
private let nikonLvHeaderLen: [UInt16: Int] = [
    0x041A: 64,  0x041C: 64,  0x0420: 64,  0x0421: 128,
    0x0422: 64,  0x0423: 128, 0x0425: 64,  0x0426: 128,
    0x0428: 384, 0x0429: 384, 0x042A: 384, 0x042B: 384,
    0x042C: 384, 0x042D: 384, 0x042E: 384, 0x042F: 384,
    0x0430: 384, 0x0431: 384, 0x0432: 384, 0x0433: 384,
    0x0434: 384, 0x0435: 384, 0x0436: 384, 0x0437: 384,
    0x0438: 384, 0x0439: 384, 0x043A: 384, 0x043B: 384,
    0x043C: 384, 0x043D: 384, 0x043F: 384, 0x0440: 384,
    0x0441: 384, 0x0442: 384, 0x0443: 384, 0x0444: 384,
    0x0445: 384, 0x0446: 384, 0x0447: 384, 0x0448: 384,
    0x044B: 384, 0x044C: 384, 0x044F: 384, 0x0450: 384, 0x0451: 384,
]

// Fallback property list if GetDeviceInfo / GetVendorProps fail. Grouped by
// theme rather than by code so the reader can see what each line covers.
private let nikonUiPropertyIds: [UInt16] = [
    // Battery + lens info (standard PTP)
    PTP_PROP_BATTERYLEVEL,
    PTP_PROP_FOCALLENGTH,
    // Live-view state
    PTP_PROP_NIKON_LV_SELECTOR,
    PTP_PROP_NIKON_LV_STATUS,
    // Exposure: program / aperture / ISO / shutter speed
    PTP_PROP_EXPOSUREPROGRAMMODE,
    PTP_PROP_FNUMBER,
    PTP_PROP_NIKON_MOVIE_FNUMBER,
    PTP_PROP_EXPOSUREINDEX,
    PTP_PROP_NIKON_ISO_AUTO,
    PTP_PROP_NIKON_SHUTTER_SPEED,
    PTP_PROP_NIKON_MOVIE_SHUTTER_SPEED,
    // White balance + exposure bias
    PTP_PROP_WHITEBALANCE,
    PTP_PROP_EXPOSUREBIAS,
    PTP_PROP_NIKON_MOVIE_EXPOSURE_BIAS,
    // Focus
    PTP_PROP_NIKON_LV_AF_FOCUS_OR_Z_STILL_FOCUS_MODE,
    PTP_PROP_NIKON_LV_AF_AREA_OR_Z_STILL_FOCUS_METERING_MODE,
    // LV display / zoom / exposure preview / mode
    PTP_PROP_NIKON_LV_ZOOM_RATIO,
    PTP_PROP_NIKON_LV_MODE,
    PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW,
    PTP_PROP_NIKON_APPLY_LV_SETTING,
    PTP_PROP_NIKON_LV_MOVIE_MODE_OR_LV_IMAGE_SIZE,
    // White-balance fine-tune per preset
    PTP_PROP_NIKON_WB_AUTO_BIAS,
    PTP_PROP_NIKON_WB_TUNGSTEN_BIAS,
    PTP_PROP_NIKON_WB_FLUORESCENT_BIAS,
    PTP_PROP_NIKON_WB_DAYLIGHT_BIAS,
    PTP_PROP_NIKON_WB_FLASH_BIAS,
    PTP_PROP_NIKON_WB_CLOUDY_BIAS,
    PTP_PROP_NIKON_WB_SHADE_BIAS,
    PTP_PROP_NIKON_WB_COLOR_TEMP,
    // WB-related typing / fluorescent subtype / colour-temp tune
    PTP_PROP_NIKON_WB_AUTO_TYPE,
    PTP_PROP_NIKON_FLUORESCENT_TYPE,
    PTP_PROP_NIKON_TUNE_COLOR_TEMP,
]

// MARK: - UsbNikonCamera

final class UsbNikonCamera: UsbPtpCameraBase {

    private let headerLen: Int

    /// Z-series cameras: use GetLiveViewImageEx (0x9428). Set in `performVendorConnect`.
    private var usesLvEx = false

    /// Count of consecutive NOTLIVEVIEW responses — used to give up after repeated restarts.
    private var notLiveViewCount = 0

    init(transport: UsbPtpTransport) {
        self.headerLen = nikonLvHeaderLen[transport.productId] ?? 384
        super.init(transport: transport, logTag: "UsbNikonCamera")
        // Nikon's PTP stack needs more settle time after device attach.
        sessionOpenSettleSeconds = 1.0
    }

    // MARK: - Vendor connect

    override func performVendorConnect() {
        // Override the default GetDeviceInfo parser: Nikon also wants the props list
        // and the GetVendorProps / GetVendorCodes extension.
        parseDeviceInfoExtended()
    }

    private var cachedPropertyIds: [UInt16] = []

    private func parseDeviceInfoExtended() {
        let cmd = transport.buildCommand(code: PTP_CMD_GETDEVICEINFO)
        guard let (inData, rsp) = try? transport.sendPtpCommand(cmd),
              transport.responseCode(from: rsp) == PTP_RSP_OK,
              let data = inData else {
            cameraLog.fault("GetDeviceInfo failed — using hardcoded property list")
            cachedPropertyIds = nikonUiPropertyIds
            return
        }
        let p = PtpPropParser(data)
        _ = p.readU16(); _ = p.readU32(); _ = p.readU16()
        p.skipPtpString(); _ = p.readU16()
        guard let ops = p.readU16Array() else {
            cameraLog.fault("GetDeviceInfo ops parse failed — using hardcoded list")
            cachedPropertyIds = nikonUiPropertyIds
            return
        }
        p.skipArray(elementSize: 2)  // supported events
        guard let props = p.readU16Array() else {
            cameraLog.fault("GetDeviceInfo props parse failed — using hardcoded list")
            cachedPropertyIds = nikonUiPropertyIds
            return
        }

        supportedOps = Set(ops)
        usesLvEx = supportedOps.contains(PTP_CMD_NIKON_GETLIVEVIEWIMGEX)
        var allProps = props
        cameraLog.fault("GetDeviceInfo — \(props.count, privacy: .public) standard props, \(ops.count, privacy: .public) ops, usesLvEx=\(self.usesLvEx, privacy: .public)")

        if supportedOps.contains(PTP_CMD_NIKON_GETVENDORPROPS) {
            if let (vd, vRsp) = try? transport.sendPtpCommand(
                    transport.buildCommand(code: PTP_CMD_NIKON_GETVENDORPROPS)),
               transport.responseCode(from: vRsp) == PTP_RSP_OK,
               let vData = vd, vData.count >= 4,
               let vendorProps = PtpPropParser(vData).readU16Array() {
                allProps.append(contentsOf: vendorProps)
                cameraLog.fault("GetVendorProps — \(vendorProps.count, privacy: .public) additional props")
            }
        } else if supportedOps.contains(PTP_CMD_NIKON_GETVENDORCODES) {
            if let (vd, vRsp) = try? transport.sendPtpCommand(
                    transport.buildCommand(code: PTP_CMD_NIKON_GETVENDORCODES, parameters: [0x0D])),
               transport.responseCode(from: vRsp) == PTP_RSP_OK,
               let vData = vd, vData.count >= 4 {
                let vp = PtpPropParser(vData)
                if let count = vp.readU32() {
                    var vendorProps: [UInt16] = []
                    for _ in 0..<count {
                        if let v = vp.readU32() { vendorProps.append(UInt16(v & 0xFFFF)) }
                    }
                    allProps.append(contentsOf: vendorProps)
                    cameraLog.fault("GetVendorCodes — \(vendorProps.count, privacy: .public) additional props")
                }
            }
        }

        // Deduplicate while preserving order.
        var seen = Set<UInt16>()
        cachedPropertyIds = allProps.filter { seen.insert($0).inserted }
        cameraLog.fault("total \(self.cachedPropertyIds.count, privacy: .public) unique properties to discover")
    }

    // MARK: - Property discovery

    override func discoverAllProperties() -> [UInt32: UsbCameraProperty] {
        var result: [UInt32: UsbCameraProperty] = [:]
        for pid in cachedPropertyIds {
            if closing { break }
            if let prop = discoverSingleProperty(pid) {
                result[UInt32(pid)] = prop
            }
        }
        discoveredProperties.merge(result) { $1 }
        return result
    }

    /// Decode Nikon's `LiveViewProhibitCondition` (0xD1A4) bitfield into a
    /// human-readable summary for the log. Bits are best-effort — different
    /// Nikon bodies use slightly different encodings.
    private func describeProhibitBits(_ bits: UInt32) -> String {
        var parts: [String] = []
        if bits & 0x0001 != 0 { parts.append("aperture/lens") }
        if bits & 0x0002 != 0 { parts.append("battery low") }
        if bits & 0x0004 != 0 { parts.append("card/sequence") }
        if bits & 0x0008 != 0 { parts.append("mirror up") }
        if bits & 0x0010 != 0 { parts.append("processing") }
        if bits & 0x0020 != 0 { parts.append("mode U1/U2/U3") }
        if bits & 0x0040 != 0 { parts.append("temperature") }
        if bits & 0x0080 != 0 { parts.append("card protect") }
        if bits & 0x0100 != 0 { parts.append("no card") }
        if bits & 0x0200 != 0 { parts.append("mode") }
        if parts.isEmpty { parts.append("unknown") }
        return parts.joined(separator: ", ")
    }

    private func discoverSingleProperty(_ propId: UInt16) -> UsbCameraProperty? {
        let prop = getDevicePropDesc(UInt32(propId))
        if prop == nil {
            cameraLog.fault("GetDevicePropDesc 0x\(String(propId, radix:16), privacy: .public) — failed")
        }
        return prop
    }

    // MARK: - Live view session

    override func startLiveViewSession() -> Bool {
        // Z-series cameras start in PC camera mode; switch to remote/tethered.
        if supportedOps.contains(PTP_CMD_NIKON_CHANGECAMERAMODE) {
            cameraLog.fault("issuing ChangeCameraMode(1) — remote/tethered mode")
            _ = try? transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_NIKON_CHANGECAMERAMODE, parameters: [1]))
            Thread.sleep(forTimeInterval: 0.3)
        }
        var prohibitBits: UInt32 = 0
        if let prohibit = discoverSingleProperty(0xD1A4) {
            prohibitBits = prohibit.value.uint32Value
            if prohibitBits != 0 {
                cameraLog.fault("LV prohibit condition 0xD1A4 = 0x\(String(prohibitBits, radix:16), privacy: .public) — \(self.describeProhibitBits(prohibitBits), privacy: .public)")
            }
        }

        var startCode: UInt16 = 0
        do {
            let (_, rsp) = try transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_NIKON_STARTLIVEVIEW))
            startCode = transport.responseCode(from: rsp)
            if startCode == PTP_RSP_OK {
                cameraLog.fault("live view started")
            } else {
                cameraLog.fault("STARTLIVEVIEW code=0x\(String(startCode, radix:16), privacy: .public)")
            }
        } catch {
            cameraLog.fault("STARTLIVEVIEW error: \(String(describing: error), privacy: .public)")
            liveViewStartError = "Nikon: STARTLIVEVIEW failed at the USB transport level. The camera may be powered off or its USB connection is unstable."
            return false
        }

        // Fail fast when the camera physically refuses live view — e.g. SD card
        // missing/protected, body in U1/U2/U3 mode, battery low, or camera in
        // playback. Without this we'd spin through ~10s of NOTLIVEVIEW retries
        // and leave the CMIO client with a black preview.
        if startCode != PTP_RSP_OK && prohibitBits != 0 {
            cameraLog.fault("aborting live view: prohibit=0x\(String(prohibitBits, radix:16), privacy: .public) and STARTLIVEVIEW=0x\(String(startCode, radix:16), privacy: .public). Check SD card / mode dial / battery / playback state.")
            liveViewStartError = "Nikon refused live view: \(describeProhibitBits(prohibitBits)). Check the SD card, mode dial, battery, and that the camera isn't in playback mode."
            return false
        }

        waitForDeviceReady()
        notLiveViewCount = 0
        // Return value is the camera-side answer ("did STARTLIVEVIEW
        // succeed?"), NOT the user-intent answer. If STARTLIVEVIEW
        // returned OK, the camera is in live view (mirror up); the
        // state machine driver should set `actualLv = .on` even if
        // the user's `desiredLv` flipped to .off during the
        // device-ready poll, so that `performShutdownTransition`
        // runs cleanly and brings the mirror back down. The previous
        // `return !stopLv && !closing` conflated "vendor refused
        // live view" with "user changed mind during startup" — a
        // 15-ms CMIO start→stop race would surface a spurious
        // "live view could not be started" NSAlert even though the
        // camera had successfully started LV.
        if startCode == PTP_RSP_OK { return true }
        // Non-OK STARTLIVEVIEW with no prohibit bits: ambiguous.
        // The camera responded but didn't outright refuse. Defer
        // to the user-intent check — if they no longer want LV,
        // treat it as a failure so we don't enter the frame loop
        // with a body that may not actually be streaming.
        return !stopLv && !closing
    }

    override func stopLiveViewSession() -> Bool {
        do {
            let (_, rsp) = try transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_NIKON_STOPLIVEVIEW))
            let code = transport.responseCode(from: rsp)
            // PTP_RSP_OK (0x2001) is the normal success path.
            // Any non-OK code here is still a successful round-
            // trip — the camera received the command and
            // responded, even if it's complaining that we
            // weren't in LV. Treat as success because retrying
            // wouldn't change the outcome and the state machine
            // wants to know whether to advance, not whether the
            // camera was happy.
            if code != PTP_RSP_OK {
                cameraLog.fault("STOPLIVEVIEW non-OK code=0x\(String(code, radix:16), privacy: .public) — treating as terminated")
            }
            return true
        } catch {
            // Transport-level failure (USB stall, NotResponding,
            // device dead). Signal failure so the base class
            // retries — leaving the mirror up because of a
            // single stalled write is the exact failure mode
            // the state machine refactor was meant to fix.
            cameraLog.fault("STOPLIVEVIEW transport error: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// DSLR mirror-settle poll. Nikon DSLR bodies physically
    /// drop the mirror over 200–400 ms after STOPLIVEVIEW; the
    /// camera firmware reports DeviceReady = OK once the mirror
    /// has finished moving. Z-series and other mirrorless
    /// bodies (PIDs ≥ 0x0440 in Nikon's catalog) don't have a
    /// mirror, but DeviceReady still acks correctly so a short
    /// poll there is harmless — we skip it anyway to avoid the
    /// otherwise-wasted round-trip.
    override func confirmLiveViewSettled() {
        guard transport.productId < 0x0440 else { return }
        let deadline = Date().addingTimeInterval(1.5)
        var polls = 0
        while Date() < deadline {
            polls += 1
            do {
                let (_, rsp) = try transport.sendPtpCommand(
                    transport.buildCommand(code: PTP_CMD_NIKON_DEVICEREADY))
                if transport.responseCode(from: rsp) == PTP_RSP_OK {
                    cameraLog.fault("mirror settled (\(polls, privacy: .public) poll\(polls == 1 ? "" : "s", privacy: .public))")
                    return
                }
            } catch {
                // DeviceReady not supported, or transport
                // already dead — either way no point in
                // polling. The mirror will eventually settle
                // on its own; we just lose the confirmation.
                cameraLog.info("DEVICEREADY error during settle — proceeding")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        cameraLog.warning("mirror settle timeout after \(polls, privacy: .public) polls — proceeding anyway")
    }

    private func waitForDeviceReady() {
        for _ in 0..<30 {
            if stopLv || closing { return }
            Thread.sleep(forTimeInterval: 0.1)
            do {
                let (_, rsp) = try transport.sendPtpCommand(
                    transport.buildCommand(code: PTP_CMD_NIKON_DEVICEREADY))
                if transport.responseCode(from: rsp) == PTP_RSP_OK {
                    cameraLog.info("camera ready"); return
                }
            } catch {
                cameraLog.info("DEVICEREADY unsupported or error — proceeding")
                return
            }
        }
        cameraLog.warning("device never became ready, proceeding anyway")
    }

    // MARK: - Frame fetch

    override func fetchOneFrame() throws -> Data? {
        let lvCmd = usesLvEx ? PTP_CMD_NIKON_GETLIVEVIEWIMGEX : PTP_CMD_NIKON_GETLIVEVIEWIMG
        let lvHeaderLen = usesLvEx ? 1024 : headerLen

        let (inData, rsp) = try transport.sendPtpCommand(transport.buildCommand(code: lvCmd))
        let rspCode = transport.responseCode(from: rsp)

        if rspCode == PTP_RSP_NIKON_NOTLIVEVIEW {
            notLiveViewCount += 1
            if notLiveViewCount > 20 {
                cameraLog.fault("NOTLIVEVIEW after \(self.notLiveViewCount, privacy: .public) restarts — giving up")
                // `stopLv` is now a computed property derived
                // from the state machine; bail via the
                // force-stop latch so the loop exits cleanly
                // and the outer shutdown transition still runs
                // (issues STOPLIVEVIEW + polls the mirror down).
                setLvForceStop("NOTLIVEVIEW retry budget exhausted")
                return nil
            }
            cameraLog.fault("NOTLIVEVIEW — restarting (\(self.notLiveViewCount, privacy: .public))")
            restartLiveView()
            return nil
        }

        if let data = inData, data.count > lvHeaderLen {
            if let jpeg = extractJpegFromLiveViewData(data) {
                return jpeg
            }
            cameraLog.fault("no JPEG found in \(data.count, privacy: .public)B frame")
            return nil
        }
        if inData == nil && rspCode == PTP_RSP_DEVICEBUSY {
            Thread.sleep(forTimeInterval: 0.033)
            return nil
        }
        if let data = inData {
            cameraLog.fault("frame too small (\(data.count, privacy: .public)B, lvHeaderLen=\(lvHeaderLen, privacy: .public))")
        }
        return nil
    }

    private func restartLiveView() {
        // Send STOPLIVEVIEW + STARTLIVEVIEW as a pair. The early
        // exits below (after STOP, before START) are safe — STOP
        // alone leaves the camera in the same state we'd want
        // after a clean shutdown. The early exit after START
        // would be the dangerous one (mirror up, no follow-up
        // STOP), so we wait through `waitForDeviceReady`
        // unconditionally even if stopLv flips during the poll —
        // the outer state machine's `performShutdownTransition`
        // will issue the closing STOPLIVEVIEW once the loop
        // exits, so the mirror still comes down.
        _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_NIKON_STOPLIVEVIEW))
        Thread.sleep(forTimeInterval: 0.5)
        if stopLv { return }
        do {
            let (_, rsp) = try transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_NIKON_STARTLIVEVIEW))
            cameraLog.info("restart STARTLIVEVIEW code=0x\(String(self.transport.responseCode(from: rsp), radix:16), privacy: .public)")
            // Don't short-circuit `waitForDeviceReady` on stopLv
            // here — letting it complete means the camera is in
            // a known-good state when the outer shutdown
            // transition runs and issues its STOPLIVEVIEW.
            // (`waitForDeviceReady` still has its own bounded
            // timeout, so this won't hang.)
            waitForDeviceReady()
        } catch {
            cameraLog.error("restart error: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Event polling

    override func pollEvents() {
        while let eventData = transport.readInterruptEvent(timeout: 0.01) {
            guard eventData.count >= 16 else { continue }
            let eventCode = eventData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self) }
            guard eventCode == PTP_EVENT_DEVICEPROPCHANGED else { continue }
            let propId16 = eventData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt16.self) }
            cameraLog.fault("DEVICEPROPCHANGED 0x\(String(propId16, radix:16), privacy: .public)")
            if let prop = discoverSingleProperty(propId16) {
                discoveredProperties[UInt32(propId16)] = prop
                onPropertiesDiscovered?([UInt32(propId16): prop])
            }
        }
    }

    // MARK: - Property set

    override func performPropertySet(_ pending: PendingSet) {
        let code = sendStandardSetPropVal(propId: pending.propId, value: pending.value, dataType: pending.dataType) ?? 0
        cameraLog.fault("setProperty 0x\(String(pending.propId, radix:16), privacy: .public) = \(pending.value, privacy: .public) → 0x\(String(code, radix:16), privacy: .public)")
        if code == PTP_RSP_OK, let updated = discoverSingleProperty(UInt16(pending.propId & 0xFFFF)) {
            discoveredProperties[pending.propId] = updated
            onPropertiesDiscovered?([pending.propId: updated])
        }
    }

    // MARK: - Autofocus

    override func performAutofocus() {
        guard sessionOpen else { return }
        do {
            let (_, rsp) = try transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_NIKON_AFDRIVE))
            let code = transport.responseCode(from: rsp)
            cameraLog.fault("AfDrive → 0x\(String(code, radix:16), privacy: .public)")
        } catch {
            cameraLog.fault("AfDrive error: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Cleanup

    // No `performVendorCleanup` override: STOPLIVEVIEW now lives
    // in the state machine's shutdown transition, which close()
    // runs ahead of CLOSE_SESSION via `driveLiveViewState`. The
    // pre-CLOSE_SESSION hook is reserved for any future Nikon-
    // specific work that needs to happen between LV-off and
    // session close, which today is nothing.
}

// MARK: - JPEG → CVPixelBuffer
// (Shared by all USB camera implementations; the provider's onJpegFrame callback
// calls this regardless of vendor.)

/// Decode a JPEG into a freshly-allocated 32-BGRA CVPixelBuffer at the JPEG's
/// native dimensions. Aspect ratio is preserved exactly.
/// Must be called inside an autoreleasepool to ensure CG objects are released
/// promptly on the camera thread.
func jpegIntoPixelBuffer(_ jpegData: Data) -> CVPixelBuffer? {
    // Disable ImageIO's global decoded-pixel cache. Without this every frame's
    // decoded image data is retained in a process-wide cache and memory grows
    // continuously at ~30 fps.
    let sourceOpts = [kCGImageSourceShouldCache: false] as CFDictionary
    let imageOpts  = [kCGImageSourceShouldCacheImmediately: false] as CFDictionary
    guard let src = CGImageSourceCreateWithData(jpegData as CFData, sourceOpts),
          let cgImage = CGImageSourceCreateImageAtIndex(src, 0, imageOpts) else { return nil }

    let width  = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0 else { return nil }

    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                        &pixelBuffer)
    guard let pixelBuffer = pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let ctx = CGContext(
        data:             CVPixelBufferGetBaseAddress(pixelBuffer),
        width:            width,
        height:           height,
        bitsPerComponent: 8,
        bytesPerRow:      CVPixelBufferGetBytesPerRow(pixelBuffer),
        space:            CGColorSpaceCreateDeviceRGB(),
        bitmapInfo:       CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }

    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixelBuffer
}

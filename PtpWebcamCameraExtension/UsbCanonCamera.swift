// UsbCanonCamera.swift
// Canon EOS PTP session running directly over USB inside the CMIO extension.

import Foundation
import os.log

// MARK: - Canon PTP Constants

private let PTP_CMD_CANON_SETPROPVAL_EX:      UInt16 = 0x9110
private let PTP_CMD_CANON_SETREMOTEMODE:      UInt16 = 0x9114
private let PTP_CMD_CANON_SETEVENTMODE:       UInt16 = 0x9115
private let PTP_CMD_CANON_GETEVENT:           UInt16 = 0x9116
private let PTP_CMD_CANON_KEEPDEVICEON:       UInt16 = 0x911D
private let PTP_CMD_CANON_REQUESTPROPVAL:     UInt16 = 0x9127
private let PTP_CMD_CANON_SETOLCINFOGROUP:    UInt16 = 0x913D
private let PTP_CMD_CANON_GETVIEWFINDERDATA:  UInt16 = 0x9153
private let PTP_CMD_CANON_DOAF:               UInt16 = 0x9154
private let PTP_CMD_CANON_AF_CANCEL:          UInt16 = 0x9160

private let PTP_PROP_CANON_EVF_OUTPUTDEVICE:  UInt32 = 0xD1B0
private let PTP_PROP_CANON_EVF_MODE:          UInt32 = 0xD1B1

// Canon EOS UI property codes. Mirrors PtpCameraCanon.uiProperties from the
// original DAL plugin. We use these to seed property discovery via
// RequestPropertyValue rather than relying on the event queue alone — at
// least one Canon EOS body (Rebel T6i, pid=0x3272) USB-resets when sent
// GetEvent (0x9116) before any property is registered for change tracking.
/// Canon EOS UI properties, paired with the PTP DataType used to decode their
/// values. Canon
/// never advertises these properties via `GetDevicePropDesc(0x1014)`, so we
/// need to know each property's data type up front to parse the value bytes
/// out of `PropValueChanged` and the per-value slots out of `AvailListChanged`.
///
/// PTP data type codes: 2=U8, 3=I16, 4=U16, 5=I32, 6=U32.
private let canonUiProperties: [(id: UInt32, dataType: UInt16)] = [
    (0x5001, 6),    // Battery Level (standard PTP, U32 here for safety)
    (0xD101, 6),    // Aperture
    (0xD102, 6),    // Exposure Time (shutter)
    (0xD103, 6),    // ISO
    (0xD104, 5),    // Exposure Bias (signed)
    (0xD105, 6),    // Auto Exposure
    (0xD107, 6),    // Metering Mode
    (0xD108, 6),    // Focus Mode
    (0xD10A, 6),    // White Balance
    // WB fine-tune offsets (signed, neutral at 0; range ±9 stops on
    // most EOS bodies). Names match libgphoto2 PTP_DPC_CANON_EOS_*
    // codes — though Canon flips the "A" / "B" axis labels relative
    // to Nikon / Sony conventions:
    //   • 0xD10C "WhiteBalanceAdjustA" = amber-blue tune (A-B)
    //   • 0xD10D "WhiteBalanceAdjustB" = green-magenta tune (G-M)
    // The R7 reports these as not-writable while the body is in
    // Color-Temperature WB mode; they should unlock after the WB
    // mode picker switches the camera to e.g. Daylight or Auto.
    (0xD10C, 5),    // WB Adjust A (amber-blue, signed)
    (0xD10D, 5),    // WB Adjust B (green-magenta, signed)
    (0xD129, 6),    // Picture Style
    (0xD12C, 6),    // LV Eye Detect
    (0xD1B0, 6),    // EVF Output Device
    (0xD1B1, 6),    // EVF Mode
    (0xD1B2, 6),    // EVF Depth of Field Preview
    (0xD1B4, 6),    // EVF White Balance
    (0xD1B6, 6),    // EVF Color Temperature
    (0xD1B7, 6),    // EVF Exposure Preview
]
private let canonUiPropertyIds: [UInt32] = canonUiProperties.map { $0.id }
private let canonUiPropertyDataTypes: [UInt32: UInt16] =
    Dictionary(uniqueKeysWithValues: canonUiProperties.map { ($0.id, $0.dataType) })

private let PTP_EVENT_CANON_PROPVALCHANGED:   UInt32 = 0xC189
private let PTP_EVENT_CANON_AVAILLISTCHANGED: UInt32 = 0xC18A

/// Canon EOS body serial (printed-on-the-camera number). Unlike the PTP-standard
/// `DeviceInfo.SerialNumber` field (which Canon EOS bodies populate with an
/// internal 32-char device UUID), this property holds the actual body
/// serial. The camera does NOT push it via the OLC info group dump — we
/// must explicitly request it with `RequestPropertyValue` (0x9127).
private let PTP_PROP_CANON_EOS_SERIALNUMBER:  UInt32 = 0xD1AF

private enum CanonLvState { case off, waitingEvfMode, waitingOutputDevice, on }

// MARK: - Per-body live-view profile
//
// Canon EOS bodies fall into three live-view profiles. The mainline DSLRs we used to hardcode
// for (SetRemoteMode=1, EVFOutputDevice=2) work for everything from the 40D
// through the 5D Mark IV and 90D. But for EOS-M mirrorless and EOS-R the
// magic numbers differ:
//
//   .dslr        SetRemoteMode(1)    + EVFOutputDevice = 2 (PC)
//   .eosMOlder   SetRemoteMode(0x15) + EVFOutputDevice = 0x08 (M, M2, M3, M5,
//                                                              M6, M10, M100, M50)
//   .eosMNewer   SetRemoteMode(0x01) + EVFOutputDevice unset (M6-II, M50-II,
//                                                             R, RP, R2, R5,
//                                                             R6, …)
//
// We classify by USB PID. Anything we don't recognise as M-series / R-series
// falls through to `.dslr` — the historical default that's known to work for
// the bulk of the supported list.
private enum CanonLvProfile { case dslr, eosMOlder, eosMNewer, eosR }

private func canonLvProfile(forPid pid: UInt16) -> CanonLvProfile {
    switch pid {
    // Older EOS-M (mode 0x15 + EVF 0x08). M200 follows the same family.
    case 0x323D,  // M
         0x3273,  // M2
         0x3299,  // M3
         0x32A0,  // M10
         0x32BB,  // M5
         0x32C5,  // M6
         0x32D1,  // M100
         0x32D2,  // M50
         0x32EF:  // M200
        return .eosMOlder
    // Newer EOS-M (mode 0x01, skip EVF output device write).
    // These bodies bring up the EVF output path themselves during
    // SetRemoteMode(0x01) and reject an explicit EVFOutputDevice write.
    case 0x32E7,  // M6 Mark II
         0x32F9:  // M50 Mark II
        return .eosMNewer
    // EOS R mirrorless (mode 0x01, EVF output device = 2 like DSLR).
    // Without writing EVFOutputDevice the camera returns 0xA102
    // (EOS_NotReady) to every GetViewfinderData call. Confirmed on
    // R7 (pid=0x32F7).
    case 0x32DA,  // R
         0x32E2,  // RP
         0x32F4,  // R5
         0x32F5,  // R6
         0x32F7,  // R7
         0x32F8,  // R10
         0x32FC,  // R3
         0x3303,  // R5 C
         0x330B,  // R6 Mark II
         0x330C,  // R8
         0x330D,  // R50
         0x3312,  // R100
         0x3313,  // R1
         0x3314,  // R5 Mark II
         0x3320,  // R50 V
         0x3323:  // R6 Mark III
        return .eosR
    default:
        return .dslr
    }
}

// MARK: - UsbCanonCamera

final class UsbCanonCamera: UsbPtpCameraBase {

    init(transport: UsbPtpTransport) {
        super.init(transport: transport, logTag: "UsbCanonCamera")
        // Canon polls GetEvent for property changes; less frequent than Nikon/Sony
        // interrupt-IN poll since each call is a full PTP transaction.
        eventPollInterval = 15
    }

    // MARK: - Vendor connect

    /// Cached per-body live-view profile. Set once in performVendorConnect()
    /// so startLiveViewSession() doesn't have to re-classify on every cycle.
    private var lvProfile: CanonLvProfile = .dslr

    override func performVendorConnect() {
        parseDeviceInfo()  // populates supportedOps

        // Reset EVF to a known-off state at the START of every
        // session. The previous extension process may have been
        // SIGKILL'd mid-LV (macOS reload, crash, or our reinstall
        // path); without an explicit reset here the body comes
        // back to us with EVF still primed from before, and the
        // first `GetViewfinderData` we then issue returns
        // `0xA102 (EOS_NotReady)` for several seconds while the
        // camera tries to recycle stale internal buffers — long
        // enough for the CMIO client to give up.
        // Writing 0 to both is harmless when the body is already
        // off (returns 0x2001 either way); when it isn't, this is
        // the missing teardown step that lets the new LV start-up
        // run cleanly.
        _ = setPropertyEos(propId: PTP_PROP_CANON_EVF_OUTPUTDEVICE, value: 0)
        _ = setPropertyEos(propId: PTP_PROP_CANON_EVF_MODE, value: 0)

        // Classify the body and select the SetRemoteMode value. EOS-M and
        // newer mirrorless bodies reject SetRemoteMode(1) — they need 0x15
        // (older M) or 0x01 (newer M / R). Sending the wrong value puts the
        // camera in a half-initialised state where SetEventMode hangs and
        // live view never starts. See `canonLvProfile(forPid:)` for the
        // body-by-body classification.
        lvProfile = canonLvProfile(forPid: transport.productId)
        let remoteMode: UInt32 = {
            switch lvProfile {
            case .dslr:      return 0x01
            case .eosMOlder: return 0x15
            case .eosMNewer: return 0x01
            case .eosR:      return 0x01
            }
        }()
        if supportedOps.contains(PTP_CMD_CANON_SETREMOTEMODE) {
            _ = try? transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_CANON_SETREMOTEMODE, parameters: [remoteMode]))
            cameraLog.fault("SetRemoteMode(0x\(String(remoteMode, radix:16), privacy: .public)) profile=\(String(describing: self.lvProfile), privacy: .public)")
        }
        if supportedOps.contains(PTP_CMD_CANON_SETEVENTMODE) {
            _ = try? transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_CANON_SETEVENTMODE, parameters: [1]))
            cameraLog.fault("SetEventMode(1)")
        }
        // Canon EOS quirk:
        // before any GetEvent call, tell the camera which categories of state
        // ("OLC = On-screen / Live Camera info") to push into the event queue.
        // Without this, the EOS firmware's event queue is in an undefined
        // state and GetEvent can USB-reset the camera (observed on EOS 750D).
        // Bitmask 0x00001FFF requests all standard info groups.
        if supportedOps.contains(PTP_CMD_CANON_SETOLCINFOGROUP) {
            let rsp = sendCanonCommand(PTP_CMD_CANON_SETOLCINFOGROUP, params: [0x00001FFF])
            cameraLog.fault("SetRequestOLCInfoGroup(0x1FFF) → 0x\(String(rsp, radix:16), privacy: .public)")
        }
        // Explicitly request the body serial number. Canon doesn't include
        // it in the OLC info dump, so we must ask for it before it shows up
        // in the GetEvent stream as a PROPVALCHANGED block.
        if supportedOps.contains(PTP_CMD_CANON_REQUESTPROPVAL) {
            let rsp = sendCanonCommand(PTP_CMD_CANON_REQUESTPROPVAL,
                                       params: [PTP_PROP_CANON_EOS_SERIALNUMBER])
            cameraLog.fault("RequestPropertyValue(0xD1AF EOS_SerialNumber) → 0x\(String(rsp, radix:16), privacy: .public)")
        }
    }

    // MARK: - Property discovery

    /// Send a Canon command with the given parameters, returning the response
    /// code (0xFFFF on transport error).
    @discardableResult
    private func sendCanonCommand(_ code: UInt16, params: [UInt32] = []) -> UInt16 {
        guard let (_, rsp) = try? transport.sendPtpCommand(
            transport.buildCommand(code: code, parameters: params)) else {
            return 0xFFFF
        }
        return transport.responseCode(from: rsp)
    }

    override func discoverAllProperties() -> [UInt32: UsbCameraProperty] {
        // Probe each known UI property directly. The DAL plugin uses the same
        // strategy: standard PTP props (≤ 0x5xxx) via GetDevicePropDesc (0x1014)
        // and Canon vendor props (≥ 0xD000) via RequestPropertyValue (0x9127).
        //
        // Note: we deliberately do NOT call GetEvent (0x9116) during discovery.
        // At least one body (EOS 750D / Rebel T6i, pid=0x3272) USB-resets when
        // sent GetEvent against an empty event queue — the reset cascades into
        // an IOUSBHost teardown and the extension process dies. GetEvent is
        // only safe to call during the live-view loop after RequestPropertyValue
        // has primed the queue.
        cameraLog.fault("Canon discoverAllProperties: \(canonUiPropertyIds.count, privacy: .public) UI props")

        // Standard PTP props (battery / focal length / exposure program) come
        // back inline from GetDevicePropDesc.
        var stdGot = 0
        for propId in canonUiPropertyIds where propId < 0x9000 {
            if closing { break }
            if let prop = getDevicePropDesc(propId) {
                discoveredProperties[propId] = prop
                stdGot += 1
            }
        }

        // Canon vendor props (ISO, aperture, shutter, EVF state, etc.) come
        // back via the event queue. `SetRequestOLCInfoGroup(0x1fff)` in
        // performVendorConnect tells the firmware to include some state in
        // the queue, but older EOS bodies (Rebel T5i / 700D) don't emit the
        // photographic UI properties (ISO/shutter/aperture/WB) without an
        // explicit `RequestPropertyValue` per property.
        if supportedOps.contains(PTP_CMD_CANON_REQUESTPROPVAL) {
            for propId in canonUiPropertyIds where propId >= 0x9000 || propId >= 0xD000 {
                _ = sendCanonCommand(PTP_CMD_CANON_REQUESTPROPVAL, params: [propId])
            }
        }

        // Drain the event queue. Always loop a fixed number of times: the
        // count-based break we used to do misses AVAILLISTCHANGED (which
        // updates existing entries without changing the count) and the
        // SerialNumber string response (which we intercept and don't store
        // in `discoveredProperties`). Fixed 1 s drain is cheap.
        if supportedOps.contains(PTP_CMD_CANON_GETEVENT) {
            for i in 0..<10 {
                if closing { break }
                _ = pollGetEvent()
                Thread.sleep(forTimeInterval: 0.1)
                cameraLog.fault("Canon discovery GetEvent batch #\(i, privacy: .public) discovered=\(self.discoveredProperties.count, privacy: .public)")
            }
        }

        // Filter to only the UI properties we know how to format. The EOS
        // event queue dumps ~100 internal properties (lens info, focus boxes,
        // battery internals, etc.); publishing them all clutters the agent
        // menu with raw numeric items. Match the DAL plugin which only ever
        // surfaced the canonUiPropertyIds.
        var filtered = discoveredProperties.filter { canonUiPropertyDataTypes[$0.key] != nil }

        // T5i and similar older EOS bodies don't emit AVAILLISTCHANGED for
        // the photographic UI props (ISO/Shutter/Aperture/WB) — only for
        // internal config items. Without enum lists the agent menu can't
        // offer selectable values, so fall back to hardcoded ranges for the
        // props we know need them (decoding to friendly
        // labels happens in the agent's PropertyFormatter).
        // Synthesize enum lists ONLY for properties the camera didn't
        // already provide. The T5i emits AVAILLISTCHANGED with the real
        // camera-supported values for ISO/Shutter/Aperture/WB/etc., and
        // those are authoritative — overwriting them with our hardcoded
        // tables would offer the user codes the camera might reject.
        var synthCount = 0
        for propId in Array(filtered.keys) {
            guard let prop = filtered[propId] else { continue }
            if (prop.enumValues?.isEmpty ?? true), let synth = canonHardcodedEnum(propId: propId) {
                filtered[propId] = UsbCameraProperty(
                    propertyId: prop.propertyId, dataType: prop.dataType,
                    writable: true, value: prop.value, enumValues: synth,
                    rangeMin: nil, rangeMax: nil, rangeStep: nil)
                synthCount += 1
            }
            // Diagnostic: log each UI prop's value + enum count so we can
            // see whether the camera actually fed us the right values.
            if let p = filtered[propId] {
                let head = (p.enumValues ?? []).prefix(8)
                    .map { String(format: "0x%02x", $0.uint32Value) }.joined(separator: ",")
                cameraLog.fault("ui 0x\(String(propId, radix:16), privacy: .public) v=0x\(String(p.value.uint32Value, radix:16), privacy: .public) w=\(p.writable, privacy: .public) enum#=\(p.enumValues?.count ?? -1, privacy: .public) head=[\(head, privacy: .public)]")
            }
        }
        cameraLog.fault("Canon synthesized enums for \(synthCount, privacy: .public) props (camera didn't provide them)")

        let filteredIds = filtered.keys.sorted().map { String(format: "0x%04x", $0) }.joined(separator: ",")
        let missing = canonUiPropertyIds.filter { filtered[$0] == nil }
            .map { String(format: "0x%04x", $0) }.joined(separator: ",")
        cameraLog.fault("Canon discoverAllProperties: filtered=\(filtered.count, privacy: .public) of \(self.discoveredProperties.count, privacy: .public) total (std \(stdGot, privacy: .public))")
        cameraLog.fault("  got: \(filteredIds, privacy: .public)")
        cameraLog.fault("  missing: \(missing, privacy: .public)")
        discoveredProperties = filtered
        return discoveredProperties
    }

    /// Number of standard PTP props (< 0x9000) in our hardcoded list — used
    /// for diagnostic logging only.
    private var canonStdCount: Int {
        canonUiPropertyIds.lazy.filter { $0 < 0x9000 }.count
    }

    // MARK: - Live view session

    override func startLiveViewSession() -> Bool {
        // Now that SetRequestOLCInfoGroup has primed the event queue, we can
        // safely poll GetEvent while waiting for the EVF state transition.
        let modeRsp = setPropertyEos(propId: PTP_PROP_CANON_EVF_MODE, value: 1)
        guard modeRsp == PTP_RSP_OK else {
            cameraLog.fault("EVF_MODE=1 failed code=0x\(String(modeRsp, radix:16), privacy: .public) — aborting live view")
            liveViewStartError = "Canon refused EVF_MODE=1 (response code 0x\(String(modeRsp, radix: 16))). The camera may be in playback mode, recording video, or have a stuck shutter button."
            return false
        }

        // EVF output device value differs per body profile (see CanonLvProfile):
        //   .dslr        → 2 (PC display)
        //   .eosMOlder   → 0x08 (EOS-M specific)
        //   .eosMNewer   → skip the write entirely; the body brings up its
        //                  own output path during SetRemoteMode(0x01).
        //   .eosR        → 2 (PC display, same as DSLR). Without this the
        //                  R-series returns 0xA102 (EOS_NotReady) to every
        //                  subsequent GetViewfinderData. Verified on R7.
        let evfOutputValue: UInt32?
        switch lvProfile {
        case .dslr:      evfOutputValue = 2
        case .eosMOlder: evfOutputValue = 0x08
        case .eosMNewer: evfOutputValue = nil
        case .eosR:      evfOutputValue = 2
        }

        var lvState = CanonLvState.waitingEvfMode
        for _ in 0..<100 {
            if stopLv || closing { return false }
            Thread.sleep(forTimeInterval: 0.05)
            pollGetEvent { [self] propId, value in
                switch (propId, lvState) {
                case (PTP_PROP_CANON_EVF_MODE, .waitingEvfMode) where value == 1:
                    if let v = evfOutputValue {
                        lvState = .waitingOutputDevice
                        setPropertyEos(propId: PTP_PROP_CANON_EVF_OUTPUTDEVICE, value: v)
                    } else {
                        // Newer M / R bodies: nothing more to do — declare ready.
                        lvState = .on
                    }
                case (PTP_PROP_CANON_EVF_OUTPUTDEVICE, .waitingOutputDevice):
                    // Older DSLRs report `value & 0x02 != 0` (PC bit) when ready;
                    // EOS-M bodies report `value & 0x08 != 0` for their own bit.
                    // Either way the value should reflect the bit we just set.
                    if let v = evfOutputValue, (value & v) != 0 {
                        lvState = .on
                    }
                default:
                    break
                }
            }
            if lvState == .on { break }
        }
        if lvState != .on {
            cameraLog.fault("EVF did not become ready — aborting live view")
            liveViewStartError = "Canon EVF didn't become ready within 5 seconds. Check that the camera is on, not in playback mode, and that the lens cap / mirror aren't blocking the sensor."
            return false
        }
        cameraLog.fault("EVF on")
        return true
    }

    override func stopLiveViewSession() -> Bool {
        // Reset the output device to 0 to tell the camera we're done. Newer
        // M/R bodies didn't have it written in the first place, but writing 0
        // is harmless (camera silently accepts it).
        // `setPropertyEos` returns the PTP response code, or 0
        // on a USB transport failure. Map "got any response
        // code" to success — any non-zero is a successful
        // round-trip even if the camera complained (e.g.
        // "wasn't in LV"); only 0 (transport failure) signals
        // the base class to retry.
        let code = setPropertyEos(propId: PTP_PROP_CANON_EVF_OUTPUTDEVICE, value: 0)
        return code != 0
    }

    /// Canon-specific teardown before `CLOSE_SESSION`. Without this the
    /// camera carries the previous extension's EVF / RemoteMode state
    /// across the new session — manifests as the next live-view start
    /// returning `0xA102 (EOS_NotReady)` and the LV loop never
    /// producing frames until the camera is power-cycled. Resetting
    /// `EVFOutputDevice=0` then `EVFMode=0` cleanly drops the
    /// live-view stream so the next OpenSession + SetRemoteMode(1)
    /// starts from a known state.
    override func performVendorCleanup() {
        _ = setPropertyEos(propId: PTP_PROP_CANON_EVF_OUTPUTDEVICE, value: 0)
        _ = setPropertyEos(propId: PTP_PROP_CANON_EVF_MODE, value: 0)
    }

    // MARK: - Frame fetch

    /// Diagnostic counter — log details for the first few frame fetches and
    /// every periodic interval after, but not every frame (would flood logs).
    private var frameFetchAttempts: Int = 0
    /// Soft EOS_NotReady response code Canon returns for the first
    /// few GetViewfinderData calls after EVF_OUTPUTDEVICE writes —
    /// the body still needs ~0.5–1.0 s to spool up the LV pipeline
    /// after our setup acks `OK`. Treated as a transient retryable
    /// state inside `fetchOneFrame` so the LV loop sees a steady
    /// stream of frames once the body is ready.
    private static let canonRspEosNotReady: UInt16 = 0xA102

    override func fetchOneFrame() throws -> Data? {
        frameFetchAttempts += 1
        let verbose = frameFetchAttempts <= 5 || frameFetchAttempts % 60 == 0
        let cmd = transport.buildCommand(
            code: PTP_CMD_CANON_GETVIEWFINDERDATA, parameters: [0x00100000])

        // EOS_NotReady (0xA102) is normal during LV start-up — the
        // body takes a moment to fill its first viewfinder buffer
        // after EVF_OUTPUTDEVICE goes through. Spin briefly inside
        // this call rather than returning nil up to the LV loop:
        // every LV-loop iteration drains pendingOps and sleeps a
        // frame interval (~33 ms), so a bounced retry over there
        // would let a not-yet-ready body keep its first useful
        // frame waiting for ~100 ms, by which point a CMIO client
        // may have already disconnected (some apps give up after
        // 1–2 s of no frames). Tight spin caps at ~600 ms of
        // retries — beyond that the body is genuinely stalled and
        // we bubble the failure up so the loop's normal pacing
        // takes over.
        let notReadyDeadline = Date().addingTimeInterval(0.6)
        var notReadyAttempts = 0

        while true {
            let inData: Data?
            let rsp: Data
            do {
                (inData, rsp) = try transport.sendPtpCommand(cmd)
            } catch {
                if verbose {
                    cameraLog.fault("GetViewfinderData attempt #\(self.frameFetchAttempts, privacy: .public) threw: \(String(describing: error), privacy: .public)")
                }
                throw error
            }
            let code = transport.responseCode(from: rsp)
            if code == Self.canonRspEosNotReady,
               Date() < notReadyDeadline, !stopLv, !closing {
                notReadyAttempts += 1
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            if notReadyAttempts > 0 && verbose {
                cameraLog.fault("GetViewfinderData attempt #\(self.frameFetchAttempts, privacy: .public) — EOS_NotReady cleared after \(notReadyAttempts, privacy: .public) inner retries, rsp=0x\(String(code, radix:16), privacy: .public)")
            }
            guard code == PTP_RSP_OK else {
                if verbose {
                    cameraLog.fault("GetViewfinderData attempt #\(self.frameFetchAttempts, privacy: .public) rsp=0x\(String(code, radix:16), privacy: .public) inLen=\(inData?.count ?? -1, privacy: .public)")
                }
                return nil
            }
            guard let data = inData else {
                if verbose {
                    cameraLog.fault("GetViewfinderData attempt #\(self.frameFetchAttempts, privacy: .public) OK but inData=nil")
                }
                return nil
            }
            let jpeg = extractJpegFromLiveViewData(data)
            if jpeg == nil && verbose {
                let headHex = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                cameraLog.fault("GetViewfinderData attempt #\(self.frameFetchAttempts, privacy: .public) OK but no SOI/EOI in \(data.count, privacy: .public)B head=[\(headHex, privacy: .public)]")
            }
            return jpeg
        }
    }

    // MARK: - Autofocus

    /// Canon EOS AF trigger — the "press" half of a press-and-hold
    /// pair. Sends `AfCancel` (to clear any stale half-press) then
    /// `DoAf` (to start the AF motor) and returns immediately, so
    /// the camera holds focus until the matching
    /// `performAutofocusCancel` arrives.
    /// The release happens on mouseUp from the HUD's AF chip; the
    /// agent menu's single-click action sends a delayed cancel from
    /// its own side so the menu path still produces a complete
    /// "tap to autofocus" cycle.
    override func performAutofocus() {
        guard sessionOpen else { return }
        if supportedOps.contains(PTP_CMD_CANON_AF_CANCEL) {
            let rsp = sendCanonCommand(PTP_CMD_CANON_AF_CANCEL)
            cameraLog.fault("AfCancel (pre) → 0x\(String(rsp, radix:16), privacy: .public)")
        }
        if supportedOps.contains(PTP_CMD_CANON_DOAF) {
            let rsp = sendCanonCommand(PTP_CMD_CANON_DOAF)
            cameraLog.fault("DoAf → 0x\(String(rsp, radix:16), privacy: .public)")
        }
    }

    /// Canon EOS AF release — the "release" half of a press-and-hold
    /// pair. Sends `AfCancel` (0x9160) to release the shutter
    /// half-press state the body fell into after `DoAf`. Without
    /// this release every subsequent `SetPropValueEx` returns
    /// `0x2019 DeviceBusy` and LV won't cleanly restart.
    override func performAutofocusCancel() {
        guard sessionOpen,
              supportedOps.contains(PTP_CMD_CANON_AF_CANCEL) else { return }
        let rsp = sendCanonCommand(PTP_CMD_CANON_AF_CANCEL)
        cameraLog.fault("AfCancel (release) → 0x\(String(rsp, radix:16), privacy: .public)")
    }

    // MARK: - Event polling

    /// Counter so we can run `KeepDeviceOn` (0x911D) on a slower
    /// cadence than the event poll. The LV loop calls `pollEvents`
    /// once per `eventPollInterval` frames (every ~0.5 s at 30 fps);
    /// we want KeepDeviceOn roughly every 5 s.
    private var keepAliveCounter: Int = 0

    override func pollEvents() {
        // Safe to call GetEvent now that performVendorConnect issued
        // SetRequestOLCInfoGroup to prep the camera's event queue.
        pollGetEvent()

        // EOS bodies soft-lock the SetPropValueEx code path after
        // ~30 s of tethered live view without a heartbeat —
        // SetPropValueEx then returns 0x2019 (DeviceBusy) on every
        // call while LV/AF/GetEvent keep working. libgphoto2 ships
        // a periodic `KeepDeviceOn` (0x911D) to prevent this; we
        // do the same here, roughly every 5 s of LV runtime.
        keepAliveCounter += 1
        if keepAliveCounter >= 10,
           supportedOps.contains(PTP_CMD_CANON_KEEPDEVICEON) {
            keepAliveCounter = 0
            _ = sendCanonCommand(PTP_CMD_CANON_KEEPDEVICEON)
        }
    }

    @discardableResult
    private func pollGetEvent(onPropertyChanged: ((UInt32, UInt32) -> Void)? = nil) -> Bool {
        guard sessionOpen else {
            cameraLog.fault("pollGetEvent: session not open")
            return false
        }
        guard supportedOps.contains(PTP_CMD_CANON_GETEVENT) else {
            cameraLog.fault("pollGetEvent: GetEvent (0x9116) not in supportedOps")
            return false
        }
        do {
            let (inData, rsp) = try transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_CANON_GETEVENT))
            let code = transport.responseCode(from: rsp)
            guard code == PTP_RSP_OK, let data = inData else {
                cameraLog.fault("pollGetEvent: rsp=0x\(String(code, radix:16), privacy: .public) len=\(inData?.count ?? -1, privacy: .public)")
                return false
            }
            parseCanonEventResponse(data, onPropertyChanged: onPropertyChanged)
            return true
        } catch {
            cameraLog.fault("pollGetEvent: threw \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func parseCanonEventResponse(_ data: Data, onPropertyChanged: ((UInt32, UInt32) -> Void)?) {
        var offset = 0
        while offset + 8 <= data.count {
            let len  = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset,     as: UInt32.self) })
            let type = data.withUnsafeBytes     { $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self) }
            guard len >= 8, offset + len <= data.count else { break }
            let blockData = data.subdata(in: (offset + 8) ..< (offset + len))
            parseCanonEventBlock(blockData, type: type, onPropertyChanged: onPropertyChanged)
            offset += len
        }
    }

    private func parseCanonEventBlock(_ blockData: Data, type: UInt32, onPropertyChanged: ((UInt32, UInt32) -> Void)?) {
        switch type {
        case PTP_EVENT_CANON_PROPVALCHANGED:
            guard blockData.count >= 4 else { return }
            let propId = blockData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
            let valueData = blockData.subdata(in: 4 ..< blockData.count)

            // EOS_SerialNumber (0xD1AF) is a PTP string (UCS-2 LE, length-
            // prefixed). It's not a UI item — capture it into `deviceSerial`
            // so the agent shows it instead of the 32-char UUID from
            // DeviceInfo.SerialNumber.
            if propId == PTP_PROP_CANON_EOS_SERIALNUMBER {
                let parser = PtpPropParser(valueData)
                if let s = parser.readPtpString(), !s.isEmpty {
                    deviceSerial = s
                    cameraLog.fault("EOS_SerialNumber = \(s, privacy: .public)")
                }
                return
            }

            let (value, _) = readEosValue(from: valueData, offset: 0, rawType: eosRawType(forPropId: propId))
            guard let value = value else { return }

            let existing = discoveredProperties[propId]
            let dataType = existing?.dataType ?? UInt16(eosRawType(forPropId: propId))
            let updated = UsbCameraProperty(
                propertyId: propId, dataType: dataType,
                writable: existing?.writable ?? false,
                value: value,
                enumValues: existing?.enumValues,
                rangeMin: existing?.rangeMin,
                rangeMax: existing?.rangeMax,
                rangeStep: existing?.rangeStep)
            discoveredProperties[propId] = updated
            onPropertyChanged?(propId, value.uint32Value)

        case PTP_EVENT_CANON_AVAILLISTCHANGED:
            // EOS AvailListChanged block layout
            // PTP_EC_CANON_EOS_AvailListChanged):
            //   [0..3]  propId  (uint32)
            //   [4..7]  dpdType (uint32)  — should be 3 for enum form
            //   [8..11] count   (uint32)
            //   [12..]  values, each occupying 4 bytes regardless of the
            //           property's actual data type (UInt8/UInt16/UInt32).
            // The value's true data type comes from our hardcoded
            // canonUiPropertyDataTypes table; the EOS firmware does NOT
            // advertise it via this event.
            guard blockData.count >= 8 else { return }
            let propId    = blockData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
            let dpdType   = blockData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
            guard dpdType == 3 else { return }   // only "enum form" supported
            guard let dataType = canonUiPropertyDataTypes[propId] else { return }
            let rawType = UInt8(dataType)

            if blockData.count > 8 {
                let arrayData = blockData.subdata(in: 8 ..< blockData.count)
                let values = readEosArray(from: arrayData, rawType: rawType)
                let existing = discoveredProperties[propId]
                let updated = UsbCameraProperty(
                    propertyId: propId, dataType: dataType,
                    writable: !values.isEmpty,
                    value: existing?.value ?? NSNumber(value: 0),
                    enumValues: values.isEmpty ? nil : values,
                    rangeMin: nil, rangeMax: nil, rangeStep: nil)
                discoveredProperties[propId] = updated
            }

        default:
            break
        }
    }

    // MARK: - EOS data helpers

    private func eosRawType(forPropId propId: UInt32) -> UInt8 {
        // Prefer the hardcoded data type for known UI properties (Canon
        // never advertises types via PTP, so we have to know them up front).
        // Fall back to whatever was previously discovered, then UInt32.
        if let dt = canonUiPropertyDataTypes[propId] { return UInt8(dt) }
        return discoveredProperties[propId].map { UInt8($0.dataType & 0xFF) } ?? 6
    }

    private func readEosValue(from data: Data, offset: Int, rawType: UInt8) -> (NSNumber?, Int) {
        guard offset + 4 <= data.count else { return (nil, 0) }
        switch rawType {
        case 1: return (NSNumber(value: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int8.self) }),  4)
        case 2: return (NSNumber(value: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt8.self) }), 4)
        case 3: return (NSNumber(value: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int16.self) }), 4)
        case 4: return (NSNumber(value: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }),4)
        case 5: return (NSNumber(value: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }), 4)
        case 6: return (NSNumber(value: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }),4)
        default: return (nil, 4)
        }
    }

    private func readEosArray(from data: Data, rawType: UInt8) -> [NSNumber] {
        guard data.count >= 4 else { return [] }
        let count = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) })
        var result: [NSNumber] = []
        var offset = 4
        for _ in 0..<count {
            let (val, bytesRead) = readEosValue(from: data, offset: offset, rawType: rawType)
            if let val = val { result.append(val) }
            offset += max(bytesRead, 4)
            if offset > data.count { break }
        }
        return result
    }

    // MARK: - Property set

    override func performPropertySet(_ pending: PendingSet) {
        if pending.propId < 0x9000 {
            sendStandardSetPropVal(propId: pending.propId, value: pending.value, dataType: pending.dataType)
        } else {
            let rsp = setPropertyEos(propId: pending.propId, value: pending.value)
            // WB-mode dual-write: on R-series bodies the "EVF White
            // Balance" mode slot at 0xD1B4 returns 0x2019 (DeviceBusy)
            // when the still WB (0xD10A) is in Color Temperature mode
            // — the body refuses to change the LV-WB mode while
            // 0xD10A is driving it from a K value. Conversely, when
            // the user picks a non-CT mode the still-WB slot needs to
            // be moved out of Color-Temp too, or it will keep
            // overriding the LV. So write both in lockstep whenever
            // either takes a mode-code value (≤ 0xFF).
            if (pending.propId == 0xD1B4 || pending.propId == 0xD10A)
               && pending.value <= 0xFF {
                let mirrorId: UInt32 = pending.propId == 0xD1B4 ? 0xD10A : 0xD1B4
                let mirrorRsp = setPropertyEos(propId: mirrorId, value: pending.value)
                cameraLog.fault("WB mirror SET 0x\(String(mirrorId, radix:16), privacy: .public)=\(pending.value, privacy: .public) → 0x\(String(mirrorRsp, radix:16), privacy: .public) (primary rsp=0x\(String(rsp, radix:16), privacy: .public))")
            }
        }
        // Canon EOS doesn't issue a PROPVALCHANGED event automatically after a
        // successful SetDevicePropValueEx — we have to ask for it. Drain the
        // event queue once so any confirmation/rejection lands in our parser
        // (which updates discoveredProperties + publishes back to the agent).
        // This is the missing step that makes a 0x2001 ACK actually visible
        // as a value change in the menu after the user clicks.
        if pending.propId >= 0x9000 {
            // re-request the property to force the
            // camera to emit a fresh PROPVALCHANGED with the new value.
            if supportedOps.contains(PTP_CMD_CANON_REQUESTPROPVAL) {
                _ = sendCanonCommand(PTP_CMD_CANON_REQUESTPROPVAL, params: [pending.propId])
            }
            // Then drain — events arrive in the next GetEvent batch.
            _ = pollGetEvent { [self] propId, value in
                if propId == pending.propId {
                    cameraLog.fault("post-SET event 0x\(String(propId, radix:16), privacy: .public) = 0x\(String(value, radix:16), privacy: .public) (asked for 0x\(String(pending.value, radix:16), privacy: .public))")
                }
            }
            // Republish current value to the agent so the menu reflects
            // whatever the camera actually has now (which may differ from
            // what we asked for if the camera silently substituted).
            if let prop = discoveredProperties[pending.propId] {
                onPropertiesDiscovered?([pending.propId: prop])
            }
        } else if let updated = getDevicePropDesc(pending.propId) {
            discoveredProperties[pending.propId] = updated
            onPropertiesDiscovered?([pending.propId: updated])
        }
    }

    @discardableResult
    private func setPropertyEos(propId: UInt32, value: UInt32) -> UInt16 {
        var outData = Data()
        outData.appendLE(UInt32(12))  // block: [len:4][propId:4][value:4]
        outData.appendLE(propId)
        outData.appendLE(value)
        let cmd = transport.buildCommand(code: PTP_CMD_CANON_SETPROPVAL_EX)
        guard let (_, rsp) = try? transport.sendPtpCommand(cmd, outData: outData) else {
            cameraLog.fault("setPropertyEos 0x\(String(propId, radix:16), privacy: .public)=\(value, privacy: .public) — transport error")
            return 0
        }
        let code = transport.responseCode(from: rsp)
        cameraLog.fault("setPropertyEos 0x\(String(propId, radix:16), privacy: .public)=\(value, privacy: .public) → 0x\(String(code, radix:16), privacy: .public)")
        return code
    }
}

// MARK: - Hardcoded Canon EOS enum lists
//
// Older EOS bodies (700D/T5i etc.) don't emit AVAILLISTCHANGED for the
// photographic UI properties. The agent's
// PropertyFormatter handles the code→label mapping for display.
private let canonIsoCodes: [UInt32] = [
    0x0048, 0x004b, 0x004d, 0x0050, 0x0053, 0x0055, 0x0058, 0x005b, 0x005d,
    0x0060, 0x0063, 0x0065, 0x0068, 0x006b, 0x006d, 0x0070, 0x0073, 0x0075,
    0x0078, 0x007b, 0x007d, 0x0080,
]
private let canonApertureCodes: [UInt32] = [
    0x10, 0x13, 0x14, 0x15, 0x18, 0x1b, 0x1c, 0x1d, 0x20, 0x23, 0x24, 0x25,
    0x28, 0x2b, 0x2c, 0x2d, 0x30, 0x33, 0x34, 0x35, 0x38, 0x3b, 0x3c, 0x3d,
    0x40, 0x43, 0x44, 0x45, 0x48, 0x4b, 0x4c, 0x4d, 0x50,
]
private let canonShutterCodes: [UInt32] = [
    0x10, 0x18, 0x20, 0x28, 0x30, 0x38, 0x40, 0x48, 0x50, 0x58, 0x60, 0x68,
    0x70, 0x78, 0x80, 0x88, 0x90, 0x98, 0xa0,
]
private let canonWhiteBalanceCodes: [UInt32] = [0, 1, 2, 3, 4, 5, 6, 8, 9]
private let canonMeteringModeCodes: [UInt32] = [0, 1, 3, 4]
private let canonFocusModeCodes: [UInt32]    = [0, 1, 2, 3]

private func canonHardcodedEnum(propId: UInt32) -> [NSNumber]? {
    switch propId {
    case 0xD101: return canonApertureCodes.map     { NSNumber(value: $0) }
    case 0xD102: return canonShutterCodes.map      { NSNumber(value: $0) }
    case 0xD103: return canonIsoCodes.map          { NSNumber(value: $0) }
    case 0xD107: return canonMeteringModeCodes.map { NSNumber(value: $0) }
    case 0xD108: return canonFocusModeCodes.map    { NSNumber(value: $0) }
    case 0xD10A: return canonWhiteBalanceCodes.map { NSNumber(value: $0) }
    default: return nil
    }
}

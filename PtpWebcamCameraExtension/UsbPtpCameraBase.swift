// UsbPtpCameraBase.swift
// Shared base class for USB PTP camera implementations.
//
// Owns the dispatch queue, lifecycle state, pending-sets queue,
// the live-view frame loop (pacing + autoreleasepool + error handling),
// and the standard OPEN_SESSION / GetDeviceInfo / GetDevicePropDesc / SetPropVal logic.
//
// Vendor subclasses override the hook methods below to add their specific
// handshake, property discovery, frame fetch, event polling, and cleanup.

import Foundation
import os.log

// MARK: - Standard PTP constants shared by all vendors
//
// Every code defined by the PTP 1.1 spec lives here — vendor extensions
// (0x90xx, 0x91xx, 0xD1xx etc.) stay in their per-vendor files. The intent
// is that when a vendor handshake reaches for a standard opcode like
// SendObjectInfo (0x100C) or GetObject (0x1009), it picks it up from this
// block rather than redeclaring it as a `private let`.

// Operations (PTP_OC_*)
let PTP_CMD_GETDEVICEINFO:    UInt16 = 0x1001
let PTP_CMD_OPENSESSION:      UInt16 = 0x1002
let PTP_CMD_CLOSESESSION:     UInt16 = 0x1003
let PTP_CMD_GETSTORAGEIDS:    UInt16 = 0x1004
let PTP_CMD_GETSTORAGEINFO:   UInt16 = 0x1005
let PTP_CMD_GETNUMOBJECTS:    UInt16 = 0x1006
let PTP_CMD_GETOBJECTHANDLES: UInt16 = 0x1007
let PTP_CMD_GETOBJECTINFO:    UInt16 = 0x1008
let PTP_CMD_GETOBJECT:        UInt16 = 0x1009
let PTP_CMD_GETTHUMB:         UInt16 = 0x100A
let PTP_CMD_DELETEOBJECT:     UInt16 = 0x100B
let PTP_CMD_SENDOBJECTINFO:   UInt16 = 0x100C
let PTP_CMD_SENDOBJECT:       UInt16 = 0x100D
let PTP_CMD_INITIATECAPTURE:  UInt16 = 0x100E
let PTP_CMD_RESETDEVICE:      UInt16 = 0x1010
let PTP_CMD_INITIATEOPENCAPTURE: UInt16 = 0x101C
let PTP_CMD_GETPROPDESC:      UInt16 = 0x1014
let PTP_CMD_GETPROPVAL:       UInt16 = 0x1015
let PTP_CMD_SETPROPVAL:       UInt16 = 0x1016

// Response codes (PTP_RC_*)
let PTP_RSP_OK:                  UInt16 = 0x2001
let PTP_RSP_INVALIDOBJECTHANDLE: UInt16 = 0x2009
let PTP_RSP_DEVICEBUSY:          UInt16 = 0x2019
let PTP_RSP_SESSIONALREADY:      UInt16 = 0x201E
let PTP_RSP_ACCESSDENIED:        UInt16 = 0x202A

// Events (PTP_EC_*)
let PTP_EVENT_CANCELTRANSACTION:     UInt16 = 0x4001
let PTP_EVENT_OBJECTADDED:           UInt16 = 0x4002
let PTP_EVENT_OBJECTREMOVED:         UInt16 = 0x4003
let PTP_EVENT_STOREADDED:            UInt16 = 0x4004
let PTP_EVENT_STOREREMOVED:          UInt16 = 0x4005
let PTP_EVENT_DEVICEPROPCHANGED:     UInt16 = 0x4006
let PTP_EVENT_OBJECTINFOCHANGED:     UInt16 = 0x4007
let PTP_EVENT_DEVICEINFOCHANGED:     UInt16 = 0x4008
let PTP_EVENT_REQUESTOBJECTTRANSFER: UInt16 = 0x4009

// Object format codes (PTP_OFC_*) — only the ones we currently produce.
let PTP_OFC_SCRIPT:           UInt16 = 0x3002

// Standard PTP device properties (PTP_DPC_*). 0x5xxx range. Vendor
// extension properties (0xD0xx, 0xD1xx, …) stay in their vendor files.
let PTP_PROP_BATTERYLEVEL:        UInt16 = 0x5001
let PTP_PROP_FUNCTIONALMODE:      UInt16 = 0x5002
let PTP_PROP_IMAGESIZE:           UInt16 = 0x5003
let PTP_PROP_COMPRESSIONSETTING:  UInt16 = 0x5004
let PTP_PROP_WHITEBALANCE:        UInt16 = 0x5005
let PTP_PROP_RGBGAIN:             UInt16 = 0x5006
let PTP_PROP_FNUMBER:             UInt16 = 0x5007
let PTP_PROP_FOCALLENGTH:         UInt16 = 0x5008
let PTP_PROP_FOCUSDISTANCE:       UInt16 = 0x5009
let PTP_PROP_FOCUSMODE:           UInt16 = 0x500A
let PTP_PROP_EXPOSUREMETERINGMODE: UInt16 = 0x500B
let PTP_PROP_FLASHMODE:           UInt16 = 0x500C
let PTP_PROP_EXPOSURETIME:        UInt16 = 0x500D
let PTP_PROP_EXPOSUREPROGRAMMODE: UInt16 = 0x500E
let PTP_PROP_EXPOSUREINDEX:       UInt16 = 0x500F  // ISO
let PTP_PROP_EXPOSUREBIAS:        UInt16 = 0x5010
let PTP_PROP_DATETIME:            UInt16 = 0x5011
let PTP_PROP_CAPTUREDELAY:        UInt16 = 0x5012
let PTP_PROP_STILLCAPTUREMODE:    UInt16 = 0x5013
let PTP_PROP_CONTRAST:            UInt16 = 0x5014
let PTP_PROP_SHARPNESS:           UInt16 = 0x5015
let PTP_PROP_DIGITALZOOM:         UInt16 = 0x5016
let PTP_PROP_EFFECTMODE:          UInt16 = 0x5017
let PTP_PROP_BURSTNUMBER:         UInt16 = 0x5018
let PTP_PROP_BURSTINTERVAL:       UInt16 = 0x5019
let PTP_PROP_TIMELAPSENUMBER:     UInt16 = 0x501A
let PTP_PROP_TIMELAPSEINTERVAL:   UInt16 = 0x501B
let PTP_PROP_FOCUSMETERINGMODE:   UInt16 = 0x501C
let PTP_PROP_UPLOADURL:           UInt16 = 0x501D
let PTP_PROP_ARTIST:              UInt16 = 0x501E
let PTP_PROP_COPYRIGHTINFO:       UInt16 = 0x501F

// MARK: - UsbPtpCameraBase

class UsbPtpCameraBase: UsbCameraProtocol {

    let transport: UsbPtpTransport
    let logTag: String
    let cameraLog: Logger
    let queue: DispatchQueue

    // Lifecycle flags. Plain Bools — single-bit monotonic writes from main,
    // best-effort reads from the camera queue. A stale read just delays loop
    // exit by at most one frame interval.
    var stopLv      = false
    var closing     = false
    /// Set by `handleLiveViewTransportError` when it observes
    /// `kIOUSBPipeStalled`. Read at the top of `runLiveViewPhase`
    /// to decide whether to issue `transport.clearStalls()` before
    /// the vendor's STARTLIVEVIEW. Gated because
    /// `CLEAR_FEATURE(ENDPOINT_HALT)` against a non-halted Nikon
    /// D800 endpoint puts the body's PTP firmware into an
    /// error-recovery state (project memory: prior testing during
    /// the IOKit-USB migration).
    var liveViewNeedsStallRecovery: Bool = false
    var sessionOpen = false

    /// Supported PTP operation codes parsed from GetDeviceInfo.
    var supportedOps: Set<UInt16> = []

    /// Discovered properties — populated by `discoverAllProperties` and `pollEvents`.
    var discoveredProperties: [UInt32: UsbCameraProperty] = [:]

    struct PendingSet {
        let propId: UInt32
        let value: UInt32
        let dataType: UInt16
    }

    /// One unit of deferred work to be carried out on the camera queue.
    /// Keeping `setProperty` and `autofocus` as labelled cases — rather than
    /// flattening them into an opaque flags struct — means readers and future
    /// vendors can see at a glance what kinds of operations the base class
    /// schedules between live-view frames.
    enum PendingOp {
        case setProperty(PendingSet)
        case autofocus
        case autofocusCancel
    }
    private var pendingOps: [PendingOp] = []
    private let pendingLock = NSLock()

    var onJpegFrame: ((Data) -> Void)?
    var onPropertiesDiscovered: (([UInt32: UsbCameraProperty]) -> Void)?
    /// Fired when `startLiveViewSession()` returns false. The string is a
    /// short, user-facing explanation that the extension forwards to the
    /// agent so it can put up an NSAlert. Vendor subclasses set
    /// `liveViewStartError` before returning false; the base reads it here
    /// and falls back to a generic message if nothing was set.
    var onLiveViewStartFailed: ((String) -> Void)?

    /// Set by a vendor's `startLiveViewSession` immediately before it
    /// returns false. The base class drains and clears this in
    /// `runLiveViewPhase` to fire `onLiveViewStartFailed`.
    var liveViewStartError: String?

    // MARK: - Tunables (override in subclass init)

    /// Settle delay before the first OPEN_SESSION attempt.
    /// Nikon uses ~1.0s, Canon/Sony 0.5s.
    var sessionOpenSettleSeconds: TimeInterval = 0.5

    /// Target frame interval. 1/30s for all current vendors.
    var frameInterval: TimeInterval = 1.0 / 30.0

    /// Event polling cadence: poll every N frames inside the LV loop.
    var eventPollInterval: Int = 5

    /// Whether to call `transport.clearStalls()` between OPEN_SESSION retry attempts.
    /// Helps Nikon/Canon recover from halted endpoints; Sony's PTP firmware
    /// reacts badly to CLEAR_FEATURE on idle endpoints and can drop the session.
    var clearStallsOnSessionRetry: Bool = true

    // MARK: - Init

    init(transport: UsbPtpTransport, logTag: String) {
        self.transport = transport
        self.logTag = logTag
        self.cameraLog = Logger(subsystem: "org.ptpwebcam.PtpWebcamApp.CameraExtension", category: logTag)
        self.queue = DispatchQueue(label: "org.ptpwebcam.\(logTag.lowercased())", qos: .userInteractive)
        cameraLog.fault("init vid=0x\(String(transport.vendorId, radix:16), privacy: .public) pid=0x\(String(transport.productId, radix:16), privacy: .public) name=\(transport.deviceName, privacy: .public)")
    }

    // MARK: - UsbCameraProtocol (final — subclasses customize via hooks)

    final func openSessionAndDiscover() {
        queue.async { [weak self] in self?.runOpenSessionPhase() }
    }

    /// True once `startLiveView()` has spun up the LV phase on the camera
    /// queue and not yet observed `stopLv`. We need this to distinguish
    /// "claimed but idle" from "claimed and currently streaming" when the app
    /// asks for a PTP dump — idle claimed cameras can be dumped from
    /// in-memory state without touching the USB bus.
    private(set) var liveViewRunning: Bool = false

    final func startLiveView() {
        guard !closing else { return }
        stopLv = false
        liveViewRunning = true
        queue.async { [weak self] in
            self?.runLiveViewPhase()
            self?.liveViewRunning = false
        }
    }

    final func stopLiveView() {
        stopLv = true
        // `liveViewRunning` is cleared by the queue closure above once the
        // LV loop unwinds. Setting it eagerly here would race with a fast
        // dump that arrives while the loop is still tearing down.
    }

    final func close() {
        stopLv  = true
        closing = true
        queue.async { [weak self] in self?.runCleanUpPhase() }
    }

    /// Entry point for autofocus. Enqueues an `.autofocus` op (collapsing
    /// successive rapid clicks into a single trigger) and kicks the camera
    /// queue — if the LV loop is running, the op gets picked up by
    /// `drainPendingOps` on the next iteration; otherwise the queued closure
    /// handles it immediately.
    final func triggerAutofocus() {
        pendingLock.lock()
        let alreadyQueued = pendingOps.contains { if case .autofocus = $0 { return true } else { return false } }
        if !alreadyQueued { pendingOps.append(.autofocus) }
        pendingLock.unlock()
        queue.async { [weak self] in self?.drainPendingOps() }
    }

    /// Companion to `triggerAutofocus`. Releases any "shutter
    /// half-press" / focus-hold state the body is in after a
    /// previous `triggerAutofocus`. The HUD's AF chip uses these
    /// as a press-down / release pair so the body holds focus
    /// while the user keeps the chip pressed and releases as soon
    /// as they let go — same behaviour as a half-press on the
    /// camera's shutter button. Vendors that don't have a separate
    /// cancel command default to a no-op.
    final func cancelAutofocus() {
        pendingLock.lock()
        let alreadyQueued = pendingOps.contains { if case .autofocusCancel = $0 { return true } else { return false } }
        if !alreadyQueued { pendingOps.append(.autofocusCancel) }
        pendingLock.unlock()
        queue.async { [weak self] in self?.drainPendingOps() }
    }

    /// Vendor-specific autofocus trigger. Override per subclass.
    func performAutofocus() { }
    /// Vendor-specific autofocus cancel. Default: no-op. Canon
    /// overrides to send `AfCancel (0x9160)`, which releases the
    /// shutter half-press state the body falls into after `DoAf` —
    /// without that release every subsequent `SetPropValueEx` (and
    /// LV restart) gets locked out with `0x2019 DeviceBusy`.
    func performAutofocusCancel() { }

    final func setProperty(propId: UInt32, value: UInt32, dataType: UInt16) {
        pendingLock.lock()
        pendingOps.append(.setProperty(PendingSet(propId: propId, value: value, dataType: dataType)))
        pendingLock.unlock()
        // If the live view loop isn't running, drain immediately on the camera queue.
        queue.async { [weak self] in self?.drainPendingOps() }
    }

    // MARK: - Hooks (override in subclasses)

    /// Called once before the first OPEN_SESSION attempt, after the settle delay.
    /// Default: no-op. Sony overrides to drain stale bulk-IN bytes that would
    /// otherwise be parsed as part of the OPEN_SESSION response.
    func preSessionOpenSetup() {}

    /// Send vendor-specific handshake after OPEN_SESSION succeeds.
    /// Default: parse GetDeviceInfo into `supportedOps`.
    func performVendorConnect() {
        parseDeviceInfo()
    }

    /// Run the full property discovery pass.
    ///
    /// Default: standard PTP — walk `standardPropertyIds` (populated from the
    /// GetDeviceInfo response by `parseDeviceInfo`) and call standard
    /// `GetDevicePropDesc` (0x1014) on each. This works as-is for Nikon,
    /// Fujifilm X/GFX, Olympus modern bodies, and Pentax/Ricoh — every
    /// vendor that honours the spec.
    ///
    /// Vendors with non-spec property models override this:
    ///   - `UsbNikonCamera`: probes a hand-curated property list (Nikon's
    ///     `standardPropertyIds` understates what the body actually
    ///     supports — many properties are queryable without ever appearing
    ///     in DeviceInfo).
    ///   - `UsbCanonCamera`: Canon doesn't expose vendor properties via
    ///     GetDevicePropDesc at all — runs the RequestPropertyValue /
    ///     GetEvent harvest path instead.
    ///   - `UsbSonyCamera`: uses Sony's extended GetAllDevicePropData
    ///     (0x9209) which returns every property in one transaction.
    ///   - `UsbPanasonicCamera`: 32-bit property codes via ListProperty
    ///     (0x9108).
    func discoverAllProperties() -> [UInt32: UsbCameraProperty] {
        var out: [UInt32: UsbCameraProperty] = [:]
        for pid16 in standardPropertyIds {
            if closing { break }
            if let prop = getDevicePropDesc(UInt32(pid16)) {
                out[UInt32(pid16)] = prop
            }
        }
        discoveredProperties = out
        return out
    }

    /// Pre-flight before entering the frame loop. Return false to abort live view.
    /// Default: no-op, returns true.
    func startLiveViewSession() -> Bool { true }

    /// Fetch one JPEG frame from the camera. Return nil if no frame is available
    /// this iteration (e.g. DEVICEBUSY, NOTLIVEVIEW recovery in progress).
    /// Called inside an autoreleasepool on the camera queue.
    /// Throw to signal a transport error — loop pauses 0.5s and retries.
    func fetchOneFrame() throws -> Data? { nil }

    /// Poll for camera-side events (property changes etc.). Default: no-op.
    /// Called every `eventPollInterval` frames inside the LV loop.
    func pollEvents() {}

    /// Send STOPLIVEVIEW (or vendor equivalent) when the LV loop exits cleanly.
    /// Not called when `closing` is set — `performVendorCleanup` handles that path.
    func stopLiveViewSession() {}

    /// Execute a single queued property-set command. Vendor-specific because
    /// Sony has SetPropStep, Canon has SetPropValEx (0x9110), Nikon uses standard.
    /// Default property-set implementation: issues standard PTP
    /// `SetDevicePropValue (0x1016)`. Works for any vendor that honours the
    /// PTP 1.1 spec — Fuji X / GFX, Olympus modern (OM-1, E-M5/M1 II),
    /// Pentax K-series, Ricoh GR, modern Leica (0x1A98), and Sigma fp's
    /// standard properties (Sigma also has vendor opcodes for exposure
    /// triplet but those aren't wired yet).
    ///
    /// Vendors with non-spec property models override this:
    ///   - `UsbCanonCamera` — uses `SetDevicePropValueEx (0x9110)` with
    ///     payload-length framing.
    ///   - `UsbSonyCamera` — uses `SetPropAbs (0x9205)` /
    ///     `SetPropStep (0x9207)` based on the property's `incremental` flag.
    ///   - `UsbPanasonicCamera` — uses `SetProperty (0x9403)` with the
    ///     propcode+valuesize header.
    ///   - `UsbNikonCamera` — uses standard SetDevicePropValue but post-set
    ///     refresh + LV-prohibit guards live in its override.
    ///
    /// Wire format here is per PTP spec section 10.4.16: command 0x1016
    /// with Param1=propcode, data phase carrying just the raw value bytes
    /// in little-endian, width determined by `pending.dataType`.
    func performPropertySet(_ pending: PendingSet) {
        guard supportedOps.contains(PTP_CMD_SETPROPVAL) else {
            cameraLog.fault("performPropertySet: SetDevicePropValue (0x1016) not advertised — dropping set 0x\(String(pending.propId, radix: 16), privacy: .public)")
            return
        }
        let payload = encodeStandardPtpValue(pending.value, dataType: pending.dataType)
        let cmd = transport.buildCommand(code: PTP_CMD_SETPROPVAL,
                                          parameters: [pending.propId])
        guard let (_, rsp) = try? transport.sendPtpCommand(cmd, outData: payload) else {
            cameraLog.fault("SetDevicePropValue 0x\(String(pending.propId, radix: 16), privacy: .public) transport error")
            return
        }
        let code = transport.responseCode(from: rsp)
        cameraLog.fault("SetDevicePropValue 0x\(String(pending.propId, radix: 16), privacy: .public) = \(pending.value, privacy: .public) (dt=\(pending.dataType, privacy: .public)) → 0x\(String(code, radix: 16), privacy: .public)")
        guard code == PTP_RSP_OK else { return }
        // Refresh the descriptor so the agent's menu reflects the committed
        // value — some bodies (notably Pentax) clamp to legal stops and
        // we'd otherwise leave the menu showing what we asked for rather
        // than what stuck.
        if let updated = getDevicePropDesc(pending.propId) {
            discoveredProperties[pending.propId] = updated
            onPropertiesDiscovered?([pending.propId: updated])
        }
    }

    /// Pack a numeric PTP value into the little-endian byte string the
    /// standard `SetDevicePropValue` data phase expects. Width is taken
    /// from the PTP DataType (INT8=1 / UINT8=2 → 1 byte, INT16=3 /
    /// UINT16=4 → 2 bytes, INT32=5 / UINT32=6 → 4 bytes, INT64=7 /
    /// UINT64=8 → 8 bytes). Anything else falls back to 4 bytes — the
    /// safe-ish default since 32-bit is the most common width.
    func encodeStandardPtpValue(_ value: UInt32, dataType: UInt16) -> Data {
        switch dataType {
        case 1, 2:    // INT8 / UINT8
            return Data([UInt8(value & 0xFF)])
        case 3, 4:    // INT16 / UINT16
            let v = UInt16(value & 0xFFFF).littleEndian
            return withUnsafeBytes(of: v) { Data($0) }
        case 7, 8:    // INT64 / UINT64
            let v = UInt64(value).littleEndian
            return withUnsafeBytes(of: v) { Data($0) }
        default:      // INT32 / UINT32 and anything unknown
            let v = value.littleEndian
            return withUnsafeBytes(of: v) { Data($0) }
        }
    }

    /// Vendor-specific cleanup before CLOSE_SESSION (e.g. STOPLIVEVIEW for Nikon).
    func performVendorCleanup() {}

    // MARK: - Phase 1: session open + property discovery

    private func runOpenSessionPhase() {
        // Settle delay before first command.
        let settleSteps = max(1, Int(sessionOpenSettleSeconds / 0.1))
        for _ in 0..<settleSteps {
            if closing { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if closing { return }

        // Vendor-specific pre-OPEN_SESSION setup (e.g. Sony bulk-IN drain).
        preSessionOpenSetup()
        if closing { return }

        guard performStandardSessionOpen() else { return }
        if closing { return }

        performVendorConnect()
        if closing { return }

        let discovered = discoverAllProperties()
        cameraLog.fault("discovered \(discovered.count, privacy: .public) properties")
        if !discovered.isEmpty {
            onPropertiesDiscovered?(discovered)
        }
    }

    /// Standard OPEN_SESSION with retry on 0x201E (SessionAlreadyOpen) and
    /// transport error retry with clearStalls. Sets `sessionOpen` on success.
    func performStandardSessionOpen() -> Bool {
        for attempt in 1...5 {
            if closing { return false }
            do {
                let (_, rsp) = try transport.sendPtpCommand(
                    transport.buildCommand(code: PTP_CMD_OPENSESSION, parameters: [1]))
                var code = transport.responseCode(from: rsp)

                if code == PTP_RSP_SESSIONALREADY {
                    cameraLog.fault("session already open — CLOSE_SESSION + retry")
                    _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_CLOSESESSION))
                    Thread.sleep(forTimeInterval: 0.3)
                    let (_, rsp2) = try transport.sendPtpCommand(
                        transport.buildCommand(code: PTP_CMD_OPENSESSION, parameters: [1]))
                    code = transport.responseCode(from: rsp2)
                }

                if code == PTP_RSP_OK {
                    sessionOpen = true
                    cameraLog.fault("session opened (attempt \(attempt, privacy: .public))")
                    return true
                }
                cameraLog.fault("OPEN_SESSION attempt \(attempt, privacy: .public) code=0x\(String(code, radix:16), privacy: .public)")
            } catch {
                cameraLog.fault("OPEN_SESSION attempt \(attempt, privacy: .public) error: \(String(describing: error), privacy: .public)")
                if attempt < 5 {
                    Thread.sleep(forTimeInterval: 0.5)
                    if clearStallsOnSessionRetry { transport.clearStalls() }
                }
            }
        }
        return false
    }

    /// Property codes listed by the most recent `parseDeviceInfo()` call.
    var standardPropertyIds: [UInt16] = []

    /// Serial number reported by the camera in its GetDeviceInfo response, if
    /// any. Some cameras (Canon EOS DSLRs in particular) leave the USB device
    /// descriptor serial empty but still expose a serial through PTP.
    var deviceSerial: String?

    /// GetDeviceInfo → `supportedOps` and `standardPropertyIds`. Subclasses can
    /// call this from `performVendorConnect` (it's already the default) or
    /// override entirely.
    func parseDeviceInfo() {
        guard let (inData, rsp) = try? transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_GETDEVICEINFO)),
              transport.responseCode(from: rsp) == PTP_RSP_OK,
              let data = inData else {
            cameraLog.fault("GetDeviceInfo failed")
            return
        }
        let p = PtpPropParser(data)
        _ = p.readU16()              // StandardVersion
        _ = p.readU32()              // VendorExtensionID
        _ = p.readU16()              // VendorExtensionVersion
        p.skipPtpString()            // VendorExtensionDesc
        _ = p.readU16()              // FunctionalMode
        if let ops = p.readU16Array() {
            supportedOps = Set(ops)
        }
        p.skipArray(elementSize: 2)  // EventsSupported
        if let props = p.readU16Array() {
            standardPropertyIds = props
        }
        p.skipArray(elementSize: 2)  // CaptureFormats
        p.skipArray(elementSize: 2)  // ImageFormats
        let manufacturer = p.readPtpString() ?? "?"
        let model        = p.readPtpString() ?? "?"
        let version      = p.readPtpString() ?? "?"
        // Diagnostic: log raw bytes at the SerialNumber offset so we can
        // verify the parser landed at the right place. The first byte
        // should be a sensible charCount (typically 6–20 for a real serial).
        let serialOffset = p.offset
        let preview = data.subdata(in: serialOffset ..< min(serialOffset + 32, data.count))
        let previewHex = preview.map { String(format: "%02x", $0) }.joined(separator: " ")
        let serial = p.readPtpString()
        if let s = serial, !s.isEmpty { deviceSerial = s }
        cameraLog.fault("GetDeviceInfo — \(self.supportedOps.count, privacy: .public) ops, \(self.standardPropertyIds.count, privacy: .public) standard props")
        cameraLog.fault("  manufacturer=\(manufacturer, privacy: .public) model=\(model, privacy: .public) version=\(version, privacy: .public)")
        cameraLog.fault("  serial offset=\(serialOffset, privacy: .public) raw=\(previewHex, privacy: .public) decoded=\(self.deviceSerial ?? "(none)", privacy: .public)")
    }

    // MARK: - Phase 2: live view loop

    private func runLiveViewPhase() {
        guard sessionOpen && !closing else {
            cameraLog.fault("startLiveView called but session not ready (open=\(self.sessionOpen, privacy: .public) closing=\(self.closing, privacy: .public))")
            return
        }

        // Stall recovery is gated to "only when the previous LV
        // session actually observed a stall" — see the same
        // gating rule in `handleLiveViewTransportError`. The
        // Nikon D800's PTP firmware enters an error-recovery state
        // if `CLEAR_FEATURE(ENDPOINT_HALT)` is sent to a non-halted
        // endpoint (project memory: prior testing during the
        // IOKit-USB migration), so we only clear when the flag
        // says we observed a stall earlier.
        if liveViewNeedsStallRecovery {
            cameraLog.fault("LV restart: clearing pipes from prior session stall")
            transport.clearStalls()
            _ = transport.drainBulkIn(timeout: 0.05)
            liveViewNeedsStallRecovery = false
        }

        guard startLiveViewSession() else {
            let reason = liveViewStartError ?? "Live view could not be started. The camera may be in playback mode, asleep, missing a lens, or otherwise refusing the request."
            liveViewStartError = nil
            cameraLog.fault("live view session start failed: \(reason, privacy: .public)")
            onLiveViewStartFailed?(reason)
            return
        }
        if stopLv || closing { return }

        cameraLog.fault("entering live view loop")
        var frameCount = 0
        var pollCounter = 0
        /// Consecutive transport-error count. Reset on any
        /// successful round-trip. Used to escalate from a soft
        /// `clearStalls` recovery to bailing out of the LV loop
        /// entirely when the USB stack is wedged beyond what stall
        /// clears can fix.
        var consecutiveTransportErrors = 0

        while !stopLv && !closing {
            autoreleasepool {
                drainPendingOps()
                guard !stopLv && !closing else { return }

                pollCounter += 1
                if pollCounter % eventPollInterval == 0 { pollEvents() }

                let frameStart = Date()
                do {
                    if let jpeg = try fetchOneFrame() {
                        // Any successful frame means the pipe is
                        // healthy again — clear the recovery
                        // counter so a *new* burst of stalls gets
                        // its own full retry budget.
                        consecutiveTransportErrors = 0
                        frameCount += 1
                        if frameCount == 1 || frameCount == 10 || frameCount % 150 == 0 {
                            cameraLog.fault("frame #\(frameCount, privacy: .public) \(jpeg.count, privacy: .public)B → CMIO")
                        }
                        onJpegFrame?(jpeg)
                    }
                } catch {
                    if !stopLv && !closing {
                        handleLiveViewTransportError(
                            error,
                            consecutiveErrors: &consecutiveTransportErrors)
                    }
                }

                let elapsed = -frameStart.timeIntervalSinceNow
                let remaining = frameInterval - elapsed
                if remaining > 0.001 { Thread.sleep(forTimeInterval: remaining) }
            }
        }

        cameraLog.fault("LV loop exited (stopLv=\(self.stopLv, privacy: .public) closing=\(self.closing, privacy: .public))")
        if !closing { stopLiveViewSession() }
    }

    /// Maximum consecutive `bulkOutFailed` / `bulkInFailed` errors
    /// the LV loop absorbs before forcing `stopLv`. A single
    /// successful frame resets the counter.
    private static let maxConsecutiveLiveViewTransportErrors = 90

    /// Centralised handler for live-view-loop transport failures.
    ///   1. Log the error. First error in a streak goes to `fault`;
    ///      subsequent ones in the same streak go to `info` to
    ///      avoid flooding the default log.
    ///   2. Bail (set `stopLv`) if the streak crosses
    ///      `maxConsecutiveLiveViewTransportErrors`.
    ///   3. If the underlying IOReturn is `kIOUSBPipeStalled`,
    ///      issue `CLEAR_FEATURE(ENDPOINT_HALT)` on all PTP pipes
    ///      via `transport.clearStalls()` and drain bulk-IN.
    ///      Otherwise skip the clear — see the in-body comment for
    ///      the Nikon D800 firmware behaviour that drives this
    ///      gating.
    ///   4. 100 ms back-off before returning to the LV loop.
    private func handleLiveViewTransportError(
        _ error: Error,
        consecutiveErrors: inout Int
    ) {
        consecutiveErrors += 1
        // `Logger`'s `.log(level:)` autoclosure can't capture an
        // inout — snapshot to a local before logging.
        let attempts = consecutiveErrors
        let errDesc = String(describing: error)
        if attempts == 1 {
            cameraLog.fault("frame fetch error #\(attempts, privacy: .public): \(errDesc, privacy: .public)")
        } else {
            cameraLog.info("frame fetch error #\(attempts, privacy: .public): \(errDesc, privacy: .public)")
        }

        if attempts > Self.maxConsecutiveLiveViewTransportErrors {
            cameraLog.fault("LV loop bailing — \(attempts, privacy: .public) consecutive transport errors")
            stopLv = true
            return
        }

        // ClearStalls is gated to `kIOUSBPipeStalled` only. On the
        // Nikon D800, calling `CLEAR_FEATURE(ENDPOINT_HALT)`
        // against a non-halted endpoint puts the body's PTP
        // firmware into an error-recovery state that then refuses
        // OPEN_SESSION and STARTLIVEVIEW (project memory: prior
        // testing during the IOKit-USB migration; see
        // `liveViewNeedsStallRecovery` comment). The transport
        // already issues `CancelTransaction` on the bulk-IN timeout
        // path (`UsbPtpTransport.sendPtpCommand`), which is the
        // appropriate cleanup for `kIOReturnNotResponding`.
        let ioReturn = Self.ioReturnCode(from: error)
        if ioReturn == IOUSBReturns.pipeStalled {
            liveViewNeedsStallRecovery = true
            transport.clearStalls()
            _ = transport.drainBulkIn(timeout: 0.05)
        } else if attempts == 1 {
            // Log the raw IOReturn on the first error in a streak
            // so the failure mode (stall vs. silence timeout vs.
            // other) is identifiable from the log.
            cameraLog.fault("LV error IOReturn=0x\(String(UInt32(bitPattern: ioReturn), radix:16), privacy: .public) — no stall clear (pipe not halted)")
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// IOReturn codes from IOUSBHost we explicitly act on,
    /// hard-coded rather than imported via a bridging header.
    private enum IOUSBReturns {
        /// `kIOUSBPipeStalled` (0xE000404F as unsigned, encoded as
        /// `Int32` here). Recovered with
        /// `CLEAR_FEATURE(ENDPOINT_HALT)`.
        static let pipeStalled: Int32 = -536854449
    }

    /// Extract the underlying `IOReturn` code from a transport
    /// error. IOUSBHost reports `IOReturn` codes as
    /// `NSError(domain: "IOUSBErrorDomain", code: <IOReturn>)`;
    /// our transport wraps that into `UsbPtpError.bulkOutFailed` /
    /// `.bulkInFailed` / `.openFailed`. Returns 0 if the error
    /// isn't from the IOUSBHost framework, which routes the caller
    /// down the no-clear path.
    private static func ioReturnCode(from error: Error) -> Int32 {
        let underlying: Error
        switch error as? UsbPtpError {
        case .bulkOutFailed(let e), .bulkInFailed(let e),
             .openFailed(let e):
            underlying = e
        default:
            underlying = error
        }
        let ns = underlying as NSError
        guard ns.domain == "IOUSBErrorDomain" else { return 0 }
        return Int32(truncatingIfNeeded: ns.code)
    }

    // MARK: - Pending-set drain

    /// Execute all queued property-set commands. Runs on the camera queue
    /// (between LV frames, or as a standalone dispatch when LV isn't running).
    /// Drain the pending-ops queue. Runs deferred SetProperty and Autofocus
    /// work in FIFO order on the camera queue — called once per live-view
    /// frame iteration, and also as a one-shot kick when the LV loop isn't
    /// running so commands aren't held up.
    final func drainPendingOps() {
        // Snapshot under lock so we can release before doing slow PTP work.
        pendingLock.lock()
        let ops = pendingOps
        pendingOps.removeAll()
        pendingLock.unlock()

        // If the session isn't open (still in settle delay, or already closed),
        // re-queue every op for the next drain attempt instead of silently
        // discarding them. The session-state transitions on the same camera
        // queue, so this drain will be re-invoked shortly.
        guard sessionOpen else {
            pendingLock.lock()
            pendingOps.insert(contentsOf: ops, at: 0)
            pendingLock.unlock()
            return
        }

        for (index, op) in ops.enumerated() {
            // Re-check between ops: the camera may have been disconnected
            // mid-batch (close() flips sessionOpen → false). Save the
            // remaining work for the next drain.
            guard sessionOpen else {
                let remaining = Array(ops[index...])
                pendingLock.lock()
                pendingOps.insert(contentsOf: remaining, at: 0)
                pendingLock.unlock()
                cameraLog.fault("drainPendingOps: session closed mid-drain, re-queued \(remaining.count, privacy: .public) op(s)")
                return
            }
            switch op {
            case .setProperty(let cmd):
                performPropertySet(cmd)
            case .autofocus:
                performAutofocus()
            case .autofocusCancel:
                performAutofocusCancel()
            }
        }
    }

    /// Backwards-compatible alias for callers (vendor subclasses or external
    /// code) that still refer to the older name. Just drains the unified
    /// pending-ops queue.
    final func drainPendingSets() { drainPendingOps() }

    // MARK: - Cleanup

    private func runCleanUpPhase() {
        if sessionOpen {
            performVendorCleanup()
            _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_CLOSESESSION))
            sessionOpen = false
            cameraLog.fault("session closed")
        }
        transport.close()
        cameraLog.fault("transport closed")
    }

    // MARK: - Helpers for subclasses

    /// Encode a UInt32 value into the bytes expected for a PTP dataType (1..6, signed/unsigned).
    /// Used by SETPROPVAL payloads.
    static func encodeLE(value: UInt32, dataType: UInt16) -> Data {
        var out = Data()
        switch dataType {
        case 1: out.appendLE(UInt8(bitPattern: Int8(bitPattern: UInt8(value & 0xFF))))
        case 2: out.appendLE(UInt8(value & 0xFF))
        case 3: out.appendLE(UInt16(bitPattern: Int16(bitPattern: UInt16(value & 0xFFFF))))
        case 4: out.appendLE(UInt16(value & 0xFFFF))
        case 5: out.appendLE(value)
        case 6: out.appendLE(value)
        default: out.appendLE(UInt16(value & 0xFFFF))
        }
        return out
    }

    /// Send a standard PTP SetPropVal (0x1016). Returns the response code, or nil on transport error.
    @discardableResult
    func sendStandardSetPropVal(propId: UInt32, value: UInt32, dataType: UInt16) -> UInt16? {
        let outData = Self.encodeLE(value: value, dataType: dataType)
        let cmd = transport.buildCommand(code: PTP_CMD_SETPROPVAL, parameters: [propId])
        guard let (_, rsp) = try? transport.sendPtpCommand(cmd, outData: outData) else { return nil }
        return transport.responseCode(from: rsp)
    }

    /// Send a standard PTP GetDevicePropDesc (0x1014) and parse the response.
    /// Returns nil on transport error or non-OK response.
    func getDevicePropDesc(_ propId: UInt32) -> UsbCameraProperty? {
        let cmd = transport.buildCommand(code: PTP_CMD_GETPROPDESC, parameters: [propId])
        guard let (inData, rsp) = try? transport.sendPtpCommand(cmd),
              transport.responseCode(from: rsp) == PTP_RSP_OK,
              let data = inData else { return nil }
        return PtpPropParser(data).parsePropDesc()
    }

    /// Render a human-readable PTP property dump from in-memory state. Used
    /// for cameras the extension has already opened — avoids fresh PTP I/O,
    /// so no risk of conflicting with the camera's own poll loop. Includes
    /// every fact we have on hand (ops, properties, current values, enums,
    /// ranges) — the descriptor-level format matches PtpDumper's live output
    /// as closely as the in-memory model allows.
    func generateInMemoryDump() -> String {
        var out = ""
        func line(_ s: String = "") { out.append(s); out.append("\n") }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        line("PTP Property Dump (from cached state)")
        line("=====================================")
        line("Generated: \(fmt.string(from: Date()))")
        line("USB VID:PID: \(String(format: "%04X:%04X", transport.vendorId, transport.productId))")
        line("USB Product Name: \(transport.deviceName)")
        if let s = deviceSerial { line("Serial Number (PTP): \(s)") }
        line("")
        line("Note: this dump was synthesized from in-memory state because the")
        line("camera was already claimed by PTP Webcam. Values reflect the most")
        line("recent property poll, not a fresh GetDevicePropDesc round-trip.")
        line("")

        let vendor = PtpKnownCameras.protocolFamily(forVid: transport.vendorId,
                                                    pid: transport.productId)
        // Render `<dec> (0xHEX) [interp]`. Interp comes from formatExtPropRaw
        // (Sony WB names, Nikon shutter denominator table, EV-bias × 0.001,
        // ISO-Auto sentinel, etc.). Dropped when identical to the bare decimal.
        func formatVal(_ n: NSNumber, _ propId: UInt32, _ dataType: UInt16) -> String {
            let hex: String
            switch dataType {
            case 1: hex = String(format: "%d (0x%02X)", n.int8Value, UInt8(bitPattern: n.int8Value))
            case 2: hex = String(format: "%u (0x%02X)", n.uint8Value, n.uint8Value)
            case 3: hex = String(format: "%d (0x%04X)", n.int16Value, UInt16(bitPattern: n.int16Value))
            case 4: hex = String(format: "%u (0x%04X)", n.uint16Value, n.uint16Value)
            case 5: hex = String(format: "%d (0x%08X)", n.int32Value, UInt32(bitPattern: n.int32Value))
            case 6: hex = String(format: "%u (0x%08X)", n.uint32Value, n.uint32Value)
            default: hex = n.description
            }
            let pretty = formatExtPropRaw(n, propId: propId, vendor: vendor)
            if pretty == "\(n)" || pretty == n.stringValue { return hex }
            return "\(hex)  → \(pretty)"
        }

        let sortedOps = supportedOps.sorted()
        line("=== Supported Operations (\(sortedOps.count)) ===")
        for op in sortedOps {
            line(String(format: "  0x%04X  %@", op, PtpKnownCameras.operationName(op, vendor: vendor) as NSString))
        }
        line("")

        line("=== Supported Standard Properties (\(standardPropertyIds.count)) ===")
        for pid in standardPropertyIds {
            line(String(format: "  0x%04X  %@", pid, PtpKnownCameras.propertyName(pid, vendor: vendor) as NSString))
        }
        line("")

        let sortedProps = discoveredProperties.keys.sorted()
        line("=== Discovered Property Descriptors (\(sortedProps.count)) ===")
        line("")
        for pid in sortedProps {
            guard let prop = discoveredProperties[pid] else { continue }
            line(String(format: "[0x%04X] %@", pid, PtpKnownCameras.propertyName(UInt16(pid & 0xFFFF), vendor: vendor) as NSString))
            line(String(format: "  DataType:  0x%04X (%@)", prop.dataType, PtpKnownCameras.dataTypeName(prop.dataType) as NSString))
            line("  Writable:  \(prop.writable)")
            if prop.incremental { line("  Incremental: true (Sony SetPropStep)") }
            if prop.isButton    { line("  Button:    true") }
            if let d = prop.defaultValue {
                line("  Default:   \(formatVal(d, pid, prop.dataType))")
            }
            line("  Current:   \(formatVal(prop.value, pid, prop.dataType))")
            if let enums = prop.enumValues {
                line("  Form:      Enum (\(enums.count) values)")
                for v in enums { line("    " + formatVal(v, pid, prop.dataType)) }
            } else if let mn = prop.rangeMin, let mx = prop.rangeMax {
                line("  Form:      Range")
                line("    Min:     \(formatVal(mn, pid, prop.dataType))")
                line("    Max:     \(formatVal(mx, pid, prop.dataType))")
                if let st = prop.rangeStep { line("    Step:    \(formatVal(st, pid, prop.dataType))") }
            } else {
                line("  Form:      none")
            }
            line("")
        }
        return out
    }
}

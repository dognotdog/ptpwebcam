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

let PTP_CMD_GETDEVICEINFO:  UInt16 = 0x1001
let PTP_CMD_OPENSESSION:    UInt16 = 0x1002
let PTP_CMD_CLOSESESSION:   UInt16 = 0x1003
let PTP_CMD_GETPROPDESC:    UInt16 = 0x1014
let PTP_CMD_SETPROPVAL:     UInt16 = 0x1016
let PTP_RSP_OK:             UInt16 = 0x2001
let PTP_RSP_DEVICEBUSY:     UInt16 = 0x2019
let PTP_RSP_SESSIONALREADY: UInt16 = 0x201E
let PTP_EVENT_DEVICEPROPCHANGED: UInt16 = 0x4006

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
    }
    private var pendingOps: [PendingOp] = []
    private let pendingLock = NSLock()

    var onJpegFrame: ((Data) -> Void)?
    var onPropertiesDiscovered: (([UInt32: UsbCameraProperty]) -> Void)?

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
        self.cameraLog = Logger(subsystem: "org.ptpwebcam.CameraExtension", category: logTag)
        self.queue = DispatchQueue(label: "org.ptpwebcam.\(logTag.lowercased())", qos: .userInteractive)
        cameraLog.fault("init vid=0x\(String(transport.vendorId, radix:16), privacy: .public) pid=0x\(String(transport.productId, radix:16), privacy: .public) name=\(transport.deviceName, privacy: .public)")
    }

    // MARK: - UsbCameraProtocol (final — subclasses customize via hooks)

    final func openSessionAndDiscover() {
        queue.async { [weak self] in self?.runOpenSessionPhase() }
    }

    final func startLiveView() {
        guard !closing else { return }
        stopLv = false
        queue.async { [weak self] in self?.runLiveViewPhase() }
    }

    final func stopLiveView() {
        stopLv = true
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

    /// Vendor-specific autofocus trigger. Override per subclass.
    func performAutofocus() { }

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

    /// Run the full property discovery pass. Default: empty.
    /// Override to populate `discoveredProperties` and return the dict to publish.
    func discoverAllProperties() -> [UInt32: UsbCameraProperty] { [:] }

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
    func performPropertySet(_ pending: PendingSet) {}

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

        guard startLiveViewSession() else {
            cameraLog.fault("live view session start failed")
            return
        }
        if stopLv || closing { return }

        cameraLog.fault("entering live view loop")
        var frameCount = 0
        var pollCounter = 0

        while !stopLv && !closing {
            autoreleasepool {
                drainPendingOps()
                guard !stopLv && !closing else { return }

                pollCounter += 1
                if pollCounter % eventPollInterval == 0 { pollEvents() }

                let frameStart = Date()
                do {
                    if let jpeg = try fetchOneFrame() {
                        frameCount += 1
                        if frameCount == 1 || frameCount == 10 || frameCount % 150 == 0 {
                            cameraLog.fault("frame #\(frameCount, privacy: .public) \(jpeg.count, privacy: .public)B → CMIO")
                        }
                        onJpegFrame?(jpeg)
                    }
                } catch {
                    if !stopLv && !closing {
                        cameraLog.fault("frame fetch error: \(String(describing: error), privacy: .public) — pausing")
                        Thread.sleep(forTimeInterval: 0.5)
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
}

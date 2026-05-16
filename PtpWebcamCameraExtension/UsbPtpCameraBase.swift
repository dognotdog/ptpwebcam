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
        line("Note: this dump was synthesised from in-memory state because the")
        line("camera was already claimed by PTP Webcam. Values reflect the most")
        line("recent property poll, not a fresh GetDevicePropDesc round-trip.")
        line("")

        let vendor = PtpKnownCameras.vendor(forVid: transport.vendorId)
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
            line(String(format: "  0x%04X  %@", op, PtpKnownCameras.operationName(op) as NSString))
        }
        line("")

        line("=== Supported Standard Properties (\(standardPropertyIds.count)) ===")
        for pid in standardPropertyIds {
            line(String(format: "  0x%04X  %@", pid, PtpKnownCameras.propertyName(pid) as NSString))
        }
        line("")

        let sortedProps = discoveredProperties.keys.sorted()
        line("=== Discovered Property Descriptors (\(sortedProps.count)) ===")
        line("")
        for pid in sortedProps {
            guard let prop = discoveredProperties[pid] else { continue }
            line(String(format: "[0x%04X] %@", pid, PtpKnownCameras.propertyName(UInt16(pid & 0xFFFF)) as NSString))
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

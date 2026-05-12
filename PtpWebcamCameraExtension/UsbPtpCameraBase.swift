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
    private var pendingSets: [PendingSet] = []
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

    final func setProperty(propId: UInt32, value: UInt32, dataType: UInt16) {
        pendingLock.lock()
        pendingSets.append(PendingSet(propId: propId, value: value, dataType: dataType))
        pendingLock.unlock()
        // If the live view loop isn't running, drain immediately on the camera queue.
        queue.async { [weak self] in self?.drainPendingSets() }
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
        _ = p.readU16()              // standard version
        _ = p.readU32()              // vendor extension ID
        _ = p.readU16()              // vendor extension version
        p.skipPtpString()            // vendor extension desc
        _ = p.readU16()              // functional mode
        if let ops = p.readU16Array() {
            supportedOps = Set(ops)
        }
        p.skipArray(elementSize: 2)  // EventsSupported
        if let props = p.readU16Array() {
            standardPropertyIds = props
        }
        cameraLog.fault("GetDeviceInfo — \(self.supportedOps.count, privacy: .public) ops, \(self.standardPropertyIds.count, privacy: .public) standard props")
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
                drainPendingSets()
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
    final func drainPendingSets() {
        pendingLock.lock()
        let cmds = pendingSets
        pendingSets.removeAll()
        pendingLock.unlock()

        for cmd in cmds {
            guard sessionOpen else { break }
            performPropertySet(cmd)
        }
    }

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

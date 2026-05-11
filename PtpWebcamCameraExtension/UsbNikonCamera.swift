// UsbNikonCamera.swift
// Nikon PTP live view loop running directly over USB inside the CMIO extension.
// No agent IPC needed — operates the camera entirely in-process.

import Foundation
import CoreGraphics
import ImageIO
import CoreVideo
import os.log

// MARK: - Nikon PTP constants (mirrored from PtpCameraAgent target)

private let PTP_CMD_GETDEVICEINFO:          UInt16 = 0x1001
private let PTP_CMD_OPENSESSION:            UInt16 = 0x1002
private let PTP_CMD_CLOSESESSION:           UInt16 = 0x1003
private let PTP_CMD_GETPROPDESC:            UInt16 = 0x1014
private let PTP_CMD_SETPROPVAL:             UInt16 = 0x1016
private let PTP_RSP_OK:                     UInt16 = 0x2001
private let PTP_RSP_DEVICEBUSY:             UInt16 = 0x2019

private let PTP_CMD_NIKON_GETVENDORPROPS:   UInt16 = 0x90CA
private let PTP_CMD_NIKON_STARTLIVEVIEW:    UInt16 = 0x9201
private let PTP_CMD_NIKON_STOPLIVEVIEW:     UInt16 = 0x9202
private let PTP_CMD_NIKON_GETLIVEVIEWIMG:   UInt16 = 0x9203
private let PTP_CMD_NIKON_DEVICEREADY:      UInt16 = 0x90C8
private let PTP_CMD_NIKON_GETVENDORCODES:   UInt16 = 0x9439

private let PTP_RSP_NIKON_NOTLIVEVIEW:      UInt16 = 0xA00B

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

// Nikon UI property codes to discover after session open.
// Order matches PtpCameraNikon.uiProperties.
private let nikonUiPropertyIds: [UInt16] = [
    0x5001,  // Battery Level
    0x5008,  // Focal Length
    0xD1A6,  // LV Selector (still/video)
    0xD1A2,  // LV Status
    0x500E,  // Exposure Program
    0x5007,  // Aperture (F-number × 100)
    0xD1A9,  // Movie Aperture
    0x500F,  // ISO
    0xD054,  // Auto ISO
    0xD100,  // Nikon Shutter Speed
    0xD1A8,  // Movie Shutter Speed
    0x5005,  // White Balance
    0x5010,  // Exposure Bias
    0xD1AB,  // Movie Exposure Bias
    0xD061,  // LV AF Mode
    0xD05D,  // LV AF Area Mode
    0xD1A3,  // LV Zoom
    0xD1A0,  // LV Mode (mirror position)
    0xD1A5,  // LV Exposure Preview
    0xD17B,  // LV Apply Settings
    0xD1AC,  // LV Image Size
]

// MARK: - NikonDiscoveredProperty

struct NikonDiscoveredProperty {
    let propertyId: UInt16
    let dataType: UInt16
    let writable: Bool
    let value: NSNumber
    let enumValues: [NSNumber]?
    let rangeMin: NSNumber?
    let rangeMax: NSNumber?
    let rangeStep: NSNumber?
}

// MARK: - PropParser (minimal PTP data parser, no ImageCapture dependency)

private class PropParser {
    private let data: Data
    private var offset: Int = 0

    init(_ data: Data) { self.data = data }

    func readU8() -> UInt8? {
        guard offset + 1 <= data.count else { return nil }
        let v = data[offset]; offset += 1; return v
    }
    func readU16() -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        let v = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        offset += 2; return v
    }
    func readU32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(data[offset + i]) << (i * 8) }
        offset += 4; return v
    }
    func readNum(ofType dt: UInt16) -> NSNumber? {
        switch dt {
        case 1: return readU8().map  { NSNumber(value: Int8(bitPattern: $0)) }
        case 2: return readU8().map  { NSNumber(value: $0) }
        case 3: return readU16().map { NSNumber(value: Int16(bitPattern: $0)) }
        case 4: return readU16().map { NSNumber(value: $0) }
        case 5: return readU32().map { NSNumber(value: Int32(bitPattern: $0)) }
        case 6: return readU32().map { NSNumber(value: $0) }
        default: return nil
        }
    }
    func skip(type dt: UInt16) {
        _ = readNum(ofType: dt)
    }

    // PTP string: 1-byte char count (including null terminator), then count × UTF-16LE chars.
    @discardableResult
    func skipPtpString() -> Bool {
        guard let charCount = readU8() else { return false }
        guard offset + Int(charCount) * 2 <= data.count else { return false }
        offset += Int(charCount) * 2
        return true
    }

    // PTP array: UInt32 count, followed by count elements of the given data type (1=u8, 2=u8, 4=u16, 6=u32).
    func readU16Array() -> [UInt16]? {
        guard let count = readU32() else { return nil }
        var result: [UInt16] = []
        result.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let v = readU16() else { return nil }
            result.append(v)
        }
        return result
    }

    // Skip a PTP array of fixed-width elements (elementSize in bytes: 1, 2, or 4).
    func skipArray(elementSize: Int) {
        guard let count = readU32() else { return }
        let skip = Int(count) * elementSize
        guard offset + skip <= data.count else { return }
        offset += skip
    }
}

// MARK: - UsbNikonCamera

/// Manages a Nikon camera PTP session over a UsbPtpTransport.
/// All USB I/O runs on an internal serial DispatchQueue.
///
/// Lifecycle:
///   openSessionAndDiscover()  — call at camera connect time
///   startLiveView()           — call when CMIO streaming begins
///   stopLiveView()            — call when CMIO streaming stops (session stays open)
///   close()                   — call at camera disconnect (closes session + transport)
final class UsbNikonCamera {

    private let transport: UsbPtpTransport
    private let headerLen: Int
    private let cameraLog = Logger(subsystem: "org.ptpwebcam.CameraExtension", category: "UsbNikonCamera")

    private let queue = DispatchQueue(label: "org.ptpwebcam.usbcamera", qos: .userInteractive)
    // stopLv: signals the live view loop to stop (session stays open).
    // closing: signals the camera is being torn down; suppresses redundant STOPLIVEVIEW in cleanUp.
    private var stopLv   = false
    private var closing  = false
    private var sessionOpen = false

    // Pending property-set commands. Appended from any thread under pendingLock;
    // drained on the camera queue between live view frames (or immediately when not streaming).
    private struct PendingSet { let propId: UInt16; let value: UInt32; let dataType: UInt16 }
    private var pendingSets: [PendingSet] = []
    private let pendingLock = NSLock()

    // Called on queue — passes raw JPEG bytes from GETLIVEVIEWIMG.
    var onJpegFrame: ((Data) -> Void)?

    // Called on queue after property discovery completes (and after each setProperty).
    var onPropertiesDiscovered: (([UInt16: NikonDiscoveredProperty]) -> Void)?

    init(transport: UsbPtpTransport) {
        self.transport = transport
        self.headerLen = nikonLvHeaderLen[transport.productId] ?? 384
        cameraLog.fault("UsbNikonCamera: init vid=0x\(String(transport.vendorId, radix:16), privacy: .public) pid=0x\(String(transport.productId, radix:16), privacy: .public) name=\(transport.deviceName, privacy: .public) headerLen=\(self.headerLen, privacy: .public)")
    }

    // MARK: - Lifecycle

    /// Open PTP session and discover properties. Call once at camera connect time.
    func openSessionAndDiscover() {
        queue.async { [weak self] in self?.runOpenSessionPhase() }
    }

    /// Start live view. Session must be open (openSessionAndDiscover already dispatched).
    /// Queued behind openSessionAndDiscover on the same serial queue.
    func startLiveView() {
        guard !closing else { return }
        stopLv = false
        queue.async { [weak self] in self?.runLiveViewPhase() }
    }

    /// Stop live view loop. Session remains open; call startLiveView() to resume.
    func stopLiveView() {
        stopLv = true
    }

    /// Close PTP session and release transport. Call at camera disconnect.
    func close() {
        stopLv  = true
        closing = true
        queue.async { [weak self] in self?.runCleanUp() }
    }

    // MARK: - Phase 1: Session open + property discovery (runs on queue)

    private func runOpenSessionPhase() {
        // Brief settle to let the camera's PTP stack finish initializing.
        for _ in 0..<10 {
            if closing { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if closing { return }

        do {
            let cmd = transport.buildCommand(code: PTP_CMD_OPENSESSION, parameters: [1])
            let (_, rsp) = try transport.sendPtpCommand(cmd)
            var code = transport.responseCode(from: rsp)

            if code == 0x201E {
                cameraLog.fault("UsbNikonCamera: session already open — CLOSE_SESSION + retry")
                _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_CLOSESESSION))
                Thread.sleep(forTimeInterval: 0.3)
                let cmd2 = transport.buildCommand(code: PTP_CMD_OPENSESSION, parameters: [1])
                let (_, rsp2) = try transport.sendPtpCommand(cmd2)
                code = transport.responseCode(from: rsp2)
            }

            guard code == PTP_RSP_OK else {
                cameraLog.fault("UsbNikonCamera: OPEN_SESSION failed code=0x\(String(code, radix:16), privacy: .public)")
                return
            }
            sessionOpen = true
            cameraLog.fault("UsbNikonCamera: session opened")
        } catch {
            cameraLog.fault("UsbNikonCamera: OPEN_SESSION error: \(String(describing: error), privacy: .public)")
            return
        }

        if closing { return }

        let discovered = discoverAllProperties()
        if !discovered.isEmpty {
            cameraLog.fault("UsbNikonCamera: discovered \(discovered.count, privacy: .public) properties")
            onPropertiesDiscovered?(discovered)
        }
    }

    // MARK: - Phase 2: Live view loop (runs on queue, queued after phase 1)

    private func runLiveViewPhase() {
        guard sessionOpen && !closing else {
            cameraLog.fault("UsbNikonCamera: startLiveView called but session not ready (open=\(self.sessionOpen, privacy: .public) closing=\(self.closing, privacy: .public))")
            return
        }

        // ── STARTLIVEVIEW ─────────────────────────────────────────────────────
        do {
            let cmd = transport.buildCommand(code: PTP_CMD_NIKON_STARTLIVEVIEW)
            let (_, rsp) = try transport.sendPtpCommand(cmd)
            let code = transport.responseCode(from: rsp)
            if code != PTP_RSP_OK {
                cameraLog.fault("UsbNikonCamera: STARTLIVEVIEW code=0x\(String(code, radix:16), privacy: .public) (continuing)")
            } else {
                cameraLog.fault("UsbNikonCamera: live view started")
            }
        } catch {
            cameraLog.fault("UsbNikonCamera: STARTLIVEVIEW error: \(String(describing: error), privacy: .public)")
            return
        }

        waitForDeviceReady()
        if stopLv || closing { return }

        // ── GETLIVEVIEWIMG loop ───────────────────────────────────────────────
        cameraLog.fault("UsbNikonCamera: entering live view loop")
        let targetInterval: TimeInterval = 1.0 / 30.0
        var frameCount = 0

        while !stopLv && !closing {
            // Execute any queued property-set commands before the next frame.
            drainPendingSets()
            if stopLv || closing { break }

            let frameStart = Date()

            do {
                let cmd = transport.buildCommand(code: PTP_CMD_NIKON_GETLIVEVIEWIMG)
                let (inData, rsp) = try transport.sendPtpCommand(cmd)
                let rspCode = transport.responseCode(from: rsp)

                if rspCode == PTP_RSP_NIKON_NOTLIVEVIEW {
                    cameraLog.fault("UsbNikonCamera: NOTLIVEVIEW — restarting")
                    restartLiveView()
                    continue
                }

                if let data = inData, data.count > headerLen {
                    if let jpeg = extractJpeg(from: data) {
                        frameCount += 1
                        if frameCount == 1 || frameCount == 10 || frameCount % 150 == 0 {
                            cameraLog.fault("UsbNikonCamera: frame #\(frameCount, privacy: .public) \(jpeg.count, privacy: .public)B → CMIO")
                        }
                        onJpegFrame?(jpeg)
                    } else {
                        cameraLog.fault("UsbNikonCamera: no JPEG found in \(data.count, privacy: .public)B frame")
                    }
                } else if inData == nil && rspCode == PTP_RSP_DEVICEBUSY {
                    Thread.sleep(forTimeInterval: 0.033)
                } else if let data = inData {
                    cameraLog.fault("UsbNikonCamera: frame too small (\(data.count, privacy: .public)B, headerLen=\(self.headerLen, privacy: .public))")
                }
            } catch {
                if !stopLv && !closing {
                    cameraLog.fault("UsbNikonCamera: GETLIVEVIEWIMG error: \(String(describing: error), privacy: .public) — pausing")
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }

            let elapsed = -frameStart.timeIntervalSinceNow
            let remaining = targetInterval - elapsed
            if remaining > 0.001 { Thread.sleep(forTimeInterval: remaining) }
        }

        cameraLog.fault("UsbNikonCamera: LV loop exited (stopLv=\(self.stopLv, privacy: .public) closing=\(self.closing, privacy: .public))")

        // Send STOPLIVEVIEW unless close() will handle it.
        if !closing {
            _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_NIKON_STOPLIVEVIEW))
        }
    }

    private func waitForDeviceReady() {
        for _ in 0 ..< 30 {
            if stopLv || closing { return }
            Thread.sleep(forTimeInterval: 0.1)
            do {
                let cmd = transport.buildCommand(code: PTP_CMD_NIKON_DEVICEREADY)
                let (_, rsp) = try transport.sendPtpCommand(cmd)
                let code = transport.responseCode(from: rsp)
                if code == PTP_RSP_OK { cameraLog.info("UsbNikonCamera: camera ready"); return }
            } catch {
                cameraLog.info("UsbNikonCamera: DEVICEREADY unsupported or error — proceeding")
                return
            }
        }
        cameraLog.warning("UsbNikonCamera: device never became ready, proceeding anyway")
    }

    private func restartLiveView() {
        do {
            _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_NIKON_STOPLIVEVIEW))
            Thread.sleep(forTimeInterval: 0.5)
            if stopLv || closing { return }
            let cmd = transport.buildCommand(code: PTP_CMD_NIKON_STARTLIVEVIEW)
            let (_, rsp) = try transport.sendPtpCommand(cmd)
            let code = transport.responseCode(from: rsp)
            cameraLog.info("UsbNikonCamera: restart STARTLIVEVIEW code=0x\(String(code, radix:16))")
            waitForDeviceReady()
        } catch {
            cameraLog.error("UsbNikonCamera: restart error: \(error)")
        }
    }

    // MARK: - Property Discovery & Control (runs on queue)

    /// Query GetDeviceInfo (and Nikon GetVendorProps) for the full property list.
    /// Falls back to the hardcoded list if the commands fail.
    private func querySupportedPropertyIds() -> [UInt16] {
        let cmd = transport.buildCommand(code: PTP_CMD_GETDEVICEINFO)
        guard let (inData, rsp) = try? transport.sendPtpCommand(cmd),
              transport.responseCode(from: rsp) == PTP_RSP_OK,
              let data = inData else {
            cameraLog.fault("UsbNikonCamera: GetDeviceInfo failed — using hardcoded list")
            return nikonUiPropertyIds
        }

        let p = PropParser(data)
        _ = p.readU16()              // standard version
        _ = p.readU32()              // vendor extension ID
        _ = p.readU16()              // vendor extension version
        p.skipPtpString()            // vendor extension desc
        _ = p.readU16()              // functional mode
        guard let ops = p.readU16Array() else {
            cameraLog.fault("UsbNikonCamera: GetDeviceInfo ops parse failed — using hardcoded list")
            return nikonUiPropertyIds
        }
        p.skipArray(elementSize: 2)  // supported events
        guard let props = p.readU16Array() else {
            cameraLog.fault("UsbNikonCamera: GetDeviceInfo props parse failed — using hardcoded list")
            return nikonUiPropertyIds
        }

        let supportedOps = Set(ops)
        var allProps = props
        cameraLog.fault("UsbNikonCamera: GetDeviceInfo — \(props.count, privacy: .public) standard props, \(ops.count, privacy: .public) ops")

        // Nikon GetVendorProps / GetVendorCodes adds properties not in standard DeviceInfo.
        if supportedOps.contains(PTP_CMD_NIKON_GETVENDORPROPS) {
            let vcmd = transport.buildCommand(code: PTP_CMD_NIKON_GETVENDORPROPS)
            if let (vData, vRsp) = try? transport.sendPtpCommand(vcmd),
               transport.responseCode(from: vRsp) == PTP_RSP_OK,
               let vd = vData, vd.count >= 4 {
                let vp = PropParser(vd)
                if let vendorProps = vp.readU16Array() {
                    allProps.append(contentsOf: vendorProps)
                    cameraLog.fault("UsbNikonCamera: GetVendorProps — \(vendorProps.count, privacy: .public) additional props")
                }
            }
        } else if supportedOps.contains(PTP_CMD_NIKON_GETVENDORCODES) {
            let vcmd = transport.buildCommand(code: PTP_CMD_NIKON_GETVENDORCODES, parameters: [0x0D])
            if let (vData, vRsp) = try? transport.sendPtpCommand(vcmd),
               transport.responseCode(from: vRsp) == PTP_RSP_OK,
               let vd = vData, vd.count >= 4 {
                // GetVendorCodes returns UInt32 count + UInt32 entries
                let vp = PropParser(vd)
                if let count = vp.readU32() {
                    var vendorProps: [UInt16] = []
                    for _ in 0..<count {
                        if let v = vp.readU32() { vendorProps.append(UInt16(v & 0xFFFF)) }
                    }
                    allProps.append(contentsOf: vendorProps)
                    cameraLog.fault("UsbNikonCamera: GetVendorCodes — \(vendorProps.count, privacy: .public) additional props")
                }
            }
        }

        // Deduplicate while preserving order.
        var seen = Set<UInt16>()
        let unique = allProps.filter { seen.insert($0).inserted }
        cameraLog.fault("UsbNikonCamera: total \(unique.count, privacy: .public) unique properties to discover")
        return unique
    }

    private func discoverAllProperties() -> [UInt16: NikonDiscoveredProperty] {
        let propertyIds = querySupportedPropertyIds()
        var result: [UInt16: NikonDiscoveredProperty] = [:]
        for pid in propertyIds {
            if closing { break }
            if let prop = discoverSingleProperty(pid) {
                result[pid] = prop
            }
        }
        return result
    }

    private func discoverSingleProperty(_ propId: UInt16) -> NikonDiscoveredProperty? {
        let cmd = transport.buildCommand(code: PTP_CMD_GETPROPDESC, parameters: [UInt32(propId)])
        guard let (inData, rsp) = try? transport.sendPtpCommand(cmd) else { return nil }
        guard transport.responseCode(from: rsp) == PTP_RSP_OK, let data = inData else { return nil }
        return parsePropDesc(data)
    }

    private func parsePropDesc(_ data: Data) -> NikonDiscoveredProperty? {
        let p = PropParser(data)
        guard let propId   = p.readU16(),
              let dataType = p.readU16(),
              let rwFlag   = p.readU8() else { return nil }
        p.skip(type: dataType)                      // default value
        guard let currentValue = p.readNum(ofType: dataType) else { return nil }
        guard let formFlag = p.readU8() else { return nil }

        var enumValues: [NSNumber]?
        var rangeMin: NSNumber?
        var rangeMax: NSNumber?
        var rangeStep: NSNumber?

        if formFlag == 0x01 {
            rangeMin  = p.readNum(ofType: dataType)
            rangeMax  = p.readNum(ofType: dataType)
            rangeStep = p.readNum(ofType: dataType)
            // Synthesize enum values for writable range-form properties with ≤64 steps,
            // so the menu can show a submenu of choices rather than a non-interactive item.
            if rwFlag != 0, let mn = rangeMin, let mx = rangeMax, let st = rangeStep {
                let minD = mn.doubleValue; let maxD = mx.doubleValue; let stepD = st.doubleValue
                if stepD > 0 {
                    let count = Int((maxD - minD) / stepD) + 1
                    if count >= 2 && count <= 64 {
                        var synth: [NSNumber] = []
                        for i in 0..<count {
                            let v = minD + Double(i) * stepD
                            synth.append(NSNumber(value: v))
                        }
                        enumValues = synth
                    }
                }
            }
        } else if formFlag == 0x02 {
            guard let count = p.readU16() else { return nil }
            var values: [NSNumber] = []
            for _ in 0..<count {
                if let v = p.readNum(ofType: dataType) { values.append(v) }
            }
            enumValues = values
        }

        return NikonDiscoveredProperty(
            propertyId: propId, dataType: dataType, writable: rwFlag != 0,
            value: currentValue, enumValues: enumValues,
            rangeMin: rangeMin, rangeMax: rangeMax, rangeStep: rangeStep)
    }

    /// Set a camera property. Safe to call at any time, including during live view:
    /// the command is enqueued and executed between the next live view frame.
    func setProperty(propId: UInt16, value: UInt32, dataType: UInt16) {
        pendingLock.lock()
        pendingSets.append(PendingSet(propId: propId, value: value, dataType: dataType))
        pendingLock.unlock()
        // If not in the live view loop the queue is idle — dispatch an explicit drain.
        queue.async { [weak self] in self?.drainPendingSets() }
    }

    /// Execute all queued property-set commands. Called on the camera queue.
    private func drainPendingSets() {
        pendingLock.lock()
        let cmds = pendingSets
        pendingSets.removeAll()
        pendingLock.unlock()

        for cmd in cmds {
            guard sessionOpen else { break }
            var outData = Data()
            // cmd.value carries the bit pattern; for signed types reinterpret as signed
            // before re-encoding so negative values round-trip correctly.
            switch cmd.dataType {
            case 1:  outData.appendLE(UInt8(bitPattern: Int8(bitPattern: UInt8(cmd.value & 0xFF))))
            case 2:  outData.appendLE(UInt8(cmd.value & 0xFF))
            case 3:  outData.appendLE(UInt16(bitPattern: Int16(bitPattern: UInt16(cmd.value & 0xFFFF))))
            case 4:  outData.appendLE(UInt16(cmd.value & 0xFFFF))
            case 5:  outData.appendLE(cmd.value)   // Int32 bit-pattern already in UInt32
            case 6:  outData.appendLE(cmd.value)
            default: outData.appendLE(UInt16(cmd.value & 0xFFFF))
            }
            let ptpCmd = transport.buildCommand(code: PTP_CMD_SETPROPVAL, parameters: [UInt32(cmd.propId)])
            do {
                let (_, rsp) = try transport.sendPtpCommand(ptpCmd, outData: outData)
                let code = transport.responseCode(from: rsp)
                cameraLog.fault("UsbNikonCamera: setProperty 0x\(String(cmd.propId, radix:16), privacy: .public) = \(cmd.value, privacy: .public) → 0x\(String(code, radix:16), privacy: .public)")
                if code == PTP_RSP_OK, let updated = discoverSingleProperty(cmd.propId) {
                    onPropertiesDiscovered?([cmd.propId: updated])
                }
            } catch {
                cameraLog.fault("UsbNikonCamera: setProperty error: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func runCleanUp() {
        if sessionOpen {
            _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_NIKON_STOPLIVEVIEW))
            _ = try? transport.sendPtpCommand(transport.buildCommand(code: PTP_CMD_CLOSESESSION))
            sessionOpen = false
            cameraLog.fault("UsbNikonCamera: session closed")
        }
        transport.close()
        cameraLog.fault("UsbNikonCamera: transport closed")
    }

    // MARK: - JPEG extraction

    /// Finds the last SOI…EOI region in the live view data blob.
    private func extractJpeg(from data: Data) -> Data? {
        let soi = Data([0xFF, 0xD8])
        let eoi = Data([0xFF, 0xD9])

        var lastSoi: Data.Index? = nil
        var search = data.startIndex
        while let r = data.range(of: soi, in: search ..< data.endIndex) {
            lastSoi = r.lowerBound
            search  = r.upperBound
        }
        guard let start = lastSoi else { return nil }
        let afterSoi = data.index(start, offsetBy: 2)
        guard afterSoi < data.endIndex else { return nil }
        guard let eoiRange = data.range(of: eoi, in: afterSoi ..< data.endIndex) else { return nil }
        return data[start ..< eoiRange.upperBound]
    }
}

// MARK: - JPEG → CVPixelBuffer

/// Decode JPEG into a 32-BGRA CVPixelBuffer at the JPEG's native dimensions.
/// No scaling or stretching — aspect ratio is preserved exactly.
func jpegToPixelBuffer(_ jpegData: Data) -> CVPixelBuffer? {
    guard let src = CGImageSourceCreateWithData(jpegData as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

    let width = cgImage.width
    let height = cgImage.height

    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ]
    CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        kCVPixelFormatType_32BGRA,
                        attrs as CFDictionary, &pb)
    guard let pixelBuffer = pb else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let ctx = CGContext(
        data:              CVPixelBufferGetBaseAddress(pixelBuffer),
        width:             width,
        height:            height,
        bitsPerComponent:  8,
        bytesPerRow:       CVPixelBufferGetBytesPerRow(pixelBuffer),
        space:             CGColorSpaceCreateDeviceRGB(),
        bitmapInfo:        CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }

    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixelBuffer
}

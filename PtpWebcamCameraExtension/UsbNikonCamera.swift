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

private let PTP_CMD_NIKON_GETVENDORPROPS:    UInt16 = 0x90CA
private let PTP_CMD_NIKON_CHANGECAMERAMODE:  UInt16 = 0x90C2  // param 0=PC camera, 1=remote/tethered
private let PTP_CMD_NIKON_STARTLIVEVIEW:     UInt16 = 0x9201
private let PTP_CMD_NIKON_STOPLIVEVIEW:      UInt16 = 0x9202  // also called EndLiveView on Z-series
private let PTP_CMD_NIKON_GETLIVEVIEWIMG:    UInt16 = 0x9203  // compatibility; Z-series prefer 0x9428
private let PTP_CMD_NIKON_DEVICEREADY:       UInt16 = 0x90C8
private let PTP_CMD_NIKON_GETVENDORCODES:    UInt16 = 0x9439
private let PTP_CMD_NIKON_GETLIVEVIEWIMGEX:  UInt16 = 0x9428  // Z-series: LiveViewObject DataSet v2

private let PTP_RSP_NIKON_NOTLIVEVIEW:       UInt16 = 0xA00B

// Z-series live view status properties (not present on older bodies)
private let PTP_PROP_NIKON_CAMERA_LV_STATUS: UInt16 = 0xD1B8  // 0=off, 1=on
private let PTP_PROP_NIKON_LV_IMAGE_STATUS:  UInt16 = 0xD1BB  // 0=unavailable, 1=available

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
    // WB fine-tune sub-properties (shown as sub-menus under WB mode values)
    0xD017,  // WB Auto Tune
    0xD018,  // WB Incandescent Tune
    0xD019,  // WB Fluorescent Tune
    0xD01A,  // WB Sunny Tune
    0xD01B,  // WB Flash Tune
    0xD01C,  // WB Cloudy Tune
    0xD01D,  // WB Shade Tune
    0xD01E,  // WB Color Temperature (for Color Temp mode)
    0xD141,  // WB Auto Type
    0xD14F,  // WB Fluorescent Type
    0xD150,  // WB Color Temp Tune
]

// NikonDiscoveredProperty is now UsbCameraProperty (defined in UsbCameraProtocol.swift).
// PtpPropParser replaces PropParser (defined in UsbCameraProtocol.swift).

// MARK: - UsbNikonCamera

/// Manages a Nikon camera PTP session over a UsbPtpTransport.
/// All USB I/O runs on an internal serial DispatchQueue.
///
/// Lifecycle:
///   openSessionAndDiscover()  — call at camera connect time
///   startLiveView()           — call when CMIO streaming begins
///   stopLiveView()            — call when CMIO streaming stops (session stays open)
///   close()                   — call at camera disconnect (closes session + transport)
final class UsbNikonCamera: UsbCameraProtocol {

    private let transport: UsbPtpTransport
    private let headerLen: Int
    private let cameraLog = Logger(subsystem: "org.ptpwebcam.CameraExtension", category: "UsbNikonCamera")

    private let queue = DispatchQueue(label: "org.ptpwebcam.usbcamera", qos: .userInteractive)
    // stopLv: signals the live view loop to stop (session stays open).
    // closing: signals the camera is being torn down; suppresses redundant STOPLIVEVIEW in cleanUp.
    private var stopLv   = false
    private var closing  = false
    private var sessionOpen = false
    private var supportedOperations: Set<UInt16> = []
    // True for Z-series cameras that support GetLiveViewImageEx (0x9428).
    // Set after GetDeviceInfo; controls which LV command and header offset to use.
    private var usesLvEx = false

    // Pending property-set commands. Appended from any thread under pendingLock;
    // drained on the camera queue between live view frames (or immediately when not streaming).
    private struct PendingSet { let propId: UInt32; let value: UInt32; let dataType: UInt16 }
    private var pendingSets: [PendingSet] = []
    private let pendingLock = NSLock()

    // Called on queue — passes raw JPEG bytes from GETLIVEVIEWIMG.
    var onJpegFrame: ((Data) -> Void)?

    // Called on queue after property discovery completes (and after each setProperty).
    var onPropertiesDiscovered: (([UInt32: UsbCameraProperty]) -> Void)?

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

        var sessionOpenError: Error? = nil
        for attempt in 1...5 {
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
                sessionOpenError = nil
                cameraLog.fault("UsbNikonCamera: session opened (attempt \(attempt, privacy: .public))")
                break
            } catch {
                sessionOpenError = error
                if attempt < 5 {
                    cameraLog.fault("UsbNikonCamera: OPEN_SESSION attempt \(attempt, privacy: .public) failed: \(String(describing: error), privacy: .public) — retrying")
                    Thread.sleep(forTimeInterval: 0.5)
                    // Clear pipe stalls before retry — some cameras leave endpoints halted.
                    transport.clearStalls()
                }
            }
        }
        if let error = sessionOpenError {
            cameraLog.fault("UsbNikonCamera: OPEN_SESSION error: \(String(describing: error), privacy: .public)")
            return
        }

        if closing { return }

        let discovered = discoverAllProperties()
        if !discovered.isEmpty {
            cameraLog.fault("UsbNikonCamera: discovered \(discovered.count, privacy: .public) properties")
            onPropertiesDiscovered?(discovered)  // keys are UInt32
        }
    }

    // MARK: - Phase 2: Live view loop (runs on queue, queued after phase 1)

    private func runLiveViewPhase() {
        guard sessionOpen && !closing else {
            cameraLog.fault("UsbNikonCamera: startLiveView called but session not ready (open=\(self.sessionOpen, privacy: .public) closing=\(self.closing, privacy: .public))")
            return
        }

        // ── Pre-flight: switch to remote/tethered mode if supported ──────────
        // Z-series cameras start in PC camera mode (upload priority) by default.
        // ChangeCameraMode(1) switches to remote mode, enabling live view.
        if supportedOperations.contains(PTP_CMD_NIKON_CHANGECAMERAMODE) {
            cameraLog.fault("UsbNikonCamera: issuing ChangeCameraMode(1) — remote/tethered mode")
            let modeCmd = transport.buildCommand(code: PTP_CMD_NIKON_CHANGECAMERAMODE, parameters: [1])
            _ = try? transport.sendPtpCommand(modeCmd)
            Thread.sleep(forTimeInterval: 0.3)
        }
        if let prohibit = discoverSingleProperty(0xD1A4) {
            let bits = prohibit.value.uint32Value
            if bits != 0 {
                cameraLog.fault("UsbNikonCamera: LV prohibit condition 0xD1A4 = 0x\(String(bits, radix:16), privacy: .public)")
            }
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
        // Z-series cameras use GetLiveViewImageEx (0x9428) with a 1024-byte header.
        // Older bodies use GetLiveViewImage (0x9203) with a product-ID-specific header.
        let lvCmd = usesLvEx ? PTP_CMD_NIKON_GETLIVEVIEWIMGEX : PTP_CMD_NIKON_GETLIVEVIEWIMG
        let lvHeaderLen = usesLvEx ? 1024 : headerLen
        cameraLog.fault("UsbNikonCamera: entering live view loop (cmd=0x\(String(lvCmd, radix:16), privacy: .public) headerLen=\(lvHeaderLen, privacy: .public))")
        let targetInterval: TimeInterval = 1.0 / 30.0
        var frameCount = 0
        var pollCounter = 0
        var notLiveViewCount = 0

        while !stopLv && !closing {
            autoreleasepool {
                // Execute any queued property-set commands before the next frame.
                drainPendingSets()
                guard !stopLv && !closing else { return }

                // Poll interrupt-IN for PTP_EVENT_DEVICEPROPCHANGED events every ~5 frames.
                pollCounter += 1
                if pollCounter % 5 == 0 { pollInterruptEvents() }

                let frameStart = Date()

                do {
                    let cmd = transport.buildCommand(code: lvCmd)
                    let (inData, rsp) = try transport.sendPtpCommand(cmd)
                    let rspCode = transport.responseCode(from: rsp)

                    if rspCode == PTP_RSP_NIKON_NOTLIVEVIEW {
                        notLiveViewCount += 1
                        if notLiveViewCount > 20 {
                            cameraLog.fault("UsbNikonCamera: NOTLIVEVIEW after \(notLiveViewCount, privacy: .public) restarts — giving up")
                            stopLv = true
                            return
                        }
                        cameraLog.fault("UsbNikonCamera: NOTLIVEVIEW — restarting (\(notLiveViewCount, privacy: .public))")
                        restartLiveView()
                        return  // next iteration will retry
                    }

                    if let data = inData, data.count > lvHeaderLen {
                        if let jpeg = extractJpegFromLiveViewData(data) {
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
                        cameraLog.fault("UsbNikonCamera: frame too small (\(data.count, privacy: .public)B, lvHeaderLen=\(lvHeaderLen, privacy: .public))")
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

        let p = PtpPropParser(data)
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
        supportedOperations = supportedOps
        usesLvEx = supportedOps.contains(PTP_CMD_NIKON_GETLIVEVIEWIMGEX)
        var allProps = props
        cameraLog.fault("UsbNikonCamera: GetDeviceInfo — \(props.count, privacy: .public) standard props, \(ops.count, privacy: .public) ops, usesLvEx=\(self.usesLvEx, privacy: .public)")

        // Nikon GetVendorProps / GetVendorCodes adds properties not in standard DeviceInfo.
        if supportedOps.contains(PTP_CMD_NIKON_GETVENDORPROPS) {
            let vcmd = transport.buildCommand(code: PTP_CMD_NIKON_GETVENDORPROPS)
            if let (vData, vRsp) = try? transport.sendPtpCommand(vcmd),
               transport.responseCode(from: vRsp) == PTP_RSP_OK,
               let vd = vData, vd.count >= 4 {
                let vp = PtpPropParser(vd)
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
                let vp = PtpPropParser(vd)
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

    private func discoverAllProperties() -> [UInt32: UsbCameraProperty] {
        let propertyIds = querySupportedPropertyIds()
        var result: [UInt32: UsbCameraProperty] = [:]
        for pid in propertyIds {
            if closing { break }
            if let prop = discoverSingleProperty(pid) {
                result[UInt32(pid)] = prop
            }
        }
        return result
    }

    private func discoverSingleProperty(_ propId: UInt16) -> UsbCameraProperty? {
        let cmd = transport.buildCommand(code: PTP_CMD_GETPROPDESC, parameters: [UInt32(propId)])
        guard let (inData, rsp) = try? transport.sendPtpCommand(cmd) else {
            cameraLog.fault("UsbNikonCamera: GetDevicePropDesc 0x\(String(propId, radix:16), privacy: .public) — transport error")
            return nil
        }
        let code = transport.responseCode(from: rsp)
        guard code == PTP_RSP_OK, let data = inData else {
            cameraLog.fault("UsbNikonCamera: GetDevicePropDesc 0x\(String(propId, radix:16), privacy: .public) — rsp=0x\(String(code, radix:16), privacy: .public) inData=\(inData != nil, privacy: .public)")
            return nil
        }
        guard let prop = PtpPropParser(data).parsePropDesc() else {
            cameraLog.fault("UsbNikonCamera: GetDevicePropDesc 0x\(String(propId, radix:16), privacy: .public) — parsePropDesc returned nil (dataLen=\(data.count, privacy: .public))")
            return nil
        }
        return prop
    }

    private func setPropertyDirect(propId: UInt16, value: UInt32, dataType: UInt16) {
        var outData = Data()
        switch dataType {
        case 1:  outData.appendLE(UInt8(bitPattern: Int8(bitPattern: UInt8(value & 0xFF))))
        case 2:  outData.appendLE(UInt8(value & 0xFF))
        case 3:  outData.appendLE(UInt16(bitPattern: Int16(bitPattern: UInt16(value & 0xFFFF))))
        case 4:  outData.appendLE(UInt16(value & 0xFFFF))
        case 5, 6: outData.appendLE(value)
        default: outData.appendLE(UInt16(value & 0xFFFF))
        }
        let cmd = transport.buildCommand(code: PTP_CMD_SETPROPVAL, parameters: [UInt32(propId)])
        _ = try? transport.sendPtpCommand(cmd, outData: outData)
    }

    func setProperty(propId: UInt32, value: UInt32, dataType: UInt16) {
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
            let ptpCmd = transport.buildCommand(code: PTP_CMD_SETPROPVAL, parameters: [cmd.propId])
            do {
                let (_, rsp) = try transport.sendPtpCommand(ptpCmd, outData: outData)
                let code = transport.responseCode(from: rsp)
                cameraLog.fault("UsbNikonCamera: setProperty 0x\(String(cmd.propId, radix:16), privacy: .public) = \(cmd.value, privacy: .public) → 0x\(String(code, radix:16), privacy: .public)")
                let propId16 = UInt16(cmd.propId & 0xFFFF)
                if code == PTP_RSP_OK, let updated = discoverSingleProperty(propId16) {
                    onPropertiesDiscovered?([cmd.propId: updated])
                }
            } catch {
                cameraLog.fault("UsbNikonCamera: setProperty error: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Interrupt event polling (Nikon DEVICEPROPCHANGED)

    private func pollInterruptEvents() {
        while let eventData = transport.readInterruptEvent(timeout: 0.01) {
            guard eventData.count >= 16 else { continue }
            let eventCode = eventData.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }
            guard eventCode == 0x4006 else { continue }  // PTP_EVENT_DEVICEPROPCHANGED
            let propId16 = eventData.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt16.self) }
            cameraLog.fault("UsbNikonCamera: DEVICEPROPCHANGED 0x\(String(propId16, radix:16), privacy: .public)")
            if let prop = discoverSingleProperty(propId16) {
                onPropertiesDiscovered?([UInt32(propId16): prop])
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

}

// MARK: - JPEG → CVPixelBuffer

/// Decode JPEG into a 32-BGRA CVPixelBuffer at the JPEG's native dimensions.
/// No scaling or stretching — aspect ratio is preserved exactly.
/// Decode a JPEG into a pre-allocated CVPixelBuffer (pool-allocated, any size).
/// CG scales the image to fill the buffer dimensions.
/// Must be called inside an autoreleasepool to ensure CG objects are released promptly.
func jpegIntoPixelBuffer(_ jpegData: Data) -> CVPixelBuffer? {
    // Disable ImageIO's global decoded-pixel cache. Without this every frame's
    // decoded image data is retained in a process-wide cache and memory grows
    // continuously at ~30 fps. kCGImageSourceShouldCache controls the source-level
    // cache; kCGImageSourceShouldCacheImmediately controls the per-image cache.
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

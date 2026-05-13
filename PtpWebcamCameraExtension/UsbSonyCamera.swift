// UsbSonyCamera.swift
// Sony Alpha PTP session running directly over USB inside the CMIO extension.

import Foundation
import os.log

// MARK: - Sony PTP Constants

private let PTP_CMD_GETOBJECT:             UInt16 = 0x1009

private let PTP_CMD_SONY_CONNECT:          UInt16 = 0x9201
private let PTP_CMD_SONY_GETPROPERTIES:    UInt16 = 0x9202
private let PTP_CMD_SONY_GETPROPDESC:      UInt16 = 0x9203
private let PTP_CMD_SONY_SETPROPABS:       UInt16 = 0x9205
private let PTP_CMD_SONY_SETPROPSTEP:      UInt16 = 0x9207
private let PTP_CMD_SONY_GETALLPROPDATA:   UInt16 = 0x9209

private let SONY_GETALLPROPS_MAGICNUMBER:  UInt32 = 0xC8
private let SONY_LV_IMAGE_OBJECTID:        UInt32 = 0xFFFFC002

private let PTP_EVENT_SONY_PROPVALCHANGED: UInt16 = 0xC203

// MARK: - UsbSonyCamera

final class UsbSonyCamera: UsbPtpCameraBase {

    init(transport: UsbPtpTransport) {
        super.init(transport: transport, logTag: "UsbSonyCamera")
        // Sony's PTP firmware reacts badly to CLEAR_FEATURE(ENDPOINT_HALT) on
        // idle endpoints and can silently drop the session afterwards.
        clearStallsOnSessionRetry = false
    }

    // MARK: - Pre-OPEN_SESSION drain
    //
    // Sony cameras can leave stale bytes on bulk-IN after a previous owner
    // (ptpcamerad, an aborted session, etc.) disconnects. If those bytes are
    // still queued when we send OPEN_SESSION, the transport reads them as the
    // response and either parses garbage or times out. The drain must happen
    // before OPEN_SESSION, not after.
    override func preSessionOpenSetup() {
        _ = transport.drainBulkIn(timeout: 0.05)
    }

    // MARK: - Vendor connect
    //
    // Sony SDIO handshake — single-parameter form, matching the original
    // PtpCameraSony.swift in the agent (which worked via ImageCapture):
    //   1. SDIOConnect(1)
    //   2. SDIOConnect(2)
    //   3. GetProperties(0xC8)   [opcode 0x9202; returns list of supported prop codes]
    //   4. SDIOConnect(3)
    //   5. GetAllDevicePropData  ← descriptors + initial values (in discoverAllProperties)
    //
    // The three-parameter form (1,0,0) / (2,0xC8,0xC8) / (3,0xC8,0xC8) is what
    // libgphoto2 uses for newer Sony bodies but causes the A7's first
    // GetAllPropData to time out, which corrupts the bulk-IN pipe and the
    // camera ends up USB-resetting.

    override func performVendorConnect() {
        parseDeviceInfo()  // populates supportedOps and standardPropertyIds

        let hasConnect    = supportedOps.contains(PTP_CMD_SONY_CONNECT)
        let hasProperties = supportedOps.contains(PTP_CMD_SONY_GETPROPERTIES)
        let hasAllPropDat = supportedOps.contains(PTP_CMD_SONY_GETALLPROPDATA)
        let hasPropDesc   = supportedOps.contains(PTP_CMD_SONY_GETPROPDESC)
        let hasStdPropDesc = supportedOps.contains(PTP_CMD_GETPROPDESC)
        cameraLog.fault("Sony ops: connect=\(hasConnect, privacy: .public) getProperties=\(hasProperties, privacy: .public) getAllPropData=\(hasAllPropDat, privacy: .public) sonyGetPropDesc=\(hasPropDesc, privacy: .public) stdGetPropDesc=\(hasStdPropDesc, privacy: .public)")

        // BEFORE the Sony Connect handshake, query each standard property
        // individually via the standard PTP GetDevicePropDesc (0x1014).
        // On a fresh session the Sony A7 responds with real CurrentValues to
        // these queries; once we enter tethered mode (Connect(1)+) it returns
        // zeros for the same properties. This mirrors how the DAL plugin's
        // `deviceInfoReceived()` calls `queryPropertyDescription(propId)` for
        // each `supportedProperties` entry before sending Connect.
        if hasStdPropDesc && !standardPropertyIds.isEmpty {
            var fetched = 0
            for pid16 in standardPropertyIds {
                if closing { break }
                if let prop = getDevicePropDesc(UInt32(pid16)) {
                    discoveredProperties[UInt32(pid16)] = prop
                    fetched += 1
                }
            }
            cameraLog.fault("Sony pre-connect prop fetch: \(fetched, privacy: .public)/\(self.standardPropertyIds.count, privacy: .public) standard properties")
        }

        guard hasConnect else {
            cameraLog.fault("Sony connect op (0x9201) missing — supportedOps=\(self.supportedOps.map { String($0, radix:16) }.joined(separator: ","), privacy: .public)")
            return
        }

        runSonyConnect(params: [1])
        Thread.sleep(forTimeInterval: 0.1)
        runSonyConnect(params: [2])
        Thread.sleep(forTimeInterval: 0.1)

        if hasProperties {
            let rsp = sendPtp(PTP_CMD_SONY_GETPROPERTIES, params: [SONY_GETALLPROPS_MAGICNUMBER])
            cameraLog.fault("Sony GetProperties(0xC8) → 0x\(String(rsp, radix:16), privacy: .public)")
            Thread.sleep(forTimeInterval: 0.1)
        }

        runSonyConnect(params: [3])
        Thread.sleep(forTimeInterval: 0.2)
    }

    @discardableResult
    private func runSonyConnect(params: [UInt32]) -> UInt16 {
        let rsp = sendPtp(PTP_CMD_SONY_CONNECT, params: params)
        cameraLog.fault("Sony SDIOConnect(\(params.map(String.init).joined(separator: ","), privacy: .public)) → 0x\(String(rsp, radix:16), privacy: .public)")
        return rsp
    }

    /// Send a PTP command, ignoring data, returning the response code (or 0xFFFF on transport error).
    private func sendPtp(_ code: UInt16, params: [UInt32] = []) -> UInt16 {
        guard let (_, rsp) = try? transport.sendPtpCommand(transport.buildCommand(code: code, parameters: params)) else {
            return 0xFFFF
        }
        return transport.responseCode(from: rsp)
    }

    /// Issue GetAllDevicePropData, log the result, and merge any parsed properties
    /// into `discoveredProperties`. Returns the parsed count.
    @discardableResult
    private func fetchAndParseAllPropData(label: String) -> Int {
        do {
            let (inData, rsp) = try transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_SONY_GETALLPROPDATA))
            let code = transport.responseCode(from: rsp)
            let len = inData?.count ?? -1
            cameraLog.fault("GetAllPropData [\(label, privacy: .public)] → 0x\(String(code, radix:16), privacy: .public) len=\(len, privacy: .public)")
            guard code == PTP_RSP_OK, let data = inData, data.count > 8 else { return 0 }
            let parsed = parseSonyAllPropertyDataResponse(data, publish: false)
            return parsed.count
        } catch {
            cameraLog.fault("GetAllPropData [\(label, privacy: .public)] threw: \(String(describing: error), privacy: .public)")
            // A bulk-IN timeout leaves the transport with potentially queued bytes
            // that would corrupt the next command. Drain before continuing so
            // subsequent SDIOConnect / GetAllPropData calls don't fail with 0xffff
            // (which would cause the camera to USB-reset).
            _ = transport.drainBulkIn(timeout: 0.3)
            return 0
        }
    }

    // MARK: - Property discovery

    override func discoverAllProperties() -> [UInt32: UsbCameraProperty] {
        guard supportedOps.contains(PTP_CMD_SONY_GETALLPROPDATA) else {
            cameraLog.fault("GetAllPropData (0x9209) not in supportedOps — no discovery")
            return [:]
        }
        // After SDIOConnect(3), poll GetAllPropData until a non-empty descriptor
        // list arrives. The camera may take a few polls to start responding with
        // real data — early polls return an 8-byte header-only stub.
        for attempt in 1...30 {
            if closing { break }
            let count = fetchAndParseAllPropData(label: "poll #\(attempt)")
            if count > 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        cameraLog.fault("Sony bulk descriptor pass: \(self.discoveredProperties.count, privacy: .public) properties")

        // Drain initial PROPVALCHANGED events. The Sony A7 emits its real
        // property values via these events shortly after SDIOConnect(3) — the
        // bulk GetAllPropData response only contains descriptor structure.
        // Without draining now, these initial events are lost (pollEvents only
        // runs during live view).
        drainPropertyChangeEvents(durationSeconds: 2.0)
        logKeyPropertyValues()
        return discoveredProperties
    }

    /// Poll the interrupt-IN endpoint for PROPVALCHANGED events for up to
    /// `durationSeconds`, exiting early if a full cycle yields no new events.
    /// For each event, fetch the changed property via GetDevicePropDesc (0x9203).
    private func drainPropertyChangeEvents(durationSeconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(durationSeconds)
        var totalEvents = 0
        var refreshes = 0
        var idleCycles = 0
        while Date() < deadline && !closing {
            var got = false
            while let eventData = transport.readInterruptEvent(timeout: 0.05) {
                got = true
                guard eventData.count >= 16 else { continue }
                let eventCode = eventData.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }
                guard eventCode == PTP_EVENT_SONY_PROPVALCHANGED else { continue }
                let propId = UInt32(eventData.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt16.self) })
                totalEvents += 1
                if let (inData, rsp) = try? transport.sendPtpCommand(
                    transport.buildCommand(code: PTP_CMD_SONY_GETPROPDESC, parameters: [propId])),
                   transport.responseCode(from: rsp) == PTP_RSP_OK, let data = inData {
                    parseSonyPropDescResponse(data, publish: false)
                    refreshes += 1
                }
            }
            if got {
                idleCycles = 0
            } else {
                idleCycles += 1
                if idleCycles >= 3 { break }   // 3 × 50ms = 150ms quiet → done
            }
        }
        cameraLog.fault("Sony initial event drain: events=\(totalEvents, privacy: .public) refreshed=\(refreshes, privacy: .public)")
    }

    /// Dump every discovered property with id, dataType, value, writable, and
    /// incremental/button flags. Used to diagnose "can't set property" bugs.
    private func logKeyPropertyValues() {
        let sorted = discoveredProperties.keys.sorted()
        var chunk: [String] = []
        for id in sorted {
            guard let p = discoveredProperties[id] else { continue }
            let flags = "\(p.writable ? "W" : "-")\(p.incremental ? "I" : "-")\(p.isButton ? "B" : "-")"
            chunk.append(String(format: "0x%04x(dt%d,%@)=%@", id, p.dataType, flags, "\(p.value)"))
            if chunk.count == 6 {
                cameraLog.fault("Sony props: \(chunk.joined(separator: " "), privacy: .public)")
                chunk.removeAll()
            }
        }
        if !chunk.isEmpty {
            cameraLog.fault("Sony props: \(chunk.joined(separator: " "), privacy: .public)")
        }
    }

    // MARK: - Frame fetch (Sony has no STARTLIVEVIEW — just GetObject in a loop)

    override func fetchOneFrame() throws -> Data? {
        let cmd = transport.buildCommand(code: PTP_CMD_GETOBJECT, parameters: [SONY_LV_IMAGE_OBJECTID])
        let (inData, rsp) = try transport.sendPtpCommand(cmd)
        let code = transport.responseCode(from: rsp)

        if code == PTP_RSP_DEVICEBUSY {
            Thread.sleep(forTimeInterval: 0.033)
            return nil
        }

        if let data = inData, let jpeg = extractJpegFromLiveViewData(data) {
            return jpeg
        }
        return nil
    }

    // MARK: - Event polling

    override func pollEvents() {
        while let eventData = transport.readInterruptEvent(timeout: 0.01) {
            guard eventData.count >= 16 else { continue }
            let eventCode = eventData.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }
            cameraLog.fault("Sony event 0x\(String(eventCode, radix:16), privacy: .public) raw=\(eventData.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public)")
            guard eventCode == PTP_EVENT_SONY_PROPVALCHANGED else { continue }
            let propId = UInt32(eventData.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt16.self) })
            do {
                let (inData, rsp) = try transport.sendPtpCommand(
                    transport.buildCommand(code: PTP_CMD_SONY_GETPROPDESC, parameters: [propId]))
                let code = transport.responseCode(from: rsp)
                cameraLog.fault("PROPVALCHANGED 0x\(String(propId, radix:16), privacy: .public) → GetPropDesc 0x\(String(code, radix:16), privacy: .public) len=\(inData?.count ?? -1, privacy: .public)")
                if code == PTP_RSP_OK, let data = inData {
                    parseSonyPropDescResponse(data)
                }
            } catch {
                cameraLog.fault("PROPVALCHANGED 0x\(String(propId, radix:16), privacy: .public) → GetPropDesc threw: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Sony property parsing
    //
    // Sony 0x9203 GetPropDesc and 0x9209 GetAllPropData return the same extended
    // format with an extra `flags` byte before `readwrite`:
    //   propId(2) | dataType(2) | flags(1) | readwrite(1) | default(N) | current(N) | formFlag(1) | [form]
    // Standard PTP `parsePropDesc()` omits the flags byte and misaligns everything.

    @discardableResult
    /// Parse a Sony GetAllPropData response.
    /// - parameter publish: emit `onPropertiesDiscovered` for changed entries.
    /// - parameter mergePreserveZeros: when true (default), if the camera reports
    ///   `CurrentValue=0` for a property whose cached value is non-zero, keep the
    ///   cached value rather than overwriting (protects real values from
    ///   placeholder zeros during init). Set false when called right after a
    ///   set, so the camera's actual response wins.
    /// - parameter propIdToTrust: if set, this property's value is always
    ///   accepted from the response even if `mergePreserveZeros` is true.
    private func parseSonyAllPropertyDataResponse(
        _ data: Data,
        publish: Bool = true,
        mergePreserveZeros: Bool = true,
        propIdToTrust: UInt32? = nil
    ) -> [UInt32: UsbCameraProperty] {
        guard data.count > 8 else { return [:] }
        let p = PtpPropParser(data.subdata(in: 8 ..< data.count))
        var changed: [UInt32: UsbCameraProperty] = [:]

        while p.remaining > 0 {
            guard let propId16  = p.readU16(),
                  let dataType  = p.readU16(),
                  let flags     = p.readU8(),
                  let readwrite = p.readU8(),
                  let _         = p.readNum(ofType: dataType),  // default value (skip)
                  let current   = p.readNum(ofType: dataType),
                  let formFlag  = p.readU8() else { break }

            let propId      = UInt32(propId16)
            let incremental = (flags & 0x01) == 0
            let isButton    = (flags & 0x80) != 0
            // Sony uses byte 5 as a multi-state writable indicator:
            //   0 = read-only, 1 = read-write via SetPropAbs, 2 = writable in
            //   only some modes / via SetPropStep. Treat anything non-zero as
            //   writable so the agent menu exposes the item as clickable; the
            //   actual set path (SetPropAbs vs SetPropStep) is chosen by the
            //   `incremental`/`isButton` flags below.
            let writable    = readwrite != 0

            var enumValues: [NSNumber]?
            var rangeMin, rangeMax, rangeStep: NSNumber?

            switch formFlag {
            case 0x01:
                rangeMin  = p.readNum(ofType: dataType)
                rangeMax  = p.readNum(ofType: dataType)
                rangeStep = p.readNum(ofType: dataType)
            case 0x02:
                if let count = p.readU16() {
                    var vals: [NSNumber] = []
                    for _ in 0..<count {
                        if let v = p.readNum(ofType: dataType) { vals.append(v) }
                    }
                    enumValues = vals
                }
            default: break
            }

            let prop = UsbCameraProperty(
                propertyId: propId, dataType: dataType, writable: writable,
                value: current, enumValues: enumValues,
                rangeMin: rangeMin, rangeMax: rangeMax, rangeStep: rangeStep,
                incremental: incremental, isButton: isButton)
            // Don't overwrite a previously-fetched property if the new value is
            // 0 and the old one was non-zero. The post-connect bulk dump
            // contains placeholder zeros for many properties that the
            // pre-connect 0x1014 fetch returned with real values.
            //   `mergePreserveZeros = false` disables this protection entirely
            //   (e.g. right after a set, where the camera's truth wins).
            //   `propIdToTrust == propId` likewise: that one specific property
            //   accepts the camera's value verbatim.
            let trustThis = !mergePreserveZeros || propIdToTrust == propId
            if !trustThis,
               let existing = discoveredProperties[propId],
               current.intValue == 0, existing.value.intValue != 0 {
                // Keep existing value but update other descriptor fields.
                let merged = UsbCameraProperty(
                    propertyId: propId, dataType: dataType, writable: writable,
                    value: existing.value,
                    enumValues: enumValues ?? existing.enumValues,
                    rangeMin: rangeMin ?? existing.rangeMin,
                    rangeMax: rangeMax ?? existing.rangeMax,
                    rangeStep: rangeStep ?? existing.rangeStep,
                    incremental: incremental, isButton: isButton)
                discoveredProperties[propId] = merged
                changed[propId] = merged
            } else {
                discoveredProperties[propId] = prop
                changed[propId] = prop
            }
        }

        if publish && !changed.isEmpty {
            onPropertiesDiscovered?(changed)
        }
        return changed
    }

    private func parseSonyPropDescResponse(_ data: Data, publish: Bool = true) {
        let p = PtpPropParser(data)
        guard let propId16  = p.readU16(),
              let dataType  = p.readU16(),
              let flags     = p.readU8(),
              let readwrite = p.readU8(),
              let _         = p.readNum(ofType: dataType),
              let current   = p.readNum(ofType: dataType),
              let formFlag  = p.readU8() else {
            cameraLog.fault("parseSonyPropDescResponse — failed to parse header (dataLen=\(data.count, privacy: .public))")
            return
        }

        let propId      = UInt32(propId16)
        let incremental = discoveredProperties[propId]?.incremental ?? ((flags & 0x01) == 0)
        let isButton    = discoveredProperties[propId]?.isButton    ?? ((flags & 0x80) != 0)
        let writable    = readwrite == 1

        var enumValues: [NSNumber]?
        var rangeMin, rangeMax, rangeStep: NSNumber?

        switch formFlag {
        case 0x01:
            rangeMin  = p.readNum(ofType: dataType)
            rangeMax  = p.readNum(ofType: dataType)
            rangeStep = p.readNum(ofType: dataType)
        case 0x02:
            if let count = p.readU16() {
                var vals: [NSNumber] = []
                for _ in 0..<count {
                    if let v = p.readNum(ofType: dataType) { vals.append(v) }
                }
                enumValues = vals
            }
        default: break
        }

        let updated = UsbCameraProperty(
            propertyId: propId, dataType: dataType, writable: writable,
            value: current, enumValues: enumValues,
            rangeMin: rangeMin, rangeMax: rangeMax, rangeStep: rangeStep,
            incremental: incremental, isButton: isButton)
        discoveredProperties[propId] = updated
        if publish {
            cameraLog.fault("parseSonyPropDescResponse 0x\(String(propId, radix:16), privacy: .public) value=\(current, privacy: .public)")
            onPropertiesDiscovered?([propId: updated])
        }
    }

    // MARK: - Autofocus

    /// Sony AF trigger is a "button" property at 0xD2C1. Button properties on
    /// Sony cameras are written via `SetPropStep` (0x9207) with the raw value
    /// encoded as a 4-byte Int32 step — NOT via SetPropAbs. The DAL plugin's
    /// `incrementProperty(_:by:)` always used 4-byte Int32, and so does our
    /// `performPropertySet` button branch.
    override func performAutofocus() {
        guard sessionOpen else { return }
        let propId: UInt32 = 0xD2C1
        sendSonyButtonStep(propId: propId, step: 2)   // press
        Thread.sleep(forTimeInterval: 0.2)
        sendSonyButtonStep(propId: propId, step: 1)   // release
        cameraLog.fault("Sony AF trigger (0xD2C1 step 2 → 1)")
    }

    private func sendSonyButtonStep(propId: UInt32, step: Int32) {
        var s = step
        let cmd = transport.buildCommand(code: PTP_CMD_SONY_SETPROPSTEP, parameters: [propId])
        _ = try? transport.sendPtpCommand(cmd, outData: Data(bytes: &s, count: 4))
    }

    // MARK: - Property set

    override func performPropertySet(_ pending: PendingSet) {
        let existing = discoveredProperties[pending.propId]
        let hexId = String(pending.propId, radix: 16)
        var usedStep = false
        var setSucceeded = false

        if existing?.isButton == true {
            // Sony SetPropStep payload is Int32 (4 bytes), matching the working
            // DAL plugin's `incrementProperty(_:by:)`.
            var inc = Int32(bitPattern: pending.value)
            let cmd = transport.buildCommand(code: PTP_CMD_SONY_SETPROPSTEP, parameters: [pending.propId])
            if let (_, rsp) = try? transport.sendPtpCommand(cmd, outData: Data(bytes: &inc, count: 4)) {
                setSucceeded = transport.responseCode(from: rsp) == PTP_RSP_OK
            }
            cameraLog.fault("SetPropStep(button) 0x\(hexId, privacy: .public) inc=\(inc, privacy: .public) ok=\(setSucceeded, privacy: .public)")
            usedStep = true

        } else if existing?.incremental == true, let enumValues = existing?.enumValues {
            let targetVal = NSNumber(value: pending.value)
            let cur = existing!.value
            if let oldIdx = enumValues.firstIndex(of: cur),
               let newIdx = enumValues.firstIndex(of: targetVal) {
                var step = Int32(newIdx - oldIdx)
                let cmd = transport.buildCommand(code: PTP_CMD_SONY_SETPROPSTEP, parameters: [pending.propId])
                if let (_, rsp) = try? transport.sendPtpCommand(cmd, outData: Data(bytes: &step, count: 4)) {
                    setSucceeded = transport.responseCode(from: rsp) == PTP_RSP_OK
                }
                cameraLog.fault("SetPropStep 0x\(hexId, privacy: .public) \(cur, privacy: .public)→\(pending.value, privacy: .public) step=\(step, privacy: .public) ok=\(setSucceeded, privacy: .public)")
                usedStep = true
            } else {
                cameraLog.fault("SetPropStep 0x\(hexId, privacy: .public) — enum index not found cur=\(cur, privacy: .public) target=\(pending.value, privacy: .public) enumCount=\(enumValues.count, privacy: .public)")
            }

        } else {
            let outData = Self.encodeLE(value: pending.value, dataType: pending.dataType)
            let cmd = transport.buildCommand(code: PTP_CMD_SONY_SETPROPABS, parameters: [pending.propId])
            if let (_, rsp) = try? transport.sendPtpCommand(cmd, outData: outData) {
                let code = transport.responseCode(from: rsp)
                setSucceeded = code == PTP_RSP_OK
                cameraLog.fault("SetPropAbs 0x\(hexId, privacy: .public)=\(pending.value, privacy: .public) → 0x\(String(code, radix:16), privacy: .public)")
            }
        }

        // Optimistic update only for SetPropAbs paths (where the camera goes
        // EXACTLY to `pending.value`). For SetPropStep, the actual landing
        // value depends on the camera's real current value — which can differ
        // from our cached one — so optimistically claiming we hit the target
        // produces incorrect menu state. The GetAllPropData refresh below will
        // catch the real value if the camera reports it.
        if setSucceeded && !usedStep, let oldProp = discoveredProperties[pending.propId] {
            let newValue = NSNumber(value: pending.value)
            let updated = UsbCameraProperty(
                propertyId: oldProp.propertyId, dataType: oldProp.dataType, writable: oldProp.writable,
                value: newValue, enumValues: oldProp.enumValues,
                rangeMin: oldProp.rangeMin, rangeMax: oldProp.rangeMax, rangeStep: oldProp.rangeStep,
                incremental: oldProp.incremental, isButton: oldProp.isButton)
            discoveredProperties[pending.propId] = updated
            onPropertiesDiscovered?([pending.propId: updated])
        }

        // Wait for camera to apply the change before re-reading.
        if usedStep { Thread.sleep(forTimeInterval: 0.20) }

        // Re-fetch via GetAllPropData — catches side-effects on OTHER properties
        // (e.g. aperture range changes when exposure mode changes). The merge
        // logic in parseSonyAllPropertyDataResponse won't clobber our optimistic
        // value with the camera's lingering placeholder 0.
        if supportedOps.contains(PTP_CMD_SONY_GETALLPROPDATA) {
            if let (inData, rsp) = try? transport.sendPtpCommand(
                transport.buildCommand(code: PTP_CMD_SONY_GETALLPROPDATA)),
               transport.responseCode(from: rsp) == PTP_RSP_OK, let data = inData {
                cameraLog.fault("GetAllPropData after set 0x\(hexId, privacy: .public) len=\(data.count, privacy: .public)")
                // For the property we just set, trust the camera's response
                // even if it's 0 — otherwise the merge logic preserves our
                // stale cached value and the menu never reflects reality.
                parseSonyAllPropertyDataResponse(data, mergePreserveZeros: false,
                                                 propIdToTrust: pending.propId)
                if let after = discoveredProperties[pending.propId] {
                    cameraLog.fault("post-set 0x\(hexId, privacy: .public) cached=\(after.value, privacy: .public) (target was \(pending.value, privacy: .public))")
                }
            } else {
                cameraLog.fault("GetAllPropData after set failed for 0x\(hexId, privacy: .public)")
            }
        }
    }
}

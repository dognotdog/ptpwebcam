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
        // After SDIOConnect(3), poll GetAllPropData repeatedly. Two phases:
        //   1. The first several polls return an 8-byte header-only stub while
        //      the camera assembles the descriptor table.
        //   2. Once the full table arrives it carries the descriptor STRUCTURE
        //      but many CurrentValue fields (ISO/aperture/shutter/WB/…) are
        //      still placeholder zeros — the camera fills in real values over
        //      the next few hundred ms.
        // So we can't stop at the first non-empty response (that was the
        // regression — we captured the all-zeros snapshot). Instead keep
        // polling, letting `mergePreserveZeros` accumulate real values as they
        // land, and stop once a few consecutive polls report no further value
        // changes (`fetchAndParseAllPropData` returns the count of genuinely
        // changed properties).
        var gotDescriptors = false
        var quietPolls = 0
        for attempt in 1...60 {           // hard cap ≈ 3 s (60 × 50 ms)
            if closing { break }
            let changedCount = fetchAndParseAllPropData(label: "poll #\(attempt)")
            if changedCount > 0 {
                gotDescriptors = true
                quietPolls = 0
            } else if gotDescriptors {
                quietPolls += 1
            }
            // Three quiet polls in a row after the table arrived → the camera
            // has settled. 3 × 50 ms = 150 ms of stability.
            if gotDescriptors && quietPolls >= 3 { break }
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
                let eventCode = eventData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self) }
                guard eventCode == PTP_EVENT_SONY_PROPVALCHANGED else { continue }
                let propId = UInt32(eventData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt16.self) })
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
        // Dump the enum value lists for incremental properties — those drive
        // the dial steppers in the agent and bad/unexpected values there
        // (e.g. 0x5010 ExpBias entries that all format the same) point at
        // unit / encoding mismatches.
        for id in sorted {
            guard let p = discoveredProperties[id], p.incremental, let vals = p.enumValues else { continue }
            let valStr = vals.map { "\($0)" }.joined(separator: ",")
            cameraLog.fault("Sony enum 0x\(String(id, radix: 16), privacy: .public)(dt\(p.dataType, privacy: .public)) #\(vals.count, privacy: .public): \(valStr, privacy: .public)")
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
            let eventCode = eventData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self) }
            cameraLog.fault("Sony event 0x\(String(eventCode, radix:16), privacy: .public) raw=\(eventData.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public)")
            guard eventCode == PTP_EVENT_SONY_PROPVALCHANGED else { continue }
            let propId = UInt32(eventData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt16.self) })
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
    ///   placeholder zeros during init).
    /// - parameter propIdToPreserve: if set, this property's *value* is never
    ///   taken from the response — the existing cached value is kept and only
    ///   the descriptor fields (enum/range/flags) are refreshed. Used for the
    ///   post-set refresh: the property we just set already has the
    ///   authoritative value (the optimistic update for SetPropAbs, or the
    ///   step loop's per-iteration re-read for SetPropStep), and Sony's
    ///   GetAllPropData lags by one transaction so its read of that property
    ///   is stale. The refresh still updates every OTHER property to catch
    ///   side-effects (e.g. aperture range shifting when exposure mode changes).
    private func parseSonyAllPropertyDataResponse(
        _ data: Data,
        publish: Bool = true,
        mergePreserveZeros: Bool = true,
        propIdToPreserve: UInt32? = nil
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
            // Sony's `IsEnabled` byte (offset 5 in their extended GetAllPropData
            // format — NOT standard PTP, which only has the single GetSet byte
            // at offset 4). Per libgphoto2's Sony driver:
            //   0 = disabled / grayed out (read-only)
            //   1 = enabled (read/write)
            //   2 = display-only — currently locked by a physical control
            //       (e.g. A1's top-deck exposure-bias dial or mode dial). The
            //       camera will ACK SetPropAbs/SetPropStep but ignore them.
            // Only 1 is truly writable. Marking 2 as writable produces a
            // dial that does nothing: the camera reports unchanged values
            // and the agent's menu falls out of sync.
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

            let prop = UsbCameraProperty(
                propertyId: propId, dataType: dataType, writable: writable,
                value: current, enumValues: enumValues,
                rangeMin: rangeMin, rangeMax: rangeMax, rangeStep: rangeStep,
                incremental: incremental, isButton: isButton)
            let existing = discoveredProperties[propId]
            // Decide whether to keep the existing cached value instead of the
            // one in this response. Two independent reasons to keep it:
            //   1. `propIdToPreserve == propId` — the property we just set.
            //      Sony's GetAllPropData read of it lags one transaction, so
            //      the response value is stale; our cached value (set by the
            //      optimistic update / step loop) is the truth.
            //   2. placeholder-zero protection — during init the camera ships
            //      the descriptor table before populating CurrentValue, so a
            //      0 over a non-zero cached value is almost certainly a
            //      not-yet-filled placeholder, not a real change.
            let keepForPreserve = (propIdToPreserve == propId) && existing != nil
            let keepForZero     = mergePreserveZeros && existing != nil
                                  && current.intValue == 0 && existing!.value.intValue != 0
            let resolved: UsbCameraProperty
            if keepForPreserve || keepForZero, let existing {
                // Keep the cached value; still refresh descriptor fields
                // (enum/range/flags) from the camera's response.
                resolved = UsbCameraProperty(
                    propertyId: propId, dataType: dataType, writable: writable,
                    value: existing.value,
                    enumValues: enumValues ?? existing.enumValues,
                    rangeMin: rangeMin ?? existing.rangeMin,
                    rangeMax: rangeMax ?? existing.rangeMax,
                    rangeStep: rangeStep ?? existing.rangeStep,
                    incremental: incremental, isButton: isButton)
            } else {
                resolved = prop
            }
            discoveredProperties[propId] = resolved
            // Only report a property in `changed` if it's genuinely new or its
            // value actually moved. The discovery poll loop relies on this:
            // "a poll that changes nothing" is its signal that the camera has
            // finished filling in CurrentValues and we can stop polling. If we
            // reported every parsed property every time, the loop could never
            // detect "settled".
            if existing == nil || existing!.value != resolved.value {
                changed[propId] = resolved
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
        // Single-byte signed payload — see performPropertySet for why 4
        // bytes (the obvious-but-wrong choice) misbehaves on Sony A1.
        let s8 = UInt8(truncatingIfNeeded: step)
        let cmd = transport.buildCommand(code: PTP_CMD_SONY_SETPROPSTEP, parameters: [propId])
        _ = try? transport.sendPtpCommand(cmd, outData: Data([s8]))
    }

    // MARK: - Property set

    /// Reinterpret the raw 32-bit payload received from the agent as the
    /// signed/unsigned NSNumber the camera's enum actually uses.
    ///
    /// The agent ships values over a UInt32 Darwin-notify slot. For unsigned
    /// dataTypes (U8/U16/U32) the round-trip is identity. For SIGNED types
    /// (I8/I16/I32) a negative value goes in as -X, becomes 0xFFFF_FFXX...
    /// after `.uint32Value`'s sign-extension on the agent, and arrives here
    /// as a huge positive UInt32. Without this conversion,
    /// `enumValues.firstIndex(of: NSNumber(uint32: huge))` never matches the
    /// stored NSNumber(int16: -X), so negative-EV / negative-bias targets
    /// silently fall out of the step loop with an "enum index not found".
    private static func typedNumber(_ raw: UInt32, dataType: UInt16) -> NSNumber {
        switch dataType {
        case 1: return NSNumber(value: Int8(bitPattern:  UInt8(truncatingIfNeeded: raw)))
        case 2: return NSNumber(value: UInt8(truncatingIfNeeded: raw))
        case 3: return NSNumber(value: Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
        case 4: return NSNumber(value: UInt16(truncatingIfNeeded: raw))
        case 5: return NSNumber(value: Int32(bitPattern: raw))
        case 6: return NSNumber(value: raw)
        default: return NSNumber(value: raw)
        }
    }

    override func performPropertySet(_ pending: PendingSet) {
        let existing = discoveredProperties[pending.propId]
        let hexId = String(pending.propId, radix: 16)
        // Build the target as the same signed/unsigned type the enum holds.
        // `pending.dataType` came from the agent's published descriptor and
        // matches the camera's reported DataType, so this conversion lines
        // up with `enumValues` for lookup, and with the camera's wire format
        // for `encodeLE` below.
        let target = Self.typedNumber(pending.value, dataType: pending.dataType)

        // ── 1. Fire the appropriate set command(s) ────────────────────────
        //
        // The transport-level write is whatever the property type demands:
        //   - button:      one SetPropStep with the value as a signed step.
        //                  No verification (these are momentary triggers).
        //   - incremental: a sequence of ±1 SetPropStep calls, computed from
        //                  the cached current index. Verification below
        //                  catches the case where the cache was wrong, the
        //                  camera dropped a step, or the agent posted a
        //                  target that's farther than we tried for.
        //   - SetPropAbs:  one shot at the exact target.
        var transportOk = false

        if existing?.isButton == true {
            // Sony's SDIO_ControlDevice (0x9207) for button presses takes a
            // SINGLE-BYTE Int8 payload, not Int32. The agent ships the
            // intended signed step in pending.value; we encode it as one
            // signed byte. Sending 4 bytes here was tolerated by older
            // Sony bodies but on the A1 the firmware reads it as Int32 and
            // either ignores the high bytes or treats the whole thing as a
            // jump magnitude, doing something different than intended.
            let inc8 = UInt8(truncatingIfNeeded: Int32(bitPattern: pending.value))
            let cmd = transport.buildCommand(code: PTP_CMD_SONY_SETPROPSTEP, parameters: [pending.propId])
            if let (_, rsp) = try? transport.sendPtpCommand(cmd, outData: Data([inc8])) {
                transportOk = transport.responseCode(from: rsp) == PTP_RSP_OK
            }
            cameraLog.fault("SetPropStep(button) 0x\(hexId, privacy: .public) inc8=0x\(String(inc8, radix: 16), privacy: .public) ok=\(transportOk, privacy: .public)")
            // No verification path for buttons — they're momentary. Still
            // do the standard side-effects refresh below.

        } else if existing?.incremental == true, let enumValues = existing?.enumValues {
            guard let oldIdx = enumValues.firstIndex(of: existing!.value),
                  let newIdx = enumValues.firstIndex(of: target) else {
                cameraLog.fault("SetPropStep 0x\(hexId, privacy: .public) — enum index not found cur=\(existing!.value, privacy: .public) target=\(target, privacy: .public) (raw=\(pending.value, privacy: .public))")
                return
            }
            let raw = newIdx - oldIdx
            if raw == 0 {
                cameraLog.fault("SetPropStep 0x\(hexId, privacy: .public) already at target \(target, privacy: .public)")
                return
            }
            // Sony SetPropStep / SDIO_ControlDevice payload is a SINGLE BYTE
            // interpreted as Int8: 0x01 = +1, 0xFF = -1 (i.e. two's-complement
            // signed). Sending 4 bytes (Int32 = 0xFFFFFFFF for -1) is
            // semantically equivalent IF the camera reads only the first
            // byte, but the Sony A1 reads the full Int32 payload — and on
            // the A1 a 4-byte -1 step is interpreted in the WRONG direction
            // (camera advances forward in enum order instead of backward),
            // which is how we ended up stuck at the -5000 (last) position
            // after a series of intended ±1 dial-down clicks.
            // libgphoto2 sends exactly 1 byte (`PTP_DTC_UINT8`).
            let stepByte: UInt8 = raw > 0 ? 0x01 : 0xFF
            let stepCount = abs(raw)
            var okCount = 0
            for _ in 0..<stepCount {
                if closing { break }
                let cmd = transport.buildCommand(code: PTP_CMD_SONY_SETPROPSTEP, parameters: [pending.propId])
                if let (_, rsp) = try? transport.sendPtpCommand(cmd, outData: Data([stepByte])),
                   transport.responseCode(from: rsp) == PTP_RSP_OK {
                    okCount += 1
                } else {
                    cameraLog.fault("SetPropStep 0x\(hexId, privacy: .public) step \(okCount + 1, privacy: .public)/\(stepCount, privacy: .public) failed")
                    break
                }
                // Small gap between steps so the firmware registers each
                // separately. NO read here — see comment in
                // waitForCameraToReachValue about transport corruption.
                Thread.sleep(forTimeInterval: 0.04)
            }
            transportOk = okCount > 0
            cameraLog.fault("SetPropStep 0x\(hexId, privacy: .public) target=\(target, privacy: .public) sent=\(okCount, privacy: .public)/\(stepCount, privacy: .public)")

        } else {
            let outData = Self.encodeLE(value: pending.value, dataType: pending.dataType)
            let cmd = transport.buildCommand(code: PTP_CMD_SONY_SETPROPABS, parameters: [pending.propId])
            if let (_, rsp) = try? transport.sendPtpCommand(cmd, outData: outData) {
                let code = transport.responseCode(from: rsp)
                transportOk = code == PTP_RSP_OK
                cameraLog.fault("SetPropAbs 0x\(hexId, privacy: .public)=\(target, privacy: .public) → 0x\(String(code, radix:16), privacy: .public)")
            }
        }

        guard transportOk else { return }

        // ── 2. Verify the camera actually reached the target ───────────────
        //
        // The whole reason this feedback loop exists: command-OK from the
        // camera does NOT mean the property has settled. Sony's GetAllPropData
        // read of the just-set property reliably LAGS by one transaction
        // (observed across all sets) and the per-step SetPropStep can also
        // silently no-op when fired faster than the firmware applies them.
        //
        // So poll GetAllPropData until either:
        //   - the camera reports the target value (success, cache is correct),
        //   - or we time out (cache reflects the camera's actual state, which
        //     may differ from the user's intent — that's fine, the menu now
        //     shows reality on close-reopen, and the next set computes its
        //     own ±N step from this REAL position, self-correcting).
        //
        // For buttons we skip verification — they're momentary, and the
        // "value" isn't really a settled state.
        if existing?.isButton == true {
            // Just refresh once for side-effects on other props.
            _ = pollOnce()
            return
        }

        let landed = waitForCameraToReachValue(propId: pending.propId, target: target, timeout: 1.2)
        if let cached = discoveredProperties[pending.propId] {
            cameraLog.fault("post-set 0x\(hexId, privacy: .public) cached=\(cached.value, privacy: .public) target=\(target, privacy: .public) converged=\(landed, privacy: .public)")
        }
    }

    /// Read GetAllPropData and commit. Returns true on transport success.
    @discardableResult
    private func pollOnce() -> Bool {
        guard supportedOps.contains(PTP_CMD_SONY_GETALLPROPDATA) else { return false }
        guard let (inData, rsp) = try? transport.sendPtpCommand(
                  transport.buildCommand(code: PTP_CMD_SONY_GETALLPROPDATA)),
              transport.responseCode(from: rsp) == PTP_RSP_OK, let data = inData
        else { return false }
        // Default merge: zero-protection on, no preserve. The camera's truth
        // wins for every property — that's exactly what we want for the
        // verification loop. Any stale-lag read of the just-set property
        // will be replaced by the next iteration's read once the camera has
        // actually applied the change.
        parseSonyAllPropertyDataResponse(data, mergePreserveZeros: true)
        return true
    }

    /// Poll GetAllPropData until the named property's current value matches
    /// `target`, or `timeout` elapses. Each iteration parses and commits the
    /// full response so OTHER properties (side-effects of the set, e.g.
    /// aperture range shifting when exposure mode changes) stay current too.
    ///
    /// On success: `discoveredProperties[propId].value == target`, agent
    /// menu (eventually) shows the target value.
    ///
    /// On timeout: `discoveredProperties[propId].value` is whatever the
    /// camera last reported — possibly the "stale lag" value from before
    /// the set committed, possibly the user's target if it happened to
    /// converge in the last iteration but we didn't notice in time. Either
    /// way the cache reflects the camera's perspective, so the menu shows
    /// reality on rebuild and the NEXT set's step math starts from a real
    /// position.
    private func waitForCameraToReachValue(propId: UInt32, target: NSNumber,
                                           timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !closing {
            // Brief wait first — the camera typically needs ~50-150 ms to
            // commit a Sony SetPropStep/SetPropAbs to GetAllPropData's view.
            Thread.sleep(forTimeInterval: 0.08)
            guard pollOnce() else { continue }
            if discoveredProperties[propId]?.value == target { return true }
        }
        return false
    }
}

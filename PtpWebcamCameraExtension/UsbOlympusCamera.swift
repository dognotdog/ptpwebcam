// UsbOlympusCamera.swift
// Olympus / OM Digital Solutions PTP scaffold.
//
// Two distinct firmware families share the Olympus VID 0x07B4:
//
//   1. **Modern bodies** — E-M5 II, E-M1 / E-M1 II / OM-1 etc. (PID 0x012F,
//      0x0130, 0x0135, 0x0136…). They speak fairly standard PTP and honour
//      `GetDevicePropDesc` after `OpenSession`, so the base class default
//      handles property discovery.
//
//   2. **E-series DSLRs** — E-410, E-420, E-510, E-3, E-5, E-30 etc.
//      (single PID 0x0110). On these bodies every non-trivial PTP
//      command must be wrapped in an XML "envelope" and round-tripped
//      through a synthetic file-upload/file-download dance:
//          - SendObjectInfo("HREQUEST.X3C", Script, storage 0x80000001)
//          - SendObject(<xml-encoded request>)
//          - wait for `RequestObjectTransfer` event (0x4009) on interrupt-IN
//          - GetObjectInfo + GetObject to fetch <xml-encoded response>
//          - parse with NSXMLDocument
//      This file implements that path well enough for the PTP dump to
//      produce real property descriptors from E-series bodies. Live view
//      and property writes are deliberately out of scope for now.

let OLYMPUS_XML_PIDS: [UInt16] = [0x0110]

import Foundation

// Standard PTP opcodes (SendObjectInfo, SendObject, GetObject) and the
// RequestObjectTransfer event live in UsbPtpCameraBase.swift. PTP_OFC_SCRIPT
// likewise — see the "Standard PTP constants" block there.
private let OLYMPUS_XML_STORAGE_ID: UInt32 = 0x80000001

// MARK: - Olympus modern (OMD) opcodes + property codes

/// `PTP_OC_OLYMPUS_GetLiveViewImage` — single-shot JPEG fetch. Returns
/// the frame as the bulk-IN data with no vendor header to strip.
private let PTP_CMD_OLYMPUS_GET_LIVEVIEW_IMG: UInt16 = 0x9484

/// `PTP_DPC_OLYMPUS_PCMode` — general "switch to PC tethered mode" toggle.
/// Set to 1 once during vendor connect; without it, modern bodies refuse
/// most other commands with `OperationNotSupported`.
private let PTP_PROP_OLYMPUS_PC_MODE: UInt32 = 0xD052

/// `PTP_DPC_OLYMPUS_LiveViewModeOM` — the mode the camera switches to in
/// order to start streaming preview frames. The camera fills the GetLiveViewImage queue once
/// this is set.
private let PTP_PROP_OLYMPUS_LV_MODE: UInt32 = 0xD06D
private let OLYMPUS_LV_MODE_PC_STREAM: UInt32 = 0x04000300

final class UsbOlympusCamera: UsbPtpCameraBase {

    /// True for the legacy E-series DSLRs that wrap every vendor command in
    /// the XML envelope described at the top of this file. Exposed (not
    /// `private`) so PtpDumper can pick the right handshake banner.
    let isOlympusXmlWrapped: Bool

    init(transport: UsbPtpTransport) {
        // If future bodies are reported we'd extend this set.
        self.isOlympusXmlWrapped = OLYMPUS_XML_PIDS.contains(transport.productId)
        super.init(transport: transport, logTag: "UsbOlympusCamera")
        if isOlympusXmlWrapped {
            cameraLog.fault("E-series body detected — using XML-wrapped PTP path")
        }
    }

    /// True once we've successfully switched the camera into LV-stream
    /// mode (via writing PTP_DPC_OLYMPUS_LiveViewModeOM = 0x04000300).
    /// Used to gate the fetch loop and to skip the LV mode write on
    /// subsequent restart attempts (the camera tolerates the redundant
    /// write but it's noisy in the logs).
    private var omdLiveViewActive = false

    override func performVendorConnect() {
        // Standard PTP first — populates supportedOps + standardPropertyIds.
        parseDeviceInfo()
        // Modern Olympus bodies (E-M1 II, OM-1) need a one-shot "switch to
        // PC mode" write before they accept tethered live view or property
        // changes. The
        // XML-wrapped E-series bodies use a completely different protocol
        // and don't honour 0xD052; we skip this step there.
        if !isOlympusXmlWrapped {
            switchToPcMode()
        }
    }

    private func switchToPcMode() {
        // PC-mode write is harmless if 0xD052 isn't actually exposed by
        // the body — the SetDevicePropValue request just gets a non-OK
        // response and we move on.
        let payload = encodeStandardPtpValue(1, dataType: 4 /* UINT16 */)
        let cmd = transport.buildCommand(code: PTP_CMD_SETPROPVAL,
                                          parameters: [PTP_PROP_OLYMPUS_PC_MODE])
        guard let (_, rsp) = try? transport.sendPtpCommand(cmd, outData: payload) else { return }
        let code = transport.responseCode(from: rsp)
        cameraLog.fault("Olympus PC-mode switch (0xD052=1) → 0x\(String(code, radix: 16), privacy: .public)")
        // wait ~100ms then drains an event before continuing.
        // The drain is for the camera's "I switched modes" propvalchanged
        // event — we don't process those, but the sleep gives the camera
        // time to commit.
        Thread.sleep(forTimeInterval: 0.1)
    }

    override func discoverAllProperties() -> [UInt32: UsbCameraProperty] {
        guard isOlympusXmlWrapped else { return super.discoverAllProperties() }
        return discoverViaXmlWrap()
    }

    /// Modern OM-1 / E-M5 II bodies go through the base class's standard
    /// PTP `SetDevicePropValue (0x1016)`. E-series bodies on PID 0x0110
    /// need the XML envelope (we'd send a `c1016` command inside an
    /// `<input>…</input>` wrap and parse the response). That's not
    /// implemented yet; log and drop the request rather than silently
    /// firing a 0x1016 the camera doesn't honour.
    override func performPropertySet(_ pending: PendingSet) {
        guard !isOlympusXmlWrapped else {
            cameraLog.fault("Olympus E-series setProperty 0x\(String(pending.propId, radix: 16), privacy: .public) ignored — XML-wrapped path not implemented")
            return
        }
        super.performPropertySet(pending)
    }

    // MARK: - XML-wrapped discovery

    private func discoverViaXmlWrap() -> [UInt32: UsbCameraProperty] {
        var out: [UInt32: UsbCameraProperty] = [:]
        for pid16 in standardPropertyIds {
            if closing { break }
            if let prop = xmlGetDevicePropDesc(propId: UInt32(pid16)) {
                out[UInt32(pid16)] = prop
            }
        }
        discoveredProperties = out
        cameraLog.fault("Olympus XML discovery: \(out.count, privacy: .public) of \(self.standardPropertyIds.count, privacy: .public) properties returned data")
        return out
    }

    private func xmlGetDevicePropDesc(propId: UInt32) -> UsbCameraProperty? {
        // Build the XML body. Olympus uses an "input" envelope with a
        //   <cHHHH>      ← opcode in hex
        //     <pHHHH/>   ← property code (for prop-desc commands)
        //   </cHHHH>
        // structure. The opcode for standard GetDevicePropDesc is 0x1014.
        let propHex = String(format: "%04X", propId)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x3c xmlns="http://www1.olympus-imaging.com/ww/x3c"><input><c1014><p\(propHex)/></c1014></input></x3c>
        """
        guard let responseXML = xmlSendCommandAndAwaitResponse(xml) else { return nil }
        return parseGetPropDescResponse(responseXML, propId: propId)
    }

    /// One full XML round-trip:
    ///   SendObjectInfo → SendObject(request XML)
    ///   → wait for RequestObjectTransfer event
    ///   → GetObjectInfo + GetObject (response XML)
    /// Returns the raw response XML or nil on transport / timeout error.
    private func xmlSendCommandAndAwaitResponse(_ requestXml: String) -> Data? {
        guard let payload = requestXml.data(using: .utf8) else { return nil }

        // --- step 1: SendObjectInfo with filename HREQUEST.X3C ---
        let oi = packObjectInfo(filename: "HREQUEST.X3C", objectSize: UInt32(payload.count))
        let oiCmd = transport.buildCommand(code: PTP_CMD_SENDOBJECTINFO,
                                            parameters: [OLYMPUS_XML_STORAGE_ID, 0xFFFFFFFF])
        guard let (_, oiRsp) = try? transport.sendPtpCommand(oiCmd, outData: oi),
              transport.responseCode(from: oiRsp) == PTP_RSP_OK else {
            cameraLog.fault("Olympus XML: SendObjectInfo failed")
            return nil
        }

        // --- step 2: SendObject with XML payload ---
        let soCmd = transport.buildCommand(code: PTP_CMD_SENDOBJECT)
        guard let (_, soRsp) = try? transport.sendPtpCommand(soCmd, outData: payload),
              transport.responseCode(from: soRsp) == PTP_RSP_OK else {
            cameraLog.fault("Olympus XML: SendObject failed")
            return nil
        }

        // --- step 3: wait for RequestObjectTransfer event on interrupt-IN ---
        // The camera POSTs an event with the new object handle once it has
        // processed the request and made the response file available.
        guard let responseHandle = awaitOlympusResponseHandle(timeout: 2.0) else {
            cameraLog.fault("Olympus XML: no RequestObjectTransfer event within timeout")
            return nil
        }

        // --- step 4: GetObject on the returned handle ---
        let goCmd = transport.buildCommand(code: PTP_CMD_GETOBJECT, parameters: [responseHandle])
        guard let (inData, goRsp) = try? transport.sendPtpCommand(goCmd),
              transport.responseCode(from: goRsp) == PTP_RSP_OK,
              let xmlBytes = inData else {
            cameraLog.fault("Olympus XML: GetObject(0x\(String(responseHandle, radix: 16))) failed")
            return nil
        }
        return xmlBytes
    }

    /// Poll the interrupt-IN pipe for a RequestObjectTransfer event and
    /// return the new object handle from its Param1 field.
    private func awaitOlympusResponseHandle(timeout: TimeInterval) -> UInt32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !closing {
            guard let evt = transport.readInterruptEvent(timeout: 0.1) else { continue }
            // PTP interrupt event packet:
            //   uint32 length | uint16 type(=0x0004) | uint16 code | uint32 txid | uint32 param1 | ...
            guard evt.count >= 16 else { continue }
            let code = evt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self) }
            let p1   = evt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }
            if code == PTP_EVENT_REQUESTOBJECTTRANSFER { return p1 }
        }
        return nil
    }

    // MARK: - PTP ObjectInfo packing
    //
    // Layout per PTP spec section 5.5.7 (Object Information Dataset):
    //   offset 0..51   fixed-size fields (StorageID, ObjectFormat, …)
    //   offset 52      filename length (uint8, char count INCLUDING null term)
    //   offset 53..    filename as UTF-16LE chars + 2-byte null terminator
    //   then 3 more PTP strings (CaptureDate, ModificationDate, Keywords) —
    //     we leave all three empty, each contributing a single 0x00 byte.

    private func packObjectInfo(filename: String, objectSize: UInt32) -> Data {
        var d = Data(count: 52)
        // StorageID (offset 0)
        writeLE32(&d, OLYMPUS_XML_STORAGE_ID, at: 0)
        // ObjectFormat (offset 4) = Script
        writeLE16(&d, PTP_OFC_SCRIPT, at: 4)
        // ProtectionStatus (offset 6) = 0
        // ObjectCompressedSize (offset 8)
        writeLE32(&d, objectSize, at: 8)
        // Everything else (thumb*, image*, parent, association*, sequence) = 0

        // Filename — count includes the trailing UTF-16 null terminator.
        let utf16 = Array(filename.utf16)
        d.append(UInt8(utf16.count + 1))
        for c in utf16 {
            d.append(UInt8(c & 0xFF))
            d.append(UInt8((c >> 8) & 0xFF))
        }
        d.append(0); d.append(0)  // null terminator

        // CaptureDate, ModificationDate, Keywords — all empty PTP strings
        // (1 byte count = 0).
        d.append(0); d.append(0); d.append(0)
        return d
    }

    private func writeLE16(_ d: inout Data, _ v: UInt16, at offset: Int) {
        d[offset]     = UInt8(v & 0xFF)
        d[offset + 1] = UInt8((v >> 8) & 0xFF)
    }
    private func writeLE32(_ d: inout Data, _ v: UInt32, at offset: Int) {
        d[offset]     = UInt8(v & 0xFF)
        d[offset + 1] = UInt8((v >> 8) & 0xFF)
        d[offset + 2] = UInt8((v >> 16) & 0xFF)
        d[offset + 3] = UInt8((v >> 24) & 0xFF)
    }

    // MARK: - XML response parsing
    //
    // Response shape per olympus-wrap.c::traverse_output_tree:
    //   <x3c><output>
    //     <result>HHHH</result>           ← PTP response code, e.g. 2001 = OK
    //     <cHHHH>                          ← echo of the request opcode
    //       <pHHHH>                        ← property code we asked about
    //         <type>HHHH</type>            ← PTP data type (UINT16 etc.)
    //         <attr>HH</attr>              ← GetSet flag
    //         <default>HEX</default>
    //         <value>HEX</value>           ← current value
    //         <form>0|1|2</form>           ← none | range | enum
    //         <range>min,max,step</range>  ← if form=1
    //         <enum>v1,v2,…</enum>         ← if form=2
    //       </pHHHH>
    //     </c1014>
    //   </output></x3c>
    //
    // Hex element under output → first hex child gives the property body, named
	// children give the fields. Anything missing produces nil rather than
	// partial garbage.

    private func parseGetPropDescResponse(_ data: Data, propId: UInt32) -> UsbCameraProperty? {
        guard let doc = try? XMLDocument(data: data, options: .nodeLoadExternalEntitiesNever),
              let root = doc.rootElement(),
              let output = firstChildElement(root, named: "output") else {
            return nil
        }
        // Check result code first; ignore the descriptor if the camera
        // returned an error.
        if let result = firstChildElement(output, named: "result"),
           let resultText = result.stringValue,
           let resultCode = UInt16(resultText, radix: 16),
           resultCode != PTP_RSP_OK {
            cameraLog.fault("Olympus XML GetPropDesc 0x\(String(propId, radix: 16)) → result 0x\(String(resultCode, radix: 16))")
            return nil
        }
        // The command-echo element is "c1014" — find any child whose name
        // starts with "c" followed by hex.
        guard let cmdNode = firstChildElementWithHexPrefix(output, prefix: "c"),
              let propNode = firstChildElementWithHexPrefix(cmdNode, prefix: "p") else {
            return nil
        }
        let dataType: UInt16 = {
            if let s = firstChildElement(propNode, named: "type")?.stringValue,
               let v = UInt16(s, radix: 16) { return v }
            return 6  // default UINT32 if unspecified
        }()
        let writable: Bool = {
            if let s = firstChildElement(propNode, named: "attr")?.stringValue,
               let v = UInt8(s, radix: 16) { return v != 0 }
            return false
        }()
        let defaultVal = parseHexNum(firstChildElement(propNode, named: "default")?.stringValue,
                                     dataType: dataType)
        let currentVal = parseHexNum(firstChildElement(propNode, named: "value")?.stringValue,
                                     dataType: dataType)
            ?? NSNumber(value: 0)

        var enumValues: [NSNumber]?
        var rangeMin, rangeMax, rangeStep: NSNumber?
        if let enumNode = firstChildElement(propNode, named: "enum"),
           let body = enumNode.stringValue {
            enumValues = body.split(separator: ",").compactMap { tok in
                parseHexNum(String(tok).trimmingCharacters(in: .whitespaces), dataType: dataType)
            }
        }
        if let rangeNode = firstChildElement(propNode, named: "range"),
           let body = rangeNode.stringValue {
            let parts = body.split(separator: ",").map {
                parseHexNum(String($0).trimmingCharacters(in: .whitespaces), dataType: dataType)
            }
            if parts.count >= 3 {
                rangeMin = parts[0]; rangeMax = parts[1]; rangeStep = parts[2]
            }
        }
        return UsbCameraProperty(
            propertyId: propId, dataType: dataType, writable: writable,
            value: currentVal, enumValues: enumValues,
            rangeMin: rangeMin, rangeMax: rangeMax, rangeStep: rangeStep,
            defaultValue: defaultVal)
    }

    private func firstChildElement(_ parent: XMLElement, named name: String) -> XMLElement? {
        for child in parent.children ?? [] {
            if let elem = child as? XMLElement, elem.localName == name { return elem }
        }
        return nil
    }

    private func firstChildElementWithHexPrefix(_ parent: XMLElement, prefix: String) -> XMLElement? {
        for child in parent.children ?? [] {
            if let elem = child as? XMLElement,
               let n = elem.localName,
               n.hasPrefix(prefix),
               UInt32(n.dropFirst(prefix.count), radix: 16) != nil {
                return elem
            }
        }
        return nil
    }

    /// Parse a hex-encoded numeric string from an XML element. The Olympus
    /// XML format puts most values in plain hex without a 0x prefix; some
    /// values are decimal. We try hex first then fall back to decimal.
    private func parseHexNum(_ s: String?, dataType: UInt16) -> NSNumber? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let hex = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
        if let u = UInt64(hex, radix: 16) {
            return numberOfDataType(dataType: dataType, raw: u)
        }
        if let i = Int64(s, radix: 10) {
            return numberOfDataType(dataType: dataType, raw: UInt64(bitPattern: i))
        }
        return nil
    }

    private func numberOfDataType(dataType: UInt16, raw: UInt64) -> NSNumber {
        switch dataType {
        case 1: return NSNumber(value: Int8(bitPattern: UInt8(raw & 0xFF)))
        case 2: return NSNumber(value: UInt8(raw & 0xFF))
        case 3: return NSNumber(value: Int16(bitPattern: UInt16(raw & 0xFFFF)))
        case 4: return NSNumber(value: UInt16(raw & 0xFFFF))
        case 5: return NSNumber(value: Int32(bitPattern: UInt32(raw & 0xFFFFFFFF)))
        case 6: return NSNumber(value: UInt32(raw & 0xFFFFFFFF))
        case 7: return NSNumber(value: Int64(bitPattern: raw))
        case 8: return NSNumber(value: raw)
        default: return NSNumber(value: raw)
        }
    }

    // MARK: - Live view (OMD)
    //
    //   - Set PTP_DPC_OLYMPUS_LiveViewModeOM (0xD06D) = 0x04000300 once.
    //   - Loop: 0x9484 PTP_OC_OLYMPUS_GetLiveViewImage → JPEG. Retry on
    //     DeviceBusy or short payload (< 1024 bytes).
    //   - No explicit stop opcode; ending the stream means stopping
    //     polling. We *could* reset the LV mode property back to 0 in
    //     stopLiveViewSession but it doesn't seem necessary — the
    //     camera handles a non-polling host gracefully.
    //
    // E-series bodies (XML envelope path) don't support 0x9484 — we
    // refuse LV start so the user gets a meaningful alert.

    override func startLiveViewSession() -> Bool {
        if isOlympusXmlWrapped {
            liveViewStartError = "Olympus E-series live view is not supported. These bodies (E-410/420/510/520/3/5/30/620) use an XML-wrapped PTP protocol that doesn't have a USB live-view path."
            return false
        }
        guard supportedOps.contains(PTP_CMD_OLYMPUS_GET_LIVEVIEW_IMG) else {
            liveViewStartError = "Olympus camera doesn't advertise GetLiveViewImage (0x9484). Live view requires a body in the OM-1 / E-M1 II / E-M5 II family."
            return false
        }
        // Switch the camera into LV-stream mode by writing 0xD06D. Use
        // standard SetDevicePropValue (0x1016) since modern Olympus
        // honours that opcode.
        let payload = encodeStandardPtpValue(OLYMPUS_LV_MODE_PC_STREAM,
                                              dataType: 6 /* UINT32 */)
        let cmd = transport.buildCommand(code: PTP_CMD_SETPROPVAL,
                                          parameters: [PTP_PROP_OLYMPUS_LV_MODE])
        guard let (_, rsp) = try? transport.sendPtpCommand(cmd, outData: payload) else {
            liveViewStartError = "Olympus live-view mode switch (0xD06D) transport error."
            return false
        }
        let code = transport.responseCode(from: rsp)
        cameraLog.fault("Olympus LV mode set (0xD06D=0x04000300) → 0x\(String(code, radix: 16), privacy: .public)")
        if code != PTP_RSP_OK {
            liveViewStartError = "Olympus refused live-view mode switch (0x\(String(code, radix: 16))). The body may need a firmware update, or it doesn't support tethered live view (some older E-Mxxx bodies)."
            return false
        }
        omdLiveViewActive = true
        // Give the camera a moment to fill the first frame.
        Thread.sleep(forTimeInterval: 0.1)
        return true
    }

    override func stopLiveViewSession() -> Bool {
        // Stream ends when polling stops. We don't reset 0xD06D — the
        // camera tolerates a non-polling host and resetting it can race
        // with an in-flight GetLiveViewImage transaction.
        // Nothing to fail at — the flag flip is purely local.
        omdLiveViewActive = false
        return true
    }

    override func fetchOneFrame() throws -> Data? {
        let cmd = transport.buildCommand(code: PTP_CMD_OLYMPUS_GET_LIVEVIEW_IMG)
        // retry up to 25 times within one frame call with
        // 40 ms sleep on DeviceBusy / short payload. Our outer LV loop
        // also retries, so we keep the inner retry small (3 × 40 ms) and
        // return nil for the outer loop to handle longer waits.
        for _ in 0..<3 {
            if stopLv || closing { return nil }
            let (inData, rsp) = try transport.sendPtpCommand(cmd)
            let code = transport.responseCode(from: rsp)
            if code == PTP_RSP_OK, let data = inData, data.count >= 1024 {
                // Olympus returns raw JPEG (FF D8 … FF D9). Pass through
                // extractJpegFromLiveViewData for safety in case a body
                // prepends a header.
                return extractJpegFromLiveViewData(data) ?? data
            }
            if code == PTP_RSP_DEVICEBUSY || (inData?.count ?? 0) < 1024 {
                Thread.sleep(forTimeInterval: 0.04)
                continue
            }
            cameraLog.fault("Olympus GetLiveViewImage (0x9484) → 0x\(String(code, radix: 16), privacy: .public) size=\(inData?.count ?? -1, privacy: .public)")
            return nil
        }
        return nil
    }
}

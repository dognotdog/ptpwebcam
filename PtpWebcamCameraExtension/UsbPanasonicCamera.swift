// UsbPanasonicCamera.swift
// Panasonic Lumix PTP integration.
//
// Panasonic broke the standard PTP property model: `GetDevicePropDesc`
// (0x1014) returns nothing on a Lumix body. They use their own opcode
// family instead:
//
//   0x9102 OpenSession      — required before any property access
//   0x9103 CloseSession
//   0x9108 ListProperty     — given a 32-bit property-group code, returns
//                              a packed descriptor with the current value
//                              + the full list of supported values
//   0x9402 GetProperty      — read a single value
//   0x9403 SetProperty      — write a value (8-byte header + value bytes)
//   0x9412 Liveview         — ON/OFF toggle. Param1=0x0D000010 (start) or
//                              0x0D000011 (stop). NO image payload.
//   0x9706 LiveviewImage    — fetch one JPEG frame (NO header to strip).
//
// Property codes are 32-bit (0x02000010 etc.) rather than 16-bit. The
// 16-bit `propertyName(_, vendor:)` lookup won't match — Panasonic prop
// names go through `PtpKnownCameras.panasonicPropertyName32` instead.
//
// Implemented in this class: discovery (ListProperty), property setting
// (SetProperty), live view (Liveview toggle + LiveviewImage fetch).
// Property reads outside discovery / writes still funnel through the
// base class's pending-set queue and `performPropertySet` below.

import Foundation

private let PTP_CMD_PANASONIC_OPENSESSION:  UInt16 = 0x9102
private let PTP_CMD_PANASONIC_CLOSESESSION: UInt16 = 0x9103
private let PTP_CMD_PANASONIC_LISTPROPERTY: UInt16 = 0x9108
private let PTP_CMD_PANASONIC_GETPROPERTY:  UInt16 = 0x9402
private let PTP_CMD_PANASONIC_SETPROPERTY:  UInt16 = 0x9403
/// Live-view ON/OFF toggle. Param1 = 0x0D000010 (start) or 0x0D000011 (stop).
private let PTP_CMD_PANASONIC_LIVEVIEW:     UInt16 = 0x9412
/// Live-view frame fetch (returns JPEG data). NOT 0x9412 — that's the toggle.
private let PTP_CMD_PANASONIC_LIVEVIEWIMG:  UInt16 = 0x9706

private let PANASONIC_LIVEVIEW_START_PARAM: UInt32 = 0x0D000010
private let PANASONIC_LIVEVIEW_STOP_PARAM:  UInt32 = 0x0D000011

/// Hand-curated list of Panasonic property-group codes worth probing. Each
/// group returns its current value plus all supported values via 0x9108.
private let panasonicProbeProperties: [UInt32] = [
    0x02000010,  // PhotoStyle
    0x02000020,  // ISO
    0x02000022,  // ISO upper limit
    0x02000030,  // ShutterSpeed
    0x02000040,  // Aperture
    0x02000050,  // WhiteBalance
    0x02000052,  // WhiteBalance KSet (Kelvin)
    0x02000060,  // Exposure (EV bias)
    0x02000080,  // CameraMode
    0x02000081,  // DriveMode
    0x020000A2,  // ImageFormat
    0x020000B0,  // MeteringInfo
]

final class UsbPanasonicCamera: UsbPtpCameraBase {

    init(transport: UsbPtpTransport) {
        super.init(transport: transport, logTag: "UsbPanasonicCamera")
    }

    override func performVendorConnect() {
        parseDeviceInfo()
        // Panasonic requires its own OpenSession variant in addition to (or
        // instead of) the standard 0x1002 we already sent during the base
        // class's runOpenSessionPhase.
		if supportedOps.contains(PTP_CMD_PANASONIC_OPENSESSION) {
            let cmd = transport.buildCommand(code: PTP_CMD_PANASONIC_OPENSESSION,
                                              parameters: [0x00010001])
            if let (_, rsp) = try? transport.sendPtpCommand(cmd) {
                let code = transport.responseCode(from: rsp)
                cameraLog.fault("Panasonic.OpenSession → 0x\(String(code, radix: 16), privacy: .public)")
            }
        }
    }

    override func discoverAllProperties() -> [UInt32: UsbCameraProperty] {
        var out: [UInt32: UsbCameraProperty] = [:]
        guard supportedOps.contains(PTP_CMD_PANASONIC_LISTPROPERTY) else {
            cameraLog.fault("Panasonic.ListProperty (0x9108) not advertised — dump will be empty")
            return [:]
        }
        for groupCode in panasonicProbeProperties {
            if closing { break }
            if let prop = listProperty(groupCode: groupCode) {
                out[groupCode] = prop
            }
        }
        discoveredProperties = out
        return out
    }

    /// Issue 0x9108 ListProperty for one group code and parse the response.
    /// Returns a synthesised UsbCameraProperty with the current value and
    /// (where present) the enum list of supported values.
    ///
    /// Wire format (after the 12-byte PTP data header):
    ///   [0]  uint32  unknown / always 1
    ///   [4]  uint32  headerLength (in dwords)
    ///   [headerLength*4]      uint32 propertyCode (echo)
    ///   [headerLength*4 + 8]  <valuesize> bytes currentValue (2 or 4)
    ///   [headerLength*4 + 8 + vs] uint32 valueListLength
    ///   [headerLength*4 + 12 + vs] <vs * N> bytes value list
    ///
    /// We have to *guess* the value size — try 4 first, fall back to 2 if
    /// the structure doesn't add up. Good enough for the preliminary dump.
    private func listProperty(groupCode: UInt32) -> UsbCameraProperty? {
        let cmd = transport.buildCommand(code: PTP_CMD_PANASONIC_LISTPROPERTY,
                                          parameters: [groupCode, 0, 0])
        guard let (inData, rsp) = try? transport.sendPtpCommand(cmd),
              transport.responseCode(from: rsp) == PTP_RSP_OK,
              let data = inData,
              data.count >= 16 else {
            return nil
        }
        return parseListPropertyResponse(data, groupCode: groupCode, valueSize: 4)
            ?? parseListPropertyResponse(data, groupCode: groupCode, valueSize: 2)
    }

    private func parseListPropertyResponse(_ data: Data,
                                           groupCode: UInt32,
                                           valueSize: Int) -> UsbCameraProperty? {
        let p = PtpPropParser(data)
        _ = p.readU32()  // leading word (unknown)
        guard let headerLenDwords = p.readU32() else { return nil }
        let headerByteOffset = Int(headerLenDwords) * 4
        guard data.count >= headerByteOffset + 8 + valueSize else { return nil }
        // Property-code echo lives at offset headerByteOffset+0 in a
        // separate header block; we don't need it for our
        // purposes (we already know which group we asked for).
        // Skip to current value:
        let curOff = headerByteOffset + 8
        guard data.count >= curOff + valueSize else { return nil }
        let current: UInt32
        switch valueSize {
        case 2:
            current = UInt32(data[curOff]) | (UInt32(data[curOff + 1]) << 8)
        case 4:
            current = UInt32(data[curOff])
                   | (UInt32(data[curOff + 1]) << 8)
                   | (UInt32(data[curOff + 2]) << 16)
                   | (UInt32(data[curOff + 3]) << 24)
        default: return nil
        }
        // Value-list length comes right after current.
        let listLenOff = curOff + valueSize
        guard data.count >= listLenOff + 4 else { return nil }
        let listLen = UInt32(data[listLenOff])
                   | (UInt32(data[listLenOff + 1]) << 8)
                   | (UInt32(data[listLenOff + 2]) << 16)
                   | (UInt32(data[listLenOff + 3]) << 24)
        let valuesOff = listLenOff + 4
        guard listLen < 1024,
              data.count >= valuesOff + Int(listLen) * valueSize else { return nil }

        var enums: [NSNumber] = []
        for i in 0..<Int(listLen) {
            let off = valuesOff + i * valueSize
            let v: UInt32
            switch valueSize {
            case 2:
                v = UInt32(data[off]) | (UInt32(data[off + 1]) << 8)
            case 4:
                v = UInt32(data[off])
                  | (UInt32(data[off + 1]) << 8)
                  | (UInt32(data[off + 2]) << 16)
                  | (UInt32(data[off + 3]) << 24)
            default: return nil
            }
            enums.append(NSNumber(value: v))
        }
        // DataType is approximate — Panasonic doesn't ship a PTP-style
        // type code, so we infer from the value size used.
        let dt: UInt16 = valueSize == 2 ? 4 /* UINT16 */ : 6 /* UINT32 */
        return UsbCameraProperty(
            propertyId: groupCode,
            dataType: dt,
            writable: true,
            value: NSNumber(value: current),
            enumValues: enums.isEmpty ? nil : enums,
            rangeMin: nil, rangeMax: nil, rangeStep: nil)
    }

    // MARK: - Live view
    //
    // Panasonic's live view is a two-step protocol:
    //   1. 0x9412 PTP_OC_PANASONIC_Liveview with param1=0x0D000010 to start
    //      (or 0x0D000011 to stop)
    //   2. 0x9706 PTP_OC_PANASONIC_LiveviewImage — single frame fetch
    //      (returns a JPEG payload directly, no header to strip)
    //   3. 0x9412 with 0x0D000011 to stop when done

    override func startLiveViewSession() -> Bool {
        guard supportedOps.contains(PTP_CMD_PANASONIC_LIVEVIEW) else {
            liveViewStartError = "Panasonic camera doesn't advertise live-view opcode 0x9412. Body may need a different protocol family."
            return false
        }
        let cmd = transport.buildCommand(code: PTP_CMD_PANASONIC_LIVEVIEW,
                                          parameters: [PANASONIC_LIVEVIEW_START_PARAM])
        guard let (_, rsp) = try? transport.sendPtpCommand(cmd) else {
            liveViewStartError = "Panasonic live-view start (0x9412) transport error."
            return false
        }
        let code = transport.responseCode(from: rsp)
        cameraLog.fault("Panasonic.Liveview(start) → 0x\(String(code, radix:16), privacy: .public)")
        if code != PTP_RSP_OK {
            liveViewStartError = "Panasonic refused 0x9412 live-view start (response code 0x\(String(code, radix: 16))). The camera may be in playback mode, or movie recording."
            return false
        }
        return true
    }

    override func stopLiveViewSession() {
        let cmd = transport.buildCommand(code: PTP_CMD_PANASONIC_LIVEVIEW,
                                          parameters: [PANASONIC_LIVEVIEW_STOP_PARAM])
        _ = try? transport.sendPtpCommand(cmd)
    }

    override func fetchOneFrame() throws -> Data? {
        let cmd = transport.buildCommand(code: PTP_CMD_PANASONIC_LIVEVIEWIMG)
        let (inData, rsp) = try transport.sendPtpCommand(cmd)
        let code = transport.responseCode(from: rsp)
        guard code == PTP_RSP_OK, let data = inData, data.count > 0 else {
            return nil
        }
        // Panasonic ships the raw JPEG with no PTP-wrapper header — the
        // bulk-IN data IS the JPEG. Defensively check for SOI marker; if
        // it's somewhere past the start, peel any leading bytes the
        // camera tacked on.
        return extractJpegFromLiveViewData(data) ?? data
    }

    // MARK: - Set property
    //
    // 0x9403 PTP_OC_PANASONIC_SetProperty. Param1 = propcode (32-bit). Data
    // phase carries an 8-byte header (propcode + valuesize + 2 bytes pad)
    // followed by the value bytes.
    override func performPropertySet(_ pending: PendingSet) {
        guard supportedOps.contains(PTP_CMD_PANASONIC_SETPROPERTY) else {
            cameraLog.fault("Panasonic.SetProperty (0x9403) not advertised — drop set 0x\(String(pending.propId, radix: 16), privacy: .public)")
            return
        }
        // Width derived from the cached descriptor's dataType. 2 for
        // UINT16 / INT16, 4 for UINT32 / INT32 (everything else falls back
        // to 4 — Panasonic properties are predominantly 32-bit).
        let valueSize: UInt16
        switch pending.dataType {
        case 3, 4:       valueSize = 2
        case 1, 2:       valueSize = 1   // Panasonic occasionally uses byte-wide props
        default:         valueSize = 4
        }
        // Build the data-phase payload: 8 bytes header then valueSize bytes.
        var payload = Data(count: 8 + Int(valueSize))
        payload.withUnsafeMutableBytes { raw in
            let p = raw.baseAddress!
            // bytes 0..3 : propcode (little-endian)
            p.storeBytes(of: pending.propId.littleEndian,
                         toByteOffset: 0, as: UInt32.self)
            // bytes 4..5 : valuesize
            p.storeBytes(of: valueSize.littleEndian,
                         toByteOffset: 4, as: UInt16.self)
            // bytes 6..7 : pad (already zero)
            // bytes 8.. : value, little-endian, truncated to width
            let v = pending.value.littleEndian
            switch valueSize {
            case 1: p.storeBytes(of: UInt8(v & 0xFF), toByteOffset: 8, as: UInt8.self)
            case 2: p.storeBytes(of: UInt16(v & 0xFFFF).littleEndian,
                                 toByteOffset: 8, as: UInt16.self)
            default: p.storeBytes(of: v, toByteOffset: 8, as: UInt32.self)
            }
        }
        let cmd = transport.buildCommand(code: PTP_CMD_PANASONIC_SETPROPERTY,
                                          parameters: [pending.propId])
        guard let (_, rsp) = try? transport.sendPtpCommand(cmd, outData: payload) else {
            cameraLog.fault("Panasonic.SetProperty 0x\(String(pending.propId, radix: 16), privacy: .public) transport error")
            return
        }
        let code = transport.responseCode(from: rsp)
        cameraLog.fault("Panasonic.SetProperty 0x\(String(pending.propId, radix: 16), privacy: .public) = \(pending.value, privacy: .public) (vs=\(valueSize, privacy: .public)) → 0x\(String(code, radix: 16), privacy: .public)")
        if code == PTP_RSP_OK {
            // Re-fetch the descriptor so the agent's menu reflects what the
            // camera actually committed (Panasonic occasionally clamps
            // values to legal stops).
            if let updated = listProperty(groupCode: pending.propId) {
                discoveredProperties[pending.propId] = updated
                onPropertiesDiscovered?([pending.propId: updated])
            }
        }
    }
}

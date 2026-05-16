// UsbPanasonicCamera.swift
// Panasonic Lumix PTP scaffold.
//
// Panasonic broke the standard PTP property model: `GetDevicePropDesc`
// (0x1014) returns nothing on a Lumix body. They use their own opcode
// family instead:
//
//   0x9102 OpenSession        — required before any property access
//   0x9103 CloseSession
//   0x9108 ListProperty       — given a 32-bit property-group code (e.g.
//                               0x02000010), returns a packed descriptor
//                               with the current value + the full list of
//                               supported values
//   0x9402 GetProperty        — read a single value
//   0x9403 SetProperty        — write a value
//   0x9412 GetLiveViewImage   — JPEG frame (not used here yet)
//
// Property codes are 32-bit (0x02000010 etc.) rather than 16-bit. We can't
// fit those into our normal `UsbCameraProperty.propertyId: UInt32` slot
// without losing information, so we just stuff the 32-bit code in. The
// 16-bit `propertyName(_, vendor:)` lookup won't match — Panasonic prop
// names are returned by `PtpKnownCameras.panasonicPropertyName32`.
//
// This class implements just enough to populate `discoveredProperties` for
// the PtpDumper. Live view is a follow-up.

import Foundation

private let PTP_CMD_PANASONIC_OPENSESSION:  UInt16 = 0x9102
private let PTP_CMD_PANASONIC_CLOSESESSION: UInt16 = 0x9103
private let PTP_CMD_PANASONIC_LISTPROPERTY: UInt16 = 0x9108
private let PTP_CMD_PANASONIC_GETPROPERTY:  UInt16 = 0x9402

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
}

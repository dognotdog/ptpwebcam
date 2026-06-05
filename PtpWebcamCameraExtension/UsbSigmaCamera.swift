// UsbSigmaCamera.swift
// Sigma fp / fp L PTP integration.
//
// Sigma fp has its own opcode family (0x9012–0x9037) with a custom
// "CamDataGroup" payload format that's NOT standard PTP GetDevicePropDesc.
// Each DataGroup response is:
//
//   [0]      uint8     header / parity seed
//   [1..2]   uint16 BE FieldPresent  (16 flag bits, one per optional field)
//   [3..N]   variable  fields whose bit is set, IN DECLARATION ORDER
//                      (NOT in bit-position order)
//   [N+1]    uint8     parity (sum of bytes 0..N mod 256)
//
// Each group covers a different chunk of camera state:
//   GetCamDataGroup1 (0x9012) — exposure: shutter/aperture/ISO/EVbias/AB
//   GetCamDataGroup2 (0x9013) — mode: drive/exposure/meter/flash/WB/quality
//   GetCamDataGroup3 (0x9014) — colour: ColorMode/ColorSpace + focal lengths
//   GetCamDataGroup4 (0x9023) — DC crop / LV magnify / HDR / DNG quality
//   GetCamDataGroup5 (0x9027) — interval timer / Kelvin / aspect ratio / tone
//
// SetCamDataGroup1/2/3/4/5 (0x9016/17/18/24/28) flip the wire direction:
// host sends the same bitfield + values; camera echoes acceptance.
//
// Numeric fields are APEX-encoded UInt8s for shutter/aperture/ISO/EVbias —
// each step ≈ 1/8 EV. Conversion is:
//   shutter seconds = 2^(-APEX × 1/8 × 8)  ... so APEX 64 → 1 sec, 96 → 1/8s
//   f-number       = 2^(APEX × 1/16)        ... APEX 32 → f/4, 48 → f/8
//   ISO            = 100 × 2^(APEX/24 - 5/3) ... APEX 64 → ISO 100
//
// Property IDs are synthetic so they fit UsbCameraProperty.propertyId
// (UInt32): high byte 0xF1/F2/F3 identifies the DataGroup; low 16 bits
// hold the FieldPresent bit mask. e.g. 0xF1000100 = DataGroup1 ShutterSpeed.

import Foundation

// MARK: - Sigma opcode constants (private)

private let PTP_CMD_SIGMA_GET_DATAGROUP1:        UInt16 = 0x9012
private let PTP_CMD_SIGMA_GET_DATAGROUP2:        UInt16 = 0x9013
private let PTP_CMD_SIGMA_GET_DATAGROUP3:        UInt16 = 0x9014
private let PTP_CMD_SIGMA_GET_CAPT_STATUS:       UInt16 = 0x9015
private let PTP_CMD_SIGMA_SET_DATAGROUP1:        UInt16 = 0x9016
private let PTP_CMD_SIGMA_SET_DATAGROUP2:        UInt16 = 0x9017
private let PTP_CMD_SIGMA_SET_DATAGROUP3:        UInt16 = 0x9018
private let PTP_CMD_SIGMA_GET_DATAGROUP4:        UInt16 = 0x9023
private let PTP_CMD_SIGMA_SET_DATAGROUP4:        UInt16 = 0x9024
private let PTP_CMD_SIGMA_GET_DATAGROUP5:        UInt16 = 0x9027
private let PTP_CMD_SIGMA_SET_DATAGROUP5:        UInt16 = 0x9028
private let PTP_CMD_SIGMA_GET_VIEW_FRAME:        UInt16 = 0x902B
private let PTP_CMD_SIGMA_CONFIG_API:            UInt16 = 0x9035

/// Synthetic property-ID prefixes used to fit Sigma's per-DataGroup field
/// codes into the UInt32 UsbCameraProperty.propertyId slot. High byte is
/// the group (1/2/3), low 16 bits are the FieldPresent bit mask.
private let SIGMA_PROP_PREFIX_DG1: UInt32 = 0xF1000000
private let SIGMA_PROP_PREFIX_DG2: UInt32 = 0xF2000000
private let SIGMA_PROP_PREFIX_DG3: UInt32 = 0xF3000000

/// One entry per parseable field in a DataGroup, in **declaration order**
/// (the order the field bytes appear on the wire when its bit is set).
private struct SigmaField {
    let name: String
    let bitMask: UInt16       // FieldPresent bit gating this field
    let byteCount: Int        // 1 or 2
    let isUInt16: Bool        // true → read as uint16 LE; false → uint8
    /// Synthetic property ID for the discoveredProperties dictionary.
    let propId: UInt32
}

/// DataGroup 1 field declarations. Wire order matches this list. Each
/// field is gated by `bitMask`; if `(FieldPresent & bitMask) == 0` the
/// field is absent and the parser skips to the next.
private let sigmaDataGroup1Fields: [SigmaField] = [
    .init(name: "ShutterSpeed",            bitMask: 0x0100, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG1 | 0x0100),
    .init(name: "Aperture",                bitMask: 0x0200, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG1 | 0x0200),
    .init(name: "ProgramShift",            bitMask: 0x0400, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG1 | 0x0400),
    .init(name: "ISOAuto",                 bitMask: 0x0800, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG1 | 0x0800),
    .init(name: "ISOSpeed",                bitMask: 0x1000, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG1 | 0x1000),
    .init(name: "ExpComp",                 bitMask: 0x2000, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG1 | 0x2000),
    .init(name: "ABValue",                 bitMask: 0x4000, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG1 | 0x4000),
    .init(name: "ABSetting",               bitMask: 0x8000, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG1 | 0x8000),
    .init(name: "FrameBufferState",        bitMask: 0x0001, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG1 | 0x0001),
    .init(name: "MediaFreeSpace",          bitMask: 0x0002, byteCount: 2, isUInt16: true,  propId: SIGMA_PROP_PREFIX_DG1 | 0x0002),
    .init(name: "MediaStatus",             bitMask: 0x0004, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG1 | 0x0004),
    .init(name: "CurrentLensFocalLength",  bitMask: 0x0008, byteCount: 2, isUInt16: true,  propId: SIGMA_PROP_PREFIX_DG1 | 0x0008),
    .init(name: "BatteryState",            bitMask: 0x0010, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG1 | 0x0010),
    .init(name: "ABShotRemainNumber",      bitMask: 0x0020, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG1 | 0x0020),
    .init(name: "ExpCompExcludeAB",        bitMask: 0x0040, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG1 | 0x0040),
    .init(name: "_Reserved0",              bitMask: 0x0080, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG1 | 0x0080),
]

/// DataGroup 2 — mode / drive / meter / flash / WB / resolution / quality.
private let sigmaDataGroup2Fields: [SigmaField] = [
    .init(name: "DriveMode",       bitMask: 0x0100, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG2 | 0x0100),
    .init(name: "SpecialMode",     bitMask: 0x0200, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG2 | 0x0200),
    .init(name: "ExposureMode",    bitMask: 0x0400, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG2 | 0x0400),
    .init(name: "AEMeteringMode",  bitMask: 0x0800, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG2 | 0x0800),
    .init(name: "_Reserved0",      bitMask: 0x1000, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG2 | 0x1000),
    .init(name: "_Reserved1",      bitMask: 0x2000, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG2 | 0x2000),
    .init(name: "_Reserved2",      bitMask: 0x4000, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG2 | 0x4000),
    .init(name: "_Reserved3",      bitMask: 0x8000, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG2 | 0x8000),
    .init(name: "FlashType",       bitMask: 0x0001, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG2 | 0x0001),
    .init(name: "_Reserved4",      bitMask: 0x0002, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG2 | 0x0002),
    .init(name: "FlashMode",       bitMask: 0x0004, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG2 | 0x0004),
    .init(name: "FlashSetting",    bitMask: 0x0008, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG2 | 0x0008),
    .init(name: "_Reserved5",      bitMask: 0x0010, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG2 | 0x0010),
    .init(name: "WhiteBalance",    bitMask: 0x0020, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG2 | 0x0020),
    .init(name: "Resolution",      bitMask: 0x0040, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG2 | 0x0040),
    .init(name: "ImageQuality",    bitMask: 0x0080, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG2 | 0x0080),
]

/// DataGroup 3 — colour rendering + lens focal lengths + AF beep / dest.
private let sigmaDataGroup3Fields: [SigmaField] = [
    .init(name: "_Reserved0",          bitMask: 0x0100, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG3 | 0x0100),
    .init(name: "_Reserved1",          bitMask: 0x0200, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG3 | 0x0200),
    .init(name: "_Reserved2",          bitMask: 0x0400, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG3 | 0x0400),
    .init(name: "ColorSpace",          bitMask: 0x0800, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG3 | 0x0800),
    .init(name: "ColorMode",           bitMask: 0x1000, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG3 | 0x1000),
    .init(name: "BatteryKind",         bitMask: 0x2000, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG3 | 0x2000),
    .init(name: "LensWideFocalLength", bitMask: 0x4000, byteCount: 2, isUInt16: true,  propId: SIGMA_PROP_PREFIX_DG3 | 0x4000),
    .init(name: "LensTeleFocalLength", bitMask: 0x8000, byteCount: 2, isUInt16: true,  propId: SIGMA_PROP_PREFIX_DG3 | 0x8000),
    .init(name: "AFAuxLight",          bitMask: 0x0001, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG3 | 0x0001),
    .init(name: "AFBeep",              bitMask: 0x0002, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG3 | 0x0002),
    .init(name: "_Reserved3",          bitMask: 0x0004, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG3 | 0x0004),
    .init(name: "_Reserved4",          bitMask: 0x0008, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG3 | 0x0008),
    .init(name: "_Reserved5",          bitMask: 0x0010, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG3 | 0x0010),
    .init(name: "TimerSound",          bitMask: 0x0020, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG3 | 0x0020),
    .init(name: "_Reserved6",          bitMask: 0x0040, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG3 | 0x0040),
    .init(name: "DestToSave",          bitMask: 0x0080, byteCount: 1, isUInt16: false, propId: SIGMA_PROP_PREFIX_DG3 | 0x0080),
]

// MARK: - UsbSigmaCamera

final class UsbSigmaCamera: UsbPtpCameraBase {

    init(transport: UsbPtpTransport) {
        super.init(transport: transport, logTag: "UsbSigmaCamera")
    }

    /// Sigma fp doesn't honour standard PTP `GetDevicePropDesc (0x1014)`.
    /// We instead poll the three DataGroup opcodes (0x9012/13/14) and turn
    /// each set bit in the FieldPresent bitfield into a UsbCameraProperty.
    /// Properties whose bits aren't set just don't appear in the dump.
    override func discoverAllProperties() -> [UInt32: UsbCameraProperty] {
        var out: [UInt32: UsbCameraProperty] = [:]
        fetchDataGroup(opcode: PTP_CMD_SIGMA_GET_DATAGROUP1,
                        fields: sigmaDataGroup1Fields, into: &out)
        fetchDataGroup(opcode: PTP_CMD_SIGMA_GET_DATAGROUP2,
                        fields: sigmaDataGroup2Fields, into: &out)
        fetchDataGroup(opcode: PTP_CMD_SIGMA_GET_DATAGROUP3,
                        fields: sigmaDataGroup3Fields, into: &out)
        discoveredProperties = out
        cameraLog.fault("Sigma discoveredProperties: \(out.count, privacy: .public) fields across 3 data groups")
        return out
    }

    private func fetchDataGroup(opcode: UInt16,
                                fields: [SigmaField],
                                into out: inout [UInt32: UsbCameraProperty]) {
        guard supportedOps.contains(opcode) else {
            cameraLog.fault("Sigma DataGroup 0x\(String(opcode, radix: 16), privacy: .public) not advertised")
            return
        }
        let cmd = transport.buildCommand(code: opcode)
        guard let (inData, rsp) = try? transport.sendPtpCommand(cmd),
              transport.responseCode(from: rsp) == PTP_RSP_OK,
              let data = inData, data.count >= 4 else {
            cameraLog.fault("Sigma DataGroup 0x\(String(opcode, radix: 16), privacy: .public) returned no data")
            return
        }
        parseDataGroupResponse(data, fields: fields, into: &out)
    }

    /// Parse one DataGroup payload using the supplied declaration-ordered
    /// field schema. Inserts one UsbCameraProperty per present field.
    private func parseDataGroupResponse(_ data: Data,
                                        fields: [SigmaField],
                                        into out: inout [UInt32: UsbCameraProperty]) {
        // Wire: [_Header:1] [FieldPresent:2 BE] [fields...] [_Parity:1]
        guard data.count >= 4 else { return }
        let fieldPresent = (UInt16(data[1]) << 8) | UInt16(data[2])
        var off = 3
        for field in fields {
            guard (fieldPresent & field.bitMask) != 0 else { continue }
            guard off + field.byteCount <= data.count - 1 else {
                // Truncated frame — stop early; the parity byte we'd skip
                // past would be misaligned anyway.
                cameraLog.fault("Sigma DataGroup parse: truncated at offset \(off, privacy: .public) for field \(field.name, privacy: .public)")
                return
            }
            let raw: UInt32
            if field.isUInt16 {
                raw = UInt32(data[off]) | (UInt32(data[off + 1]) << 8)
            } else {
                raw = UInt32(data[off])
            }
            off += field.byteCount
            let dt: UInt16 = field.isUInt16 ? 4 /* UINT16 */ : 2 /* UINT8 */
            // Sigma doesn't ship a "valid values" list with each
            // DataGroup response (that's what GetCamCanSetInfo5 is for).
            // To give the menu enum pickers, we synthesise plausible
            // value lists for the user-facing properties using the
            // APEX formulas / known sigma-ptpy enum tables. Missing
            // entries means "show as static label, not pickable".
            let enums = Self.sigmaSyntheticEnum(forPropId: field.propId)
            out[field.propId] = UsbCameraProperty(
                propertyId: field.propId,
                dataType: dt,
                writable: enums != nil,    // only writable if we can offer
                                            // a value picker; read-only stat
                                            // fields (battery, focal length,
                                            // _Reserved) appear in the menu
                                            // but don't pop a submenu
                value: NSNumber(value: raw),
                enumValues: enums,
                rangeMin: nil, rangeMax: nil, rangeStep: nil)
        }
    }

    /// Synthesize a list of valid values for a Sigma property so the menu
    /// can offer an enum picker. Returns nil for properties that aren't
    /// user-facing (BatteryState, FrameBufferState, focal length, reserved
    /// fields). Encoding follows the formulas in
    /// `PropertyFormatter.formatSigmaExtProp` so the picker labels stay
    /// consistent with the displayed current value.
    private static func sigmaSyntheticEnum(forPropId propId: UInt32) -> [NSNumber]? {
        let group = (propId >> 24) & 0xFF
        let mask  = propId & 0xFFFF
        switch (group, mask) {
        case (0xF1, 0x0100):    // ShutterSpeed APEX × 8.
            // Coarse 1/3-EV grid covering 30 s through 1/8000 s. APEX
            // value for "X sec" = -log2(X) × 8, packed as uint8 with
            // signed wrap for slow shutter (e.g. 1" = -log2(1)×8 = 0;
            // 30" wraps via two's-complement to ~0xD9).
            return sigmaShutterApexStops.map { NSNumber(value: $0) }
        case (0xF1, 0x0200):    // Aperture APEX × 16.
            return sigmaApertureApexStops.map { NSNumber(value: $0) }
        case (0xF1, 0x1000):    // ISO APEX × 8 from ISO 100 = 40.
            return sigmaIsoApexStops.map { NSNumber(value: $0) }
        case (0xF1, 0x2000):    // ExpComp (signed int8 / 8 EV).
            // ±3 EV in 1/3-stop steps, plus 0.
            return sigmaExpCompApexStops.map { NSNumber(value: $0) }
        case (0xF2, 0x0100):    // DriveMode
            return Array(1...7).map { NSNumber(value: UInt8($0)) }
        case (0xF2, 0x0400):    // ExposureMode (P/A/S/M)
            return Array(1...4).map { NSNumber(value: UInt8($0)) }
        case (0xF2, 0x0800):    // AEMeteringMode
            return Array(1...3).map { NSNumber(value: UInt8($0)) }
        case (0xF2, 0x0020):    // WhiteBalance — codes from sigma-ptpy
            return Array(1...13).map { NSNumber(value: UInt8($0)) }
        case (0xF2, 0x0080):    // ImageQuality
            return [0x02, 0x04, 0x08, 0x10, 0x12, 0x14, 0x18].map { NSNumber(value: UInt8($0)) }
        case (0xF3, 0x1000):    // ColorMode (0x00..0x0F)
            return Array(0...0x0F).map { NSNumber(value: UInt8($0)) }
        case (0xF3, 0x0800):    // ColorSpace (0=sRGB, 1=AdobeRGB)
            return [0, 1].map { NSNumber(value: UInt8($0)) }
        default:
            return nil
        }
    }

    // MARK: - Property set (Sigma SetCamDataGroup*)

    /// Inverse of `parseDataGroupResponse`. Builds a SetCamDataGroup
    /// payload with exactly one field set in the FieldPresent bitfield,
    /// then sends it via the matching SetCamDataGroup opcode.
    ///
    /// Wire format mirrors the read side:
    ///   [_Header:1=0] [FieldPresent:2 BE] [field value: 1-2 bytes] [_Parity:1=0]
    /// sigma-ptpy hard-codes both _Header and _Parity to 0, suggesting the
    /// firmware doesn't actually validate them — we match that convention.
    override func performPropertySet(_ pending: PendingSet) {
        let group   = (pending.propId >> 24) & 0xFF
        let mask    = UInt16(pending.propId & 0xFFFF)

        let getOpcode:  UInt16
        let setOpcode:  UInt16
        let fields:     [SigmaField]
        switch group {
        case 0xF1:
            getOpcode = PTP_CMD_SIGMA_GET_DATAGROUP1
            setOpcode = PTP_CMD_SIGMA_SET_DATAGROUP1
            fields    = sigmaDataGroup1Fields
        case 0xF2:
            getOpcode = PTP_CMD_SIGMA_GET_DATAGROUP2
            setOpcode = PTP_CMD_SIGMA_SET_DATAGROUP2
            fields    = sigmaDataGroup2Fields
        case 0xF3:
            getOpcode = PTP_CMD_SIGMA_GET_DATAGROUP3
            setOpcode = PTP_CMD_SIGMA_SET_DATAGROUP3
            fields    = sigmaDataGroup3Fields
        default:
            cameraLog.fault("Sigma performPropertySet: unknown group byte 0x\(String(group, radix: 16), privacy: .public) for propId 0x\(String(pending.propId, radix: 16), privacy: .public)")
            return
        }
        guard let field = fields.first(where: { $0.bitMask == mask }) else {
            cameraLog.fault("Sigma performPropertySet: no schema entry for mask 0x\(String(mask, radix: 16), privacy: .public) in group 0x\(String(group, radix: 16), privacy: .public)")
            return
        }
        guard supportedOps.contains(setOpcode) else {
            cameraLog.fault("Sigma SetCamDataGroup 0x\(String(setOpcode, radix: 16), privacy: .public) not advertised — drop set for \(field.name, privacy: .public)")
            return
        }

        // Build payload: header(0) + FieldPresent BE + value bytes + parity(0).
        var payload = Data()
        payload.append(0)                                              // _Header
        payload.append(UInt8((mask >> 8) & 0xFF))                       // FP hi
        payload.append(UInt8(mask & 0xFF))                              // FP lo
        if field.isUInt16 {
            payload.append(UInt8(pending.value & 0xFF))
            payload.append(UInt8((pending.value >> 8) & 0xFF))
        } else {
            payload.append(UInt8(pending.value & 0xFF))
        }
        payload.append(0)                                              // _Parity

        let cmd = transport.buildCommand(code: setOpcode)
        guard let (_, rsp) = try? transport.sendPtpCommand(cmd, outData: payload) else {
            cameraLog.fault("Sigma SetCamDataGroup transport error for \(field.name, privacy: .public)")
            return
        }
        let code = transport.responseCode(from: rsp)
        let hex = payload.map { String(format: "%02x", $0) }.joined(separator: " ")
        cameraLog.fault("Sigma SetCamDataGroup \(field.name, privacy: .public) = \(pending.value, privacy: .public) payload=\(hex, privacy: .public) → 0x\(String(code, radix: 16), privacy: .public)")
        guard code == PTP_RSP_OK else { return }

        // Re-fetch the whole group so the agent's menu sees the committed
        // state (Sigma sometimes adjusts adjacent fields — changing
        // aperture in S mode bumps shutter, etc.).
        var refreshed: [UInt32: UsbCameraProperty] = [:]
        fetchDataGroup(opcode: getOpcode, fields: fields, into: &refreshed)
        if !refreshed.isEmpty {
            for (k, v) in refreshed { discoveredProperties[k] = v }
            onPropertiesDiscovered?(refreshed)
        }
    }

    // MARK: - Live view (Sigma.GetViewFrame 0x902B)
    //
    // Sigma doesn't need an explicit "start LV" toggle — the camera ships
    // a fresh JPEG whenever 0x902B is invoked. The response payload
    // starts with a 10-byte vendor header, followed by the raw JPEG.

    override func startLiveViewSession() -> Bool {
        guard supportedOps.contains(PTP_CMD_SIGMA_GET_VIEW_FRAME) else {
            liveViewStartError = "Sigma fp doesn't advertise GetViewFrame (0x902B). Live view unavailable."
            return false
        }
        cameraLog.fault("Sigma live view: no explicit start needed; entering frame loop")
        return true
    }

    override func stopLiveViewSession() -> Bool {
        // No-op — Sigma doesn't have a counterpart stop opcode for 0x902B.
        // The frame stream ends when we stop polling. There's no
        // transport action to fail at, so always report success.
        return true
    }

    override func fetchOneFrame() throws -> Data? {
        let cmd = transport.buildCommand(code: PTP_CMD_SIGMA_GET_VIEW_FRAME)
        let (inData, rsp) = try transport.sendPtpCommand(cmd)
        let code = transport.responseCode(from: rsp)
        guard code == PTP_RSP_OK, let data = inData, data.count > 10 else { return nil }
        // Vendor header is 10 bytes (sigma-ptpy ViewFrame schema). The
        // payload that follows IS the JPEG. Defensive fall-through to
        // `extractJpegFromLiveViewData` covers bodies that prepend extra
        // bytes — it scans for an SOI marker.
        let trimmed = data.subdata(in: 10..<data.count)
        return extractJpegFromLiveViewData(trimmed) ?? trimmed
    }
}

// MARK: - Sigma synthetic enum tables (file-private)

/// Standard 1/3-EV shutter stops from 30 s to 1/8000 s in APEX×8 units.
/// Slower speeds map to signed-wrapped uint8 values: 1 s = APEX 0,
/// 2 s = APEX −8 (=0xF8), 30 s = APEX −39.2 (≈0xD9).
private let sigmaShutterApexStops: [UInt8] = {
    // Build from a (seconds, label) list and convert each to APEX×8.
    let seconds: [Double] = [
        30, 25, 20, 15, 13, 10, 8, 6, 5, 4, 3.2, 2.5, 2, 1.6, 1.3, 1,
        1/1.3, 1/1.6, 1/2, 1/2.5, 1/3.2, 1/4, 1/5, 1/6, 1/8, 1/10,
        1/13, 1/15, 1/20, 1/25, 1/30, 1/40, 1/50, 1/60, 1/80, 1/100,
        1/125, 1/160, 1/200, 1/250, 1/320, 1/400, 1/500, 1/640, 1/800,
        1/1000, 1/1250, 1/1600, 1/2000, 1/2500, 1/3200, 1/4000, 1/5000,
        1/6400, 1/8000,
    ]
    return seconds.map { s in
        let apex = -8.0 * log2(s)
        let rounded = Int(apex.rounded())
        return UInt8(truncatingIfNeeded: rounded)
    }
}()

/// 1/3-EV aperture stops from f/1.0 to f/22 in APEX×16 units.
private let sigmaApertureApexStops: [UInt8] = {
    let fNumbers: [Double] = [
        1.0, 1.1, 1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5,
        4.0, 4.5, 5.0, 5.6, 6.3, 7.1, 8.0, 9.0, 10.0, 11.0, 13.0, 14.0,
        16.0, 18.0, 20.0, 22.0,
    ]
    return fNumbers.map { f in
        let apex = 16.0 * log2(f)
        return UInt8(apex.rounded())
    }
}()

/// 1/3-EV ISO stops from 100 to 102400 in APEX×8 units.
/// APEX 40 = ISO 100; each +8 doubles the ISO.
private let sigmaIsoApexStops: [UInt8] = {
    let isos: [Double] = [
        100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250,
        1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800,
        16000, 20000, 25600, 32000, 40000, 51200, 64000, 80000, 102400,
    ]
    return isos.map { iso in
        let apex = 40.0 + 8.0 * log2(iso / 100.0)
        return UInt8(apex.rounded())
    }
}()

/// ±3 EV exposure compensation in 1/3-stop steps (signed int8 × 8).
/// Stored as two's-complement when packed in the schema's UInt8 slot.
private let sigmaExpCompApexStops: [UInt8] = {
    let evs: [Double] = stride(from: -3.0, through: 3.0, by: 1.0/3.0).map { $0 }
    return evs.map { ev in
        let apex = Int(round(ev * 8.0))
        return UInt8(truncatingIfNeeded: apex)
    }
}()

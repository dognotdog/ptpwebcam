// SupportedCameras.swift
// Shared lookup table — what make + model name corresponds to a given USB
// VID/PID. Compiled into all three targets (extension, agent, app) so each
// can render human-readable camera labels ("Sony A7S", "Nikon D800") without
// depending on the camera's USB descriptor name (which is often verbose,
// inconsistent, or empty).
//
// The vendor camera classes (PtpCameraNikon/Canon/Sony in the agent, and
// their UsbCamera counterparts in the extension) historically owned these
// tables separately. Keeping them in one place avoids drift and lets the
// extension publish friendly names to the app directly.

import Foundation

/// Identifies the **wire protocol family** a camera speaks, NOT its brand.
/// Brand identity is carried by `PtpKnownCamera.make` ("Leica D-LUX 7",
/// "Panasonic GH5") and rendered by `displayName(vid:pid:fallback:)`. This
/// enum is for code-routing only: which `UsbXxxCamera` subclass handles the
/// USB transactions, which vendor opcode/property tables apply in dumps,
/// which formatter to use, etc.
///
/// Note that one wire protocol can be spoken by multiple brands — e.g.
/// Leica D-LUX bodies are rebadged Panasonic Lumix bodies and use the same
/// `0x9402`/`0x9108` opcode family, so their `protocolFamily` is
/// `.panasonic` even though their `make` is "Leica". Disambiguation between
/// distinct families that happen to share a USB VID lives in
/// `protocolFamily(forVid:pid:)`.
enum ProtocolFamily {
    case nikon
    case sony
    case canon
    case fuji        // VID 0x04CB
    case olympus     // VID 0x07B4 (OM Digital Solutions inherits the ID)
    case panasonic   // VID 0x04DA — Panasonic Lumix and Leica D-LUX/SL legacy
    case pentax      // VID 0x25FB (modern Ricoh OUI; covers Pentax K + Ricoh GR)
    case leica       // VID 0x1A98 — modern Leica M / Q / SL bodies, standard PTP
    case sigma       // VID 0x1003 — Sigma fp / fp L, own opcode family
    case unknown
}

struct PtpKnownCamera {
    let make: String
    let model: String
    /// True if we've verified the camera works end-to-end with a real unit;
    /// false if it was added speculatively from a vendor's USB ID list.
    let confirmed: Bool
}

enum PtpKnownCameras {

    /// USB vendor IDs we recognise. Kept as named constants so per-vendor
    /// `registerCameras()` calls can derive their lists from `table` filtered
    /// by VID without re-stating the hex literal everywhere.
    static let vidNikon:     UInt16 = 0x04B0
    static let vidCanon:     UInt16 = 0x04A9
    static let vidSony:      UInt16 = 0x054C
    static let vidFuji:      UInt16 = 0x04CB
    static let vidOlympus:   UInt16 = 0x07B4
    static let vidPanasonic: UInt16 = 0x04DA
    /// Pentax K-series + Ricoh GR III/IIIx use this newer Ricoh OUI. Legacy
    /// Pentax Optio compacts are at 0x0A17 but we don't aim to support them.
    static let vidPentax:    UInt16 = 0x25FB
    /// Modern Leica bodies (M9 onwards, Q-series, SL-series). The legacy
    /// Leica D-LUX / V-Lux / C-Lux bodies share VID 0x04DA with Panasonic.
    static let vidLeica:     UInt16 = 0x1A98
    /// Sigma fp / fp L. Distinct vendor opcode family from Panasonic.
    static let vidSigma:     UInt16 = 0x1003

    /// VID/PID → (make, model). Key encoding: `(UInt32(vid) << 16) | pid`.
    static let table: [UInt32: PtpKnownCamera] = {
        var t: [UInt32: PtpKnownCamera] = [:]
        func add(_ vid: UInt16, _ make: String, _ entries: [(UInt16, String, Bool)]) {
            for (pid, model, confirmed) in entries {
                t[(UInt32(vid) << 16) | UInt32(pid)] =
                    PtpKnownCamera(make: make, model: model, confirmed: confirmed)
            }
        }

        // Nikon (0x04B0).
        add(0x04B0, "Nikon", [
            (0x041A, "D300", false), (0x041C, "D3", true),
            (0x0420, "D3X", false),  (0x0421, "D90", true),
            (0x0422, "D700", false), (0x0423, "D5000", false),
            (0x0424, "D3000", false),
            (0x0425, "D300S", false),(0x0426, "D3S", false),
            (0x0427, "D3100", false),
            (0x0428, "D7000", true), (0x0429, "D5100", true),
            (0x042A, "D800", true),  (0x042B, "D4", false),
            (0x042C, "D3200", true), (0x042D, "D600", true),
            (0x042E, "D800E", false),(0x042F, "D5200", true),
            (0x0430, "D7100", true), (0x0431, "D5300", false),
            (0x0432, "Df", false),   (0x0433, "D3300", true),
            (0x0434, "D610", false), (0x0435, "D4S", false),
            (0x0436, "D810", false), (0x0437, "D750", true),
            (0x0438, "D5500", true), (0x0439, "D7200", true),
            (0x043A, "D5", false),   (0x043B, "D810A", false),
            (0x043C, "D500", false), (0x043D, "D3400", true),
            (0x043F, "D5600", true), (0x0440, "D7500", true),
            (0x0441, "D850", false), (0x0442, "Z7", true),
            (0x0443, "Z6", true),    (0x0444, "Z50", true),
            (0x0445, "D3500", true), (0x0446, "D780", false),
            (0x0447, "D6", false),   (0x0448, "Z5", false),
            (0x044B, "Z7 II", false),(0x044C, "Z6 II", false),
            (0x044F, "Zfc", false),  (0x0450, "Z9", false),
            (0x0451, "Z8", true),    (0x0452, "Z30", false),
            (0x0453, "Zf", false),   (0x0454, "Z6 III", false),
            (0x0455, "Z50 II", false),
        ])

        // Canon (0x04A9).
        // The display layer turns these into "Canon <model>" via the shared
		// lookup.
        add(0x04A9, "Canon", [
            (0x3145, "450D", false), (0x3146, "40D", false),
            (0x317B, "1000D", false),(0x3199, "5D II", false),
            (0x319A, "7D", false),   (0x319B, "50D", false),
            (0x31CF, "500D", false), (0x31D0, "1D IV", false),
            (0x31EA, "550D", false), (0x3215, "60D", false),
            (0x3217, "1100D", false),(0x3218, "600D", false),
            (0x3219, "1DX", false),  (0x323A, "5D III", false),
            (0x323B, "650D", false), (0x323D, "M", false),
            (0x3250, "6D", true),    (0x3252, "1DC", false),
            (0x3253, "70D", false),  (0x3270, "100D", false),
            (0x3272, "700D", false), (0x3273, "M2", false),
            (0x327F, "1200D", false),(0x3280, "760D", false),
            (0x3281, "5D IV", false),(0x3292, "1DX II", false),
            (0x3294, "80D", false),  (0x3295, "5Ds", false),
            (0x3299, "M3", false),   (0x32A0, "M10", false),
            (0x32A1, "750D", false), (0x32AF, "5Ds-R", false),
            (0x32B4, "1300D", false),(0x32BB, "M5", false),
            (0x32C5, "M6", false),   (0x32C9, "800D", false),
            (0x32CA, "6D II", false),(0x32CB, "77D", false),
            (0x32CC, "200D", false), (0x32D1, "M100", false),
            (0x32D2, "M50", false),  (0x32D9, "4000D", false),
            (0x32DA, "R", false),    (0x32E1, "2000D", false),
            (0x32E2, "RP", false),   (0x32E7, "M6 II", false),
            (0x32E8, "1DX III", false),(0x32E9, "250D", false),
            (0x32EA, "90D", false),  (0x32EF, "M200", false),
            (0x32F1, "850D", false), (0x32F4, "R5", false),
            (0x32F5, "R6", false),   (0x32F7, "R7", false),
            (0x32F8, "R10", false),  (0x32F9, "M50 II", false),
            (0x32FC, "R3", false),   (0x3303, "R5 C", false),
            (0x330B, "R6 II", false),
            (0x330C, "R8", false),   (0x330D, "R50", false),
            (0x3312, "R100", false), (0x3313, "R1", false),
            (0x3314, "R5 II", false),
            (0x3320, "R50 V", false),
            (0x3323, "R6 III", false),
        ])

        // Sony (0x054C).
        // Each Sony body advertises two PIDs — the MTP-only one (camera in
        // mass-storage / phone-pairing mode) and the "Control" / "PC Control"
        // one (the PTP-tetherable mode we actually need). Only the latter
        // are listed below. A7R-IV is 0x0CCC; the earlier table mistakenly
        // assigned 0x0CE7 to the A1, but the real A1 PC-Control PID is 0x0D1C.
        add(0x054C, "Sony", [
            (0x094C, "A7", false),     (0x094D, "A7R", false),
            (0x094E, "A6000", false),  (0x0953, "A77 II", false),
            (0x0954, "A7S", true),     (0x0957, "A5100", false),
            (0x096F, "A7 III", false), // legacy, also reports as 0x0C34
            (0x079B, "A68", false),    (0x079C, "A6300", false),
            (0x079E, "A99 II", false), (0x07A4, "A6500", false),
            (0x0A6A, "A7 II", false),  (0x0A6B, "A7R II", false),
            (0x0A71, "A7S II", false),
            (0x0C2A, "A9", false),     (0x0C33, "A7R III", false),
            (0x0C34, "A7 III", false),
            (0x0CAA, "A6400", false),  (0x0CCC, "A7R IV", false),
            (0x0D10, "A6600", false),  (0x0D14, "A6100", false),
            (0x0D18, "A7S III", false),(0x0D1C, "A1", false),
            (0x0D2B, "A7C", false),    (0x0D97, "ZV-E10", false),
            (0x0D9B, "A7R IIIA", false),
            (0x0D9F, "A7R IVA", false),
            (0x0DA3, "FX3", false),    (0x0DA7, "A7 IV", false),
            (0x0E0C, "A7R V", false),  (0x0E78, "A6700", false),
            (0x0E80, "A9 III", false), (0x0E90, "ILX-LR1", false),
            (0x0EED, "A1 II", false),
        ])

        // Fujifilm (0x04CB). Modern X / GFX bodies that support USB PTP
        // tethering. Older FinePix / X-S1 / X10 etc. omitted — they're
        // mostly mass-storage-only and the dump pipeline can't claim them
        // anyway.
        add(0x04CB, "Fujifilm", [
            (0x02B5, "X-E2", false),   (0x02B6, "X-M1", false),
            (0x02CB, "X-Pro2", false), (0x02CD, "X-T2", false),
            (0x02D1, "X100F", false),  (0x02D3, "GFX 50S", false),
            (0x02D4, "X-T20", false),  (0x02D7, "X-H1", false),
            (0x02DC, "GFX 50R", false),(0x02DD, "X-T3", false),
            (0x02DE, "GFX 100", false),(0x02E3, "X-T30", false),
            (0x02E4, "X-Pro3", false), (0x02E5, "X100V", false),
            (0x02E6, "X-T4", false),
            (0x02E9, "GFX 100S", false),
            (0x02EA, "GFX 100S", false), // shared with X-S10 — webcam mode only
            (0x02F0, "X-H2S", false),
			(0x02F2, "X-H2", false),
            (0x02FC, "X-T5", false),
			(0x02FE, "GFX 100 II", false),
            (0x0305, "X100VI", false),
        ])

        // Olympus / OM Digital Solutions (0x07B4). The PID 0x0130 is shared
        // across E-M5 II, E-M1, and E-M1 Mark II; we
        // pick the most recognisable name. OM-1 onwards is OM Digital
        // Solutions branding but the VID is unchanged.
        add(0x07B4, "Olympus", [
            (0x012F, "E-M5", false),
			(0x0130, "E-M?", false),
            (0x0135, "E-M1 Mark II", false),
            (0x0136, "OM-1", false),
        ])

        // Panasonic Lumix (0x04DA). PIDs are notoriously over-shared across
        // bodies — 0x2382 covers the entire DC-/S-series
        // lineup. We list the well-known PTP-tetherable bodies; everything
        // else falls back to "Lumix <model>" via the USB descriptor name.
        // NB: Panasonic doesn't honour standard GetDevicePropDesc — see
        // `dumpViaPanasonicHandshake` in PtpDumper.
        add(0x04DA, "Panasonic", [
            (0x2374, "DMC-GX8", false),
            (0x2382, "DC-GH5", false),
        ])

        // Pentax K-series + Ricoh GR (modern Ricoh OUI 0x25FB).
        add(0x25FB, "Pentax", [
            (0x0165, "K-3", false),
			(0x0179, "K-1", false),
        ])
        // Ricoh GR III / IIIx share the same vendor block. We label them
        // under "Ricoh" so they don't say "Pentax GR III" in the menu.
        t[(UInt32(0x25FB) << 16) | 0x210F] = PtpKnownCamera(make: "Ricoh", model: "GR III", confirmed: false)
        t[(UInt32(0x25FB) << 16) | 0x2115] = PtpKnownCamera(make: "Ricoh", model: "GR IIIx", confirmed: false)

        // Legacy Leica bodies on VID 0x04DA — these are rebadged Panasonic
        // Lumix cameras and speak the Panasonic wire protocol, so they get
        // routed to `UsbPanasonicCamera` by `protocolFamily(forVid:pid:)`.
        // The menu label still says "Leica" because that's the brand stamp.
        add(0x04DA, "Leica", [
            (0x2041, "SL (Typ 601, USB-shared variant)", false),
            (0x2375, "D-LUX 2", false),
        ])

        // Modern Leica bodies on Leica's own VID 0x1A98. Standard PTP — the
        // `UsbLeicaCamera` scaffold just inherits the base class default.
        add(0x1A98, "Leica", [
            (0x0002, "M9", false),
            (0x2041, "SL (Typ 601)", false),
            (0x2083, "M11 Monochrom", false),
            (0x2376, "Q3", false),
            (0x2382, "SL3", false),
        ])

        // Sigma fp / fp L on Sigma's own VID 0x1003.
        add(0x1003, "Sigma", [
            (0xC432, "fp", false),
            (0xC442, "fp L", false),
        ])

        return t
    }()

    static func lookup(vid: UInt16, pid: UInt16) -> PtpKnownCamera? {
        return table[(UInt32(vid) << 16) | UInt32(pid)]
    }

    /// Map a (VID, PID) pair to its wire-protocol family. PID is required
    /// because some VIDs cover multiple protocol families (notably Panasonic
    /// 0x04DA, which historically also hosted some Leica D-LUX rebadges) and
    /// future bodies may need finer routing.
    ///
    /// Brand identity (Leica vs Panasonic vs Sigma) is NOT decided here —
    /// it's pulled from the per-PID `PtpKnownCamera.make` field by
    /// `displayName(vid:pid:fallback:)`. This function is purely about
    /// which `UsbXxxCamera` subclass should drive the USB transactions.
    static func protocolFamily(forVid vid: UInt16, pid: UInt16) -> ProtocolFamily {
        switch vid {
        case vidNikon:     return .nikon
        case vidCanon:     return .canon
        case vidSony:      return .sony
        case vidFuji:      return .fuji
        case vidOlympus:   return .olympus
        case vidPanasonic: return .panasonic   // Leica D-LUX bodies fall here
                                                // too — they're rebadged
                                                // Panasonic firmware.
        case vidPentax:    return .pentax
        case vidLeica:     return .leica
        case vidSigma:     return .sigma
        default:           return .unknown
        }
    }

    /// Return every (productId, model, confirmed) tuple for a given vendor,
    /// in the shape expected by `PtpCamera.register(vendorId:cameras:...)`.
    /// Lets each vendor camera class express its registration as
    /// `PtpKnownCameras.entries(forVendor: 0x054C)` instead of restating the
    /// product table — single source of truth in `table` above.
    static func entries(forVendor vid: UInt16) -> [(productId: UInt16, model: String, confirmed: Bool)] {
        return table.compactMap { (key, info) in
            guard UInt16(key >> 16) == vid else { return nil }
            return (productId: UInt16(key & 0xFFFF),
                    model: info.model,
                    confirmed: info.confirmed)
        }
    }

    // MARK: - PTP code-name tables
    //
    // Small lookup tables for the standard PTP opcodes / events / properties
    // plus a handful of well-known vendor extensions. Used by the PTP dump
    // formatter (live in PtpDumper, cached in UsbPtpCameraBase). Anything not
    // in these tables renders as a bare hex code — the dump still works,
    // it's just less readable.

    /// Standard PTP operations (always meaningful, vendor-agnostic).
    private static let standardOperationNames: [UInt16: String] = [
        0x1001: "GetDeviceInfo",        0x1002: "OpenSession",
        0x1003: "CloseSession",         0x1004: "GetStorageIDs",
        0x1005: "GetStorageInfo",       0x1006: "GetNumObjects",
        0x1007: "GetObjectHandles",     0x1008: "GetObjectInfo",
        0x1009: "GetObject",            0x100A: "GetThumb",
        0x100B: "DeleteObject",         0x100C: "SendObjectInfo",
        0x100D: "SendObject",           0x100E: "InitiateCapture",
        0x100F: "FormatStore",          0x1010: "ResetDevice",
        0x1011: "SelfTest",             0x1012: "SetObjectProtection",
        0x1013: "PowerDown",            0x1014: "GetDevicePropDesc",
        0x1015: "GetDevicePropValue",   0x1016: "SetDevicePropValue",
        0x1017: "ResetDevicePropValue", 0x1018: "TerminateOpenCapture",
        0x1019: "MoveObject",           0x101A: "CopyObject",
        0x101B: "GetPartialObject",     0x101C: "InitiateOpenCapture",
    ]

    /// Per-vendor opcode tables. Same numeric code means very different things
    /// across vendors — e.g. 0x9202 is `GetSDIOExtDeviceInfo` on Sony but a
    /// totally unrelated command on Nikon — so we keep them strictly
    /// partitioned. An entry only renders if the caller passed the matching
    /// `ProtocolFamily`.
    private static let nikonOperationNames: [UInt16: String] = [
        0x9006: "Nikon.GetProfileAllData",
        0x9201: "Nikon.Capture",        0x9206: "Nikon.DeviceReady",
        0x9207: "Nikon.SetProfileAll",  0x9208: "Nikon.AfDrive",
        0x90C0: "Nikon.GetLiveViewImg", 0x90C1: "Nikon.MfDrive",
        0x90C2: "Nikon.StartLiveView",  0x90C3: "Nikon.StopLiveView",
        0x90C4: "Nikon.GetVendorPropertyCodes",
        0x9805: "Nikon.GetVendorPropCodes",
    ]
    private static let sonyOperationNames: [UInt16: String] = [
        0x9201: "Sony.SDIOConnect",          0x9202: "Sony.GetSDIOExtDeviceInfo",
        0x9203: "Sony.GetDevicePropDesc",    0x9205: "Sony.SetDevicePropValue",
        0x9207: "Sony.SetControlDeviceB",    0x9209: "Sony.GetAllDevicePropData",
        0x920A: "Sony.SetControlDeviceA",
    ]
    private static let canonOperationNames: [UInt16: String] = [
        0x9101: "Canon.GetStorageIDs",       0x9110: "Canon.SetDevicePropValueEx",
        0x9114: "Canon.SetRemoteMode",       0x9115: "Canon.SetEventMode",
        0x9116: "Canon.GetEvent",            0x9127: "Canon.RequestPropertyValue",
        0x9128: "Canon.RemoteRelease",       0x911D: "Canon.KeepDeviceOn",
        0x913D: "Canon.SetRequestOLCInfoGroup",
        0x9151: "Canon.GetViewfinderImage",  0x9153: "Canon.GetViewfinderData",
    ]
    // Fuji-specific opcodes are sparsely known — most use standard
    // PTP. Worth labelling the FUJIPTPIP variant in case it shows up.
    private static let fujiOperationNames: [UInt16: String] = [
        0x9054: "Fuji.SetDPC",          0x9056: "Fuji.GetDevicePropValueEx",
        0x9085: "Fuji.GetObjectInfoEx",
    ]
    // Olympus E-series uses XML-wrapped PTP; the wrappers are 0x9482/0x9483.
    // Modern OM-1 uses these for SetDateTime / GetTime.
    private static let olympusOperationNames: [UInt16: String] = [
        0x9482: "Olympus.SetDateTime",  0x9483: "Olympus.GetCameraInfo",
    ]
    // Panasonic's command family is the big one — they replaced the
    // standard property protocol entirely.
    private static let panasonicOperationNames: [UInt16: String] = [
        0x9101: "Panasonic.ComponentsConfiguration",
		0x9102: "Panasonic.OpenSession",
        0x9103: "Panasonic.CloseSession",
		0x9104: "Panasonic.GetExtDeviceId",
        0x9107: "Panasonic.GetSize",
		0x9108: "Panasonic.ListProperty",
        0x9110: "Panasonic.GetObjectInfos",
        0x9112: "Panasonic.GetPartialObject",
		0x9113: "Panasonic.SkipObjectsTransfer",
        0x9402: "Panasonic.GetProperty",
        0x9403: "Panasonic.SetProperty",
		0x9404: "Panasonic.InitiateCapture",
        0x9405: "Panasonic.RecCtrlAfAe",
		0x9406: "Panasonic.SetupCtrl",
        0x9412: "Panasonic.GetLiveViewImage",
    ]
    // Pentax/Ricoh: standard PTP for K-series. Empty for now —
    // K1/K3 don't expose vendor-specific opcodes we care about.
    private static let pentaxOperationNames: [UInt16: String] = [:]
    // Modern Leica (VID 0x1A98). Mostly standard PTP. Legacy Leica bodies
    // sharing VID 0x04DA are dispatched as `.panasonic` instead so this
    // table doesn't see them.
    private static let leicaOperationNames: [UInt16: String] = [:]
    // Sigma fp / fp L. Vendor opcode family is its own — none of these
    // numbers overlap with the meanings they have on other vendors.
    private static let sigmaOperationNames: [UInt16: String] = [
        0x9035: "Sigma.GetCamCanSetInfo",
        0x9038: "Sigma.GetCamCaptStatus",
        0x9039: "Sigma.GetCamDataGroupFocus",
        0x9412: "Sigma.GetCamViewFrame",
        0x9035: "Sigma.GetCamConfig",
        0x9050: "Sigma.SetCamDataGroup1",
        0x9051: "Sigma.SetCamDataGroup2",
        0x9052: "Sigma.SetCamDataGroup3",
        0x9053: "Sigma.SetCamDataGroup4",
        0x905E: "Sigma.SnapCommand",
        0x9070: "Sigma.ClearImageDBSingle",
        0x9071: "Sigma.ClearImageDBAll",
    ]

    static func operationName(_ op: UInt16, vendor: ProtocolFamily = .unknown) -> String {
        if let n = standardOperationNames[op] { return n }
        switch vendor {
        case .nikon:     if let n = nikonOperationNames[op]     { return n }
        case .sony:      if let n = sonyOperationNames[op]      { return n }
        case .canon:     if let n = canonOperationNames[op]     { return n }
        case .fuji:      if let n = fujiOperationNames[op]      { return n }
        case .olympus:   if let n = olympusOperationNames[op]   { return n }
        case .panasonic: if let n = panasonicOperationNames[op] { return n }
        case .pentax:    if let n = pentaxOperationNames[op]    { return n }
        case .leica:     if let n = leicaOperationNames[op]     { return n }
        case .sigma:     if let n = sigmaOperationNames[op]     { return n }
        case .unknown: break
        }
        // Don't pretend to know vendor codes when we don't know which vendor.
        if op >= 0x9000 { return String(format: "Vendor.0x%04X", op) }
        return String(format: "(0x%04X)", op)
    }

    /// Standard PTP events. Vendors define their own 0xCxxx codes but those
    /// rarely show up in dumps (they ride the interrupt-IN pipe, not the
    /// GetDeviceInfo `EventsSupported` array).
    static func eventName(_ ev: UInt16, vendor: ProtocolFamily = .unknown) -> String {
        let standard: [UInt16: String] = [
            0x4001: "CancelTransaction", 0x4002: "ObjectAdded",
            0x4003: "ObjectRemoved",     0x4004: "StoreAdded",
            0x4005: "StoreRemoved",      0x4006: "DevicePropChanged",
            0x4007: "ObjectInfoChanged", 0x4008: "DeviceInfoChanged",
            0x4009: "RequestObjectTransfer", 0x400A: "StoreFull",
            0x400B: "DeviceReset",       0x400C: "StorageInfoChanged",
            0x400D: "CaptureComplete",   0x400E: "UnreportedStatus",
        ]
        if let n = standard[ev] { return n }
        _ = vendor  // reserved for future vendor-event tables
        if ev >= 0xC000 { return String(format: "Vendor.0x%04X", ev) }
        return String(format: "(0x%04X)", ev)
    }

    /// Standard PTP device properties (0x5001..0x501F — common to every PTP
    /// implementation).
    private static let standardPropertyNames: [UInt16: String] = [
        0x5001: "BatteryLevel",         0x5002: "FunctionalMode",
        0x5003: "ImageSize",            0x5004: "CompressionSetting",
        0x5005: "WhiteBalance",         0x5006: "RGBGain",
        0x5007: "FNumber",              0x5008: "FocalLength",
        0x5009: "FocusDistance",        0x500A: "FocusMode",
        0x500B: "ExposureMeteringMode", 0x500C: "FlashMode",
        0x500D: "ExposureTime",         0x500E: "ExposureProgramMode",
        0x500F: "ExposureIndex",        0x5010: "ExposureBiasCompensation",
        0x5011: "DateTime",             0x5012: "CaptureDelay",
        0x5013: "StillCaptureMode",     0x5014: "Contrast",
        0x5015: "Sharpness",            0x5016: "DigitalZoom",
        0x5017: "EffectMode",           0x5018: "BurstNumber",
        0x5019: "BurstInterval",        0x501A: "TimelapseNumber",
        0x501B: "TimelapseInterval",    0x501C: "FocusMeteringMode",
        0x501D: "UploadURL",            0x501E: "Artist",
        0x501F: "CopyrightInfo",
    ]
    private static let nikonPropertyNames: [UInt16: String] = [
        0xD100: "Nikon.ShutterSpeed",        0xD150: "Nikon.WbTune",
        0xD1A8: "Nikon.ShutterSpeedB",       0xD1AB: "Nikon.ExposureBias",
        0xD17B: "Nikon.LiveViewStatus",
    ]
    private static let sonyPropertyNames: [UInt16: String] = [
        0xD20D: "Sony.ShutterSpeed",         0xD20F: "Sony.WhiteBalanceColorTemp",
        0xD210: "Sony.WbFineTune",           0xD212: "Sony.AutoFocusFlag",
        0xD213: "Sony.AfStatus",             0xD215: "Sony.FocusStatus",
        0xD218: "Sony.BatteryLevel",         0xD21C: "Sony.ColorTuneB",
        0xD21E: "Sony.ISO",                  0xD2C1: "Sony.AutofocusTrigger",
    ]
    /// Fuji vendor property codes — overlap heavily with standard PTP
    /// (Fuji honours GetDevicePropDesc directly).
    private static let fujiPropertyNames: [UInt16: String] = [
        0xD002: "Fuji.FilmSimulation",     0xD17C: "Fuji.AfMode",
    ]
    /// Olympus modern (OM-1 etc.) — sparse, just placeholders.
    private static let olympusPropertyNames: [UInt16: String] = [:]
    /// Pentax K-series — placeholders.
    private static let pentaxPropertyNames: [UInt16: String] = [:]
    /// Panasonic's property codes are 32-bit (e.g. 0x02000010) which doesn't
    /// fit our 16-bit lookup. Their dump path stores names separately.
    /// Leaving this map empty so standard 16-bit lookups don't accidentally
    /// match Canon's 0xD1xx codes against a Panasonic dump.
    private static let panasonicPropertyNames: [UInt16: String] = [:]
    /// Modern Leica — standard PTP, no vendor properties cataloged yet.
    private static let leicaPropertyNames: [UInt16: String] = [:]
    /// Sigma fp — placeholders, vendor properties not cataloged yet.
    private static let sigmaPropertyNames: [UInt16: String] = [:]

    private static let canonPropertyNames: [UInt16: String] = [
        0xD101: "Canon.Aperture",            0xD102: "Canon.ShutterSpeed",
        0xD103: "Canon.ISO",                 0xD104: "Canon.ExposureBias",
        0xD105: "Canon.AutoExposure",        0xD107: "Canon.MeteringMode",
        0xD108: "Canon.FocusMode",           0xD10A: "Canon.WhiteBalance",
        0xD129: "Canon.PictureStyle",        0xD12C: "Canon.LvEyeDetect",
        0xD1A9: "Canon.Aperture",            0xD1AF: "Canon.EOS.SerialNumber",
        0xD1B0: "Canon.EVF.OutputDevice",    0xD1B1: "Canon.EVF.Mode",
        0xD1B2: "Canon.EVF.DepthOfFieldPreview",
        0xD1B4: "Canon.EVF.WhiteBalance",    0xD1B6: "Canon.EVF.ColorTemperature",
        0xD1B7: "Canon.EVF.ExposurePreview",
    ]

    static func propertyName(_ pid: UInt16, vendor: ProtocolFamily = .unknown) -> String {
        if let n = standardPropertyNames[pid] { return n }
        switch vendor {
        case .nikon:     if let n = nikonPropertyNames[pid]     { return n }
        case .sony:      if let n = sonyPropertyNames[pid]      { return n }
        case .canon:     if let n = canonPropertyNames[pid]     { return n }
        case .fuji:      if let n = fujiPropertyNames[pid]      { return n }
        case .olympus:   if let n = olympusPropertyNames[pid]   { return n }
        case .panasonic: if let n = panasonicPropertyNames[pid] { return n }
        case .pentax:    if let n = pentaxPropertyNames[pid]    { return n }
        case .leica:     if let n = leicaPropertyNames[pid]     { return n }
        case .sigma:     if let n = sigmaPropertyNames[pid]     { return n }
        case .unknown: break
        }
        if pid >= 0xD000 { return String(format: "Vendor.0x%04X", pid) }
        return String(format: "(0x%04X)", pid)
    }

    // MARK: - Panasonic-specific 32-bit property names
    //
    // Panasonic uses 32-bit property codes (e.g. 0x02000010 PhotoStyle), not
    // the 16-bit codes the rest of PTP uses. They come back through the
    // 0x9108 ListProperty / 0x9402 GetProperty opcodes. Separate lookup so
    // we can label them in dumps without polluting the 16-bit table.
    static func panasonicPropertyName32(_ pid: UInt32) -> String {
        let names: [UInt32: String] = [
            0x02000010: "PhotoStyle",
            0x02000020: "ISO",
            0x02000021: "ISO.Param",       0x02000022: "ISO.UpperLimit",
            0x02000030: "ShutterSpeed",
            0x02000031: "ShutterSpeed.Param", 0x02000032: "ShutterSpeed.RangeLimit",
            0x02000040: "Aperture",
            0x02000041: "Aperture.Param",  0x02000042: "Aperture.RangeLimit",
            0x02000050: "WhiteBalance",
            0x02000051: "WhiteBalance.Param",
            0x02000052: "WhiteBalance.KSet",
            0x02000053: "WhiteBalance.ADJ_AB",
            0x02000054: "WhiteBalance.ADJ_GM",
            0x02000055: "WhiteBalance.ADJ_AB_Sep",
            0x02000060: "Exposure",
            0x02000061: "Exposure.Param",  0x02000062: "Exposure.RangeLimit",
            0x02000070: "AFArea",
            0x02000071: "AFArea.AFModeParam",
            0x02000072: "AFArea.AFAreaParam",
            0x02000073: "AFArea.SetQuickAFParam",
            0x02000080: "CameraMode",
            0x02000081: "CameraMode.DriveMode",
            0x02000082: "CameraMode.ModePos",
            0x02000083: "CameraMode.CreativeMode",
            0x02000084: "CameraMode.iAMode",
            0x020000A2: "ImageFormat",
            0x020000B0: "MeteringInfo",
        ]
        return names[pid] ?? String(format: "Panasonic.0x%08X", pid)
    }

    static func dataTypeName(_ dt: UInt16) -> String {
        switch dt {
        case 0x0000: return "Undefined"
        case 0x0001: return "INT8"
        case 0x0002: return "UINT8"
        case 0x0003: return "INT16"
        case 0x0004: return "UINT16"
        case 0x0005: return "INT32"
        case 0x0006: return "UINT32"
        case 0x0007: return "INT64"
        case 0x0008: return "UINT64"
        case 0xFFFF: return "STR"
        default:     return String(format: "0x%04X", dt)
        }
    }

    static func vendorExtensionName(_ id: UInt32) -> String {
        switch id {
        case 0x0000_0000: return "(none)"
        case 0x0000_0006: return "Microsoft / MTP"
        case 0x0000_000A: return "Nikon"
        case 0x0000_000B: return "Microsoft (Sony reuses)"
        case 0x0000_000C: return "Canon"
        case 0x0000_0011: return "Sony"
        case 0x0000_0013: return "Fuji"
        default:          return String(format: "(0x%08X)", id)
        }
    }

    /// Friendly label, in priority order:
    ///   1. "<Make> <Model>" if VID/PID is in our table.
    ///   2. Trimmed USB descriptor product name, if non-empty.
    ///   3. "USB <vid>:<pid>" hex fallback.
    static func displayName(vid: UInt16, pid: UInt16, fallback: String) -> String {
        if let known = lookup(vid: vid, pid: pid) {
            return "\(known.make) \(known.model)"
        }
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return String(format: "USB %04X:%04X", vid, pid)
    }
}

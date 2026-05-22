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
            (0x32F5, "R6", false),   (0x32F7, "R7", true),
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

        // Panasonic Lumix (0x04DA). Panasonic uses a single PID per
        // generational family, so multiple bodies report the same PID. We
        // pick a generic label that's accurate for the whole bucket — the
        // USB descriptor name (which displayName(_:fallback:) falls back
        // to) usually carries the specific model.
        //
        // Panasonic's own LUMIX Tether
        // software supports the same bodies (DC-S1/S1H/S1R/S5/S5 II,
        // DC-GH5/GH5S/GH5 II/GH6, DC-G9/G9 II, DC-BGH1, DC-BS1H) all
        // through the single PID 0x2382.
        //
        // NB: Panasonic doesn't honour standard GetDevicePropDesc — see
        // `dumpViaPanasonicHandshake` in PtpDumper.
        add(0x04DA, "Panasonic", [
            // 0x2372 — legacy point-and-shoot compacts (DMC-FZ20 alternate,
            // DMC-LC1, DMC-LZ2, Lumix FZ5). Mass-storage only; no PTP
            // control / preview. Listed so the menu doesn't say "USB 04DA:2372".
            (0x2372, "Lumix (legacy compact)", false),

            // 0x2374 — early mirrorless + mid-2010s compacts. Covers
            // DMC-GX8 and DMC-GF1 on the mirrorless side, plus DMC-FZ20/38/45/50,
            // DMC-LS2/LS3, DMC-LX7, DMC-TZ8/15/18, DMC-FS62 compacts.
            // Only GX8 advertises PTP preview/capture;
            // the rest are mass-storage-only.
            (0x2374, "Lumix G/GX/DMC-series", false),

            // 0x2382 — the entire modern Panasonic Lumix DC-line. Covers
            // DC-GH5/5S/5 II/6/7, DC-G9/G9 II, DC-S1/1H/1R/5/5 II/5 IIX/9,
            // DC-BGH1, DC-BS1H, and likely later bodies. The specific model
            // is recoverable from GetDeviceInfo if needed.
            (0x2382, "Lumix DC-series", false),
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

    /// VID/PID pairs where the USB descriptor's product name is more
    /// specific than what `table` carries (because multiple body models
    /// share the same PID and we registered a generic group label).
    ///
    /// For these entries `displayName(vid:pid:fallback:)` flips priority:
    /// it prefers the USB descriptor name (which Panasonic / Olympus
    /// populate with the specific body, e.g. "DC-GH5", "E-510") and uses
    /// `table[…].make` only as a brand prefix when the descriptor name
    /// doesn't already include it.
    ///
    /// Keep this small — adding a PID here ONLY makes sense when the
    /// table label is intentionally a generic group ("Lumix DC-series")
    /// rather than a specific model name. For per-body PIDs (most Nikon /
    /// Canon / Sony) the table is more reliable than what the USB
    /// descriptor often spells (e.g. Sony's "ILCE-7S" → "A7S").
    static let sharedPids: Set<UInt32> = [
        // Panasonic Lumix — three PIDs cover dozens of bodies between them.
        (UInt32(vidPanasonic) << 16) | 0x2372,
        (UInt32(vidPanasonic) << 16) | 0x2374,
        (UInt32(vidPanasonic) << 16) | 0x2382,
        // Olympus E-series — single PID 0x0110 covers E-410/420/510/520/3/5/30/620.
        (UInt32(vidOlympus) << 16) | 0x0110,
        // Olympus E-M family — E-M5 II, E-M1, and
        // E-M1 II all at 0x0130. Newer OM-1 (0x0136) has its own PID.
        (UInt32(vidOlympus) << 16) | 0x0130,
    ]

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
    // Fuji X / GFX. Live view rides standard PTP InitiateOpenCapture (0x101C
    // from the standard table above) plus these Fuji-specific opcodes.
    private static let fujiOperationNames: [UInt16: String] = [
        0x9020: "Fuji.InitiateMovieCapture",
        0x9021: "Fuji.TerminateMovieCapture",
        0x9022: "Fuji.GetCapturePreview",
        0x9026: "Fuji.SetFocusPoint",     // a.k.a. LockS1Lock
        0x9027: "Fuji.ResetFocusPoint",   // a.k.a. UnlockS1Lock
        0x902B: "Fuji.GetDeviceInfo",
        0x902C: "Fuji.SetShutterSpeed",   // a.k.a. StepShutterSpeed
        0x902D: "Fuji.SetAperture",       // a.k.a. StepFNumber
        0x902E: "Fuji.SetExposureCompensation", // StepExposureBias
        0x9030: "Fuji.CancelInitiateCapture",    // stops live view
        0x9040: "Fuji.FmSendObjectInfo",
        0x9041: "Fuji.FmSendObject",
        0x9042: "Fuji.FmSendPartialObject",
        0x9054: "Fuji.SetDPC",
        0x9056: "Fuji.GetDevicePropValueEx",
        0x9085: "Fuji.GetObjectInfoEx",
    ]
    // Olympus modern + OMD live-view path. E-series uses XML-wrapped PTP
    // (PtpKnownCameras.sharedPids 0x07B4:0x0110) which only exposes a
    // handful of these opcodes through its envelope. Numbers from
    private static let olympusOperationNames: [UInt16: String] = [
        0x9101: "Olympus.Capture",
        0x9103: "Olympus.SelfCleaning",
        0x9106: "Olympus.SetRGBGain",
        0x9107: "Olympus.SetPresetMode",
        0x9108: "Olympus.SetWBBiasAll",
        0x910A: "Olympus.GetCameraControlMode",
        0x910B: "Olympus.SetCameraControlMode",
        0x910C: "Olympus.SetWBRGBGain",
        0x9301: "Olympus.GetDeviceInfo",
        0x9302: "Olympus.OpenSession",
        0x9402: "Olympus.SetDateTime",
        0x9481: "Olympus.OMD.Capture",
        0x9482: "Olympus.GetDateTime",
        0x9484: "Olympus.GetLiveViewImage",   // OMD live-view frame fetch
        0x9485: "Olympus.OMD.GetImage",
        0x9486: "Olympus.OMD.ChangedProperties",
        0x9487: "Olympus.OMD.MFDrive",
        0x9489: "Olympus.OMD.SetProperties",
        0x9501: "Olympus.SetCameraID",
        0x9581: "Olympus.GetCameraID",
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
        // 0x9412 is the live-view ON/OFF toggle, NOT the frame fetch
        // (despite an outdated comment in our earlier code). Frame fetch
        // is 0x9706 below.
        0x9412: "Panasonic.LiveviewToggle",
        0x9415: "Panasonic.SetLiveViewParameters",
        0x9706: "Panasonic.LiveviewImage",
    ]
    // Pentax/Ricoh: standard PTP for K-series. Empty for now —
    // K1/K3 don't expose vendor-specific opcodes we care about.
    private static let pentaxOperationNames: [UInt16: String] = [:]
    // Modern Leica (VID 0x1A98). Mostly standard PTP. Legacy Leica bodies
    // sharing VID 0x04DA are dispatched as `.panasonic` instead so this
    // table doesn't see them.
    // Modern Leica M / Q / SL family. Standard PTP for discovery + property
    // setting; vendor opcodes for the live-view stream and a few extras.
    private static let leicaOperationNames: [UInt16: String] = [
        0x9001: "Leica.SetCameraSettings",
        0x9002: "Leica.GetCameraSettings",
        0x9003: "Leica.GetLensParameter",
        0x9004: "Leica.LEReleaseStages",       // 1=push AF, 2=release AF, etc.
        0x9005: "Leica.LEOpenSession",
        0x9006: "Leica.LECloseSession",
        0x9007: "Leica.RequestObjectTransferReady",
        0x9008: "Leica.GetGeoTrackingData",
        0x900A: "Leica.OpenDebugSession",
        0x900B: "Leica.CloseDebugSession",
        0x900C: "Leica.GetDebugBuffer",
        0x900D: "Leica.DebugCommandString",
        0x900E: "Leica.GetDebugRoute",
        0x900F: "Leica.SetIPTCData",
        0x9010: "Leica.GetIPTCData",
        0x9016: "Leica.LEControlAutoFocus",
        0x9019: "Leica.LEControlBulbExposure",
        0x901A: "Leica.LEControlContinuousExposure",
        0x901B: "Leica.901b",                  // related to shutter release
        0x901C: "Leica.LEControlPhotoLiveView",
        0x901D: "Leica.LEKeepSessionActive",
        0x901E: "Leica.LEMoveLens",
        0x9020: "Leica.Get3DAxisData",
        0x9021: "Leica.LESetZoomMode",
        0x9022: "Leica.LESetFocusCrossPosition",
        0x9025: "Leica.LEGetStreamData",       // live-view frame fetch
    ]
    // Sigma fp / fp L. Vendor opcode family is its own — none of these
    // numbers overlap with the meanings they have on other vendors.
    // Source: https://github.com/makanikai/sigma-ptpy sigma_ptp.py.
    private static let sigmaOperationNames: [UInt16: String] = [
        0x9012: "Sigma.GetCamDataGroup1",  // exposure (shutter/aperture/ISO/EVbias)
        0x9013: "Sigma.GetCamDataGroup2",  // mode (drive/exposure/meter/flash/WB)
        0x9014: "Sigma.GetCamDataGroup3",  // colour + lens focal lengths
        0x9015: "Sigma.GetCamCaptStatus",
        0x9016: "Sigma.SetCamDataGroup1",
        0x9017: "Sigma.SetCamDataGroup2",
        0x9018: "Sigma.SetCamDataGroup3",
        0x9019: "Sigma.SetCamClockAdj",
        0x901B: "Sigma.SnapCommand",
        0x901C: "Sigma.ClearImageDBSingle",
        0x9022: "Sigma.GetBigPartialPictFile",
        0x9023: "Sigma.GetCamDataGroup4",  // DC crop / LV magnify / HDR
        0x9024: "Sigma.SetCamDataGroup4",
        0x9027: "Sigma.GetCamDataGroup5",  // interval timer / Kelvin / aspect
        0x9028: "Sigma.SetCamDataGroup5",
        0x9029: "Sigma.GetLastCommandData",
        0x902A: "Sigma.FreeArrayMemory",
        0x902B: "Sigma.GetViewFrame",      // live-view JPEG fetch
        0x902D: "Sigma.GetPictFileInfo2",
        0x902F: "Sigma.CloseApplication",
        0x9030: "Sigma.GetCamCanSetInfo5",
        0x9031: "Sigma.GetCamDataGroupFocus",
        0x9032: "Sigma.SetCamDataGroupFocus",
        0x9033: "Sigma.GetCamDataGroupMovie",
        0x9034: "Sigma.SetCamDataGroupMovie",
        0x9035: "Sigma.ConfigApi",
        0x9036: "Sigma.GetMovieFileInfo",
        0x9037: "Sigma.GetPartialMovieFile",
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
    ///   1. If the VID/PID is in `sharedPids` (multiple bodies on one PID)
    ///      AND the USB descriptor name is non-empty, return
    ///      "<Make> <USBName>" — using the camera-reported model so a
    ///      Panasonic DC-GH5 doesn't end up labelled as "Lumix DC-series"
    ///      when the descriptor knew the specific body.
    ///   2. Otherwise "<Make> <Model>" if VID/PID is in our `table`.
    ///   3. Trimmed USB descriptor product name, if non-empty.
    ///   4. "USB <vid>:<pid>" hex fallback.
    static func displayName(vid: UInt16, pid: UInt16, fallback: String) -> String {
        let key = (UInt32(vid) << 16) | UInt32(pid)
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)

        if let known = table[key] {
            if sharedPids.contains(key), !trimmed.isEmpty {
                // The USB descriptor knows the specific body — prefer it.
                // Avoid duplicating the brand prefix when the descriptor
                // already starts with it ("Panasonic DC-GH5" vs "DC-GH5").
                let lcTrimmed = trimmed.lowercased()
                let lcMake    = known.make.lowercased()
                if lcTrimmed.hasPrefix(lcMake) {
                    return trimmed
                }
                return "\(known.make) \(trimmed)"
            }
            return "\(known.make) \(known.model)"
        }
        if !trimmed.isEmpty { return trimmed }
        return String(format: "USB %04X:%04X", vid, pid)
    }
}

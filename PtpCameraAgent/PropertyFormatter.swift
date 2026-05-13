// PropertyFormatter.swift
// Pure property-value formatting functions shared between AppDelegate and tests.

import Foundation

// MARK: - Value name tables

let nikonExtPropValueNames: [UInt32: [UInt32: String]] = [
    0x500E: [  // Exposure Mode (PTP standard + Nikon scene modes)
        0x0001: "Manual (M)", 0x0002: "Program (P)",
        0x0003: "Aperture (A)", 0x0004: "Shutter (S)",
        0x8010: "Auto", 0x8011: "Portrait", 0x8012: "Landscape",
        0x8013: "Close-up", 0x8014: "Sports", 0x8015: "Night Portrait",
        0x8016: "Flash Off", 0x8017: "Child", 0x8018: "Scene",
        0x8019: "Effects", 0x8050: "U1", 0x8051: "U2", 0x8052: "U3",
    ],
    0x5005: [  // White Balance (PTP standard + Nikon extras + Sony extras)
        0x0001: "Manual", 0x0002: "Auto", 0x0003: "One-Push Auto",
        0x0004: "Daylight", 0x0005: "Fluorescent", 0x0006: "Tungsten", 0x0007: "Flash",
        // Nikon-specific
        0x8010: "Cloudy", 0x8011: "Shade", 0x8012: "Color Temperature",
        0x8013: "Preset", 0x8014: "Off", 0x8016: "Natural Light Auto",
        // Sony-specific (0x8001–0x8030 range not used by Nikon)
        0x8001: "Fluorescent: Warm White", 0x8002: "Fluorescent: Cool White",
        0x8003: "Fluorescent: Day White", 0x8004: "Fluorescent: Daylight",
        0x8020: "Custom 1", 0x8021: "Custom 2", 0x8022: "Custom 3",
        0x8030: "Auto (Underwater)",
    ],
    0x500A: [  // Focus Mode
        0x0001: "Manual", 0x0002: "Auto", 0x0003: "Auto Macro",
        0x8010: "[S] Single", 0x8011: "[C] Continuous",
        0x8012: "[A] Automatic", 0x8013: "[F] Constant",
    ],
    0x500B: [  // Metering Mode
        0x0001: "Average", 0x0002: "Center-weighted",
        0x0003: "Multi-spot", 0x0004: "Center-spot",
    ],
    0xD054: [  // Auto ISO
        0x0000: "Off", 0x0001: "On",
    ],
    0xD1A5: [  // Exposure Preview
        0x0000: "Off", 0x0001: "On",
    ],
    0xD17B: [  // Exposure Preview (apply settings)
        0x0000: "Off", 0x0001: "On",
    ],
    0xD10B: [  // Recording Media
        0x0000: "Card", 0x0001: "SDRAM", 0x0002: "Card + SDRAM",
    ],
    0xD141: [  // WB Auto Type
        0x0000: "Standard", 0x0001: "Incandescent",
    ],
    0xD14F: [  // WB Fluorescent Type
        0x0000: "Sodium Mixed", 0x0001: "Cool White",
        0x0002: "Warm White", 0x0003: "White",
        0x0004: "Day White", 0x0005: "Daylight",
        0x0006: "High Color Temp Mercury",
    ],
    0xD1A0: [  // LV Mirror Mode
        0x0000: "Mirror Down (AF)", 0x0001: "Mirror Up (AF)",
    ],
    0xD1A6: [  // LV Selector
        0x0000: "Still", 0x0001: "Movie",
    ],
    0xD05D: [  // AF Area Mode (StillFocusMeteringMode on Z-series)
        // DSLR values (D800-era)
        0x0000: "Face Detect", 0x0001: "Wide Area",
        0x0002: "Normal Area", 0x0003: "Target Tracking",
        // Z-series values (Z8, Z9, Z6III, etc.)
        0x8010: "Single-point",
        0x8011: "Auto-area",
        0x8012: "3D-Tracking",
        0x8013: "Dynamic (M)",
        0x8014: "Dynamic (L)",
        0x8017: "Pinpoint",
        0x8018: "Wide (S)",
        0x8019: "Wide (L)",
        0x801E: "Wide (C1)",
        0x801F: "Wide (C2)",
    ],
    0xD061: [  // Focus Mode (StillFocusMode on Z-series)
        0x0000: "AF-S", 0x0001: "AF-C / AF-F",
        0x0002: "[C] Continuous", 0x0003: "Manual Lens", 0x0004: "Manual",
    ],
    0xD1AC: [  // LV Image Size
        0x0000: "Undefined", 0x0001: "QVGA (320×240)",
        0x0002: "VGA (640×480)", 0x0003: "XGA (1024×768)",
    ],
]

// MARK: - Formatting

func formatNikonShutterSpeed(_ val: UInt32) -> String {
    let nom = UInt16(val >> 16)
    let den = UInt16(val & 0xFFFF)
    if val == 0xFFFFFFFF { return "Bulb" }
    if val == 0xFFFFFFFE { return "Flash" }
    if den == 10 && nom != 1 {
        let secs = 0.1 * Double(nom)
        return secs == Double(Int(secs)) ? "\(Int(secs))\"" : String(format: "%.1f\"", secs)
    } else if nom == 10 && den != 1 {
        let fps = 0.1 * Double(den)
        return fps == Double(Int(fps)) ? "1/\(Int(fps))" : String(format: "1/%.0f", fps)
    } else if den > 1 {
        return "\(nom)/\(den)"
    } else {
        return "\(nom)\""
    }
}

// Sony-specific enum value names. The values for properties like FocusMode
// differ between vendors despite using the same standard PTP property code,
// so we check this table first when the camera is identified as Sony.
let sonyExtPropValueNames: [UInt32: [UInt32: String]] = [
    0x500A: [  // FocusMode — Sony A7-series values
        0x0001: "MF",       // Manual Focus
        0x0002: "AF-S",     // Single-shot AF
        0x0003: "AF-C",     // Continuous AF
        0x0004: "AF-A",     // Automatic AF
        0x0006: "DMF",      // Direct Manual Focus
        // Sony-extended (0x80xx) values used on newer bodies / movie modes
        0x8004: "AF-D",     // Predictive Continuous AF
        0x8005: "AF-F",     // Full-time continuous (movie)
        0x8006: "PF",       // Power Focus
        0x8007: "DMF (Push)",
        0x8008: "AF (0x8008)",   // observed on A7-series — exact name unknown
    ],
]

func formatExtPropRaw(_ value: NSNumber, propId: UInt32, vendor: CameraVendor = .unknown) -> String {
    if vendor == .sony, let name = sonyExtPropValueNames[propId]?[value.uint32Value] { return name }
    if vendor == .canon, let canon = formatCanonExtProp(value, propId: propId) { return canon }
    if let name = nikonExtPropValueNames[propId]?[value.uint32Value] { return name }
    switch propId {
    case 0x5001: return "\(value.intValue)%"  // Standard PTP Battery Level
    case 0xD218:                              // Sony Battery Level
        // Sony reports -1 (Int8 0xFF) when the camera is running on external
        // power (AC adapter / USB power delivery) rather than the internal
        // battery; the actual battery isn't being drawn from so there's no
        // meaningful percentage to show.
        return value.intValue == -1 ? "External" : "\(value.intValue)%"
    case 0x5007, 0xD1A9:
        // Sony reports 0xFFFE (and Nikon historically reports 0xFFFF) for
        // aperture when no electronic lens is attached — the camera can't
        // read an f-number off the lens, so dividing by 100 would print a
        // nonsense value like "f/655.3". Show "—" instead.
        let u = value.uint32Value
        if u == 0xFFFE || u == 0xFFFF { return "—" }
        return String(format: "f/%.1f", Double(value.intValue) * 0.01)
    case 0x5008:         return String(format: "%.1f mm", Double(value.intValue) * 0.01)
    case 0x500F:         return "\(value.intValue)"
    case 0xD100, 0xD1A8, 0xD20D: return formatNikonShutterSpeed(value.uint32Value)
    case 0x5010, 0xD1AB: return String(format: "%+.1f EV", Double(value.intValue) * 0.001)
    case 0xD01E:         return "\(value.intValue) K"
    case 0xD20F:         return "\(value.intValue) K"
    case 0xD21E:         return value.uint32Value == 0xFFFFFF ? "Auto" : "\(value.intValue)"
    case 0xD1A2, 0xD1A5, 0xD17B: return value.boolValue ? "On" : "Off"
    // Nikon WB fine-tune: camera reports unsigned 0..12 with 6 as neutral
    // (full range −6..+6). Display as a signed offset from neutral.
    case 0xD017, 0xD018, 0xD019, 0xD01A, 0xD01B, 0xD01C, 0xD01D, 0xD150:
        let offset = value.intValue - 6
        return offset >= 0 ? "+\(offset)" : "\(offset)"

    // Sony WB tune and related fine-tune properties: camera reports unsigned
    // 0..255 with 128 (0x80) as neutral. Display as a signed offset.
    case 0xD210, 0xD21C, 0xD212, 0xD213, 0xD215, 0xD216, 0xD219, 0xD21B:
        let offset = value.intValue - 128
        return offset >= 0 ? "+\(offset)" : "\(offset)"
    default:             return "\(value)"
    }
}

// MARK: - Canon EOS formatters
//
// Canon EOS encodes ISO/aperture/shutter as proprietary 8-bit / 16-bit codes
// (not the value itself). The decoding formulas come from libgphoto2's
// `_get_Canon_ISO`, `_get_Canon_Aperture`, `_get_Canon_Shutterspeed` and from
// the legacy PtpCameraCanon agent class. We mirror them here so the ext
// camera menu can show "ISO 100" instead of the raw code 0x48.

// Canon ISO speed table — copied from libgphoto2 `canon_isospeed` in config.c.
private let canonIsoTable: [UInt32: String] = [
    0x0000: "Auto",  0x0001: "Auto ISO",
    0x0028: "6",  0x0030: "12",  0x0038: "25", 0x0040: "50",
    0x0043: "64",  0x0045: "80",  0x0048: "100", 0x004b: "125",
    0x004d: "160",  0x0050: "200", 0x0053: "250", 0x0055: "320",
    0x0058: "400",  0x005b: "500", 0x005d: "640", 0x0060: "800",
    0x0063: "1000", 0x0065: "1250",0x0068: "1600",0x006b: "2000",
    0x006d: "2500", 0x0070: "3200",0x0073: "4000",0x0075: "5000",
    0x0078: "6400", 0x007b: "8000",0x007d: "10000",0x0080: "12800",
    0x0083: "16000",0x0085: "20000",0x0088: "25600",0x008b: "32000",
    0x008d: "40000",0x0090: "51200",0x0093: "64000",0x0095: "80000",
    0x0098: "102400",0x00a0: "204800",0x00a8: "409600",0x00b0: "819200",
    0xffff: "Factory Default",
]

// Canon aperture table — copied from libgphoto2 `canon_aperture` in config.c.
// The codes are 16-bit but only the low byte differs on EOS bodies.
private let canonApertureTable: [UInt32: String] = [
    0x08: "f/1.0",  0x0b: "f/1.1",  0x0c: "f/1.2",  0x0d: "f/1.2",
    0x10: "f/1.4",  0x13: "f/1.6",  0x14: "f/1.8",  0x15: "f/1.8",
    0x18: "f/2.0",  0x1b: "f/2.2",  0x1c: "f/2.5",  0x1d: "f/2.5",
    0x20: "f/2.8",  0x23: "f/3.2",  0x24: "f/3.5",  0x25: "f/3.5",
    0x28: "f/4.0",  0x2b: "f/4.5",  0x2c: "f/4.5",  0x2d: "f/5.0",
    0x30: "f/5.6",  0x33: "f/6.3",  0x34: "f/6.7",  0x35: "f/7.1",
    0x38: "f/8.0",  0x3b: "f/9.0",  0x3c: "f/9.5",  0x3d: "f/10",
    0x40: "f/11",   0x43: "f/13",   0x44: "f/13",   0x45: "f/14",
    0x48: "f/16",   0x4b: "f/18",   0x4c: "f/19",   0x4d: "f/20",
    0x50: "f/22",   0x53: "f/25",   0x54: "f/27",   0x55: "f/29",
    0x58: "f/32",   0x5b: "f/36",   0x5c: "f/38",   0x5d: "f/40",
    0x60: "f/45",   0x63: "f/51",   0x64: "f/54",   0x65: "f/57",
    0x68: "f/64",   0x6b: "f/72",   0x6c: "f/76",   0x6d: "f/80",
    0x70: "f/91",
]

// Canon shutter-speed table — codes from libgphoto2 `canon_shutterspeed`.
private let canonShutterTable: [UInt32: String] = [
    0x0c: "Bulb", 0x10: "30\"", 0x13: "25\"", 0x14: "20\"", 0x15: "20\" (1/3)",
    0x18: "15\"", 0x1b: "13\"", 0x1c: "10\"", 0x1d: "10\" (1/3)",
    0x20: "8\"",  0x23: "6\" (1/3)", 0x24: "6\"", 0x25: "5\"",
    0x28: "4\"",  0x2b: "3\"2",      0x2c: "3\"",      0x2d: "2\"5",
    0x30: "2\"",  0x33: "1\"6",      0x34: "1\"5",     0x35: "1\"3",
    0x38: "1\"",  0x3b: "0\"8",      0x3c: "0\"7",     0x3d: "0\"6",
    0x40: "0\"5", 0x43: "0\"4",      0x44: "0\"3",     0x45: "0\"3 (1/3)",
    0x48: "1/4",  0x4b: "1/5",       0x4c: "1/6",      0x4d: "1/6 (1/3)",
    0x50: "1/8",  0x53: "1/10 (1/3)",0x54: "1/10",     0x55: "1/13",
    0x58: "1/15", 0x5b: "1/20 (1/3)",0x5c: "1/20",     0x5d: "1/25",
    0x60: "1/30", 0x63: "1/40",      0x64: "1/45",     0x65: "1/50",
    0x68: "1/60", 0x6b: "1/80",      0x6c: "1/90",     0x6d: "1/100",
    0x70: "1/125",0x73: "1/160",     0x74: "1/180",    0x75: "1/200",
    0x78: "1/250",0x7b: "1/320",     0x7c: "1/350",    0x7d: "1/400",
    0x80: "1/500",0x83: "1/640",     0x84: "1/750",    0x85: "1/800",
    0x88: "1/1000",0x8b: "1/1250",   0x8c: "1/1500",   0x8d: "1/1600",
    0x90: "1/2000",0x93: "1/2500",   0x94: "1/3000",   0x95: "1/3200",
    0x98: "1/4000",0x9b: "1/5000",   0x9c: "1/6000",   0x9d: "1/6400",
    0xa0: "1/8000",0xa3: "1/10000",  0xa5: "1/12800",  0xa8: "1/16000",
]

private let canonWhiteBalanceTable: [UInt32: String] = [
    0: "Auto", 1: "Daylight", 2: "Cloudy", 3: "Tungsten",
    4: "Fluorescent", 5: "Flash", 6: "Manual", 8: "Shade",
    9: "Color Temperature", 10: "PC-1", 11: "PC-2", 12: "PC-3",
    15: "AWB White",
]

private let canonFocusModeTable: [UInt32: String] = [
    0: "One-Shot AF", 1: "AI Servo AF", 2: "AI Focus AF", 3: "Manual",
]

private let canonMeteringModeTable: [UInt32: String] = [
    0: "Center-Weighted Average", 1: "Spot", 3: "Evaluative",
    4: "Partial", 5: "Center-Weighted Average",
]

private let canonExposureModeTable: [UInt32: String] = [
    0: "Program AE", 1: "Tv",  2: "Av",   3: "Manual",  4: "Bulb",
    5: "A-DEP",      6: "DEP", 7: "Custom", 8: "Lock", 9: "Green",
    10: "Night Portrait", 11: "Sports", 12: "Portrait",
    13: "Landscape", 14: "Close-Up", 15: "Flash Off",
    19: "Creative Auto", 20: "Movie",
    22: "SCN", 23: "Hand-held Night Scene", 24: "HDR Backlight Control",
    25: "Scene Intelligent Auto",
]

private func formatCanonExtProp(_ value: NSNumber, propId: UInt32) -> String? {
    let v = value.uint32Value
    switch propId {
    case 0xD101: return canonApertureTable[v]      ?? String(format: "f/?(0x%02x)", v)
    case 0xD102: return canonShutterTable[v]       ?? String(format: "?(0x%02x)", v)
    case 0xD103: return canonIsoTable[v].map { "ISO \($0)" } ?? "ISO ?(0x\(String(v, radix: 16)))"
    case 0xD104:
        let signed = Int8(bitPattern: UInt8(v & 0xFF))
        return String(format: "%+.1f EV", Double(signed) * (1.0 / 8.0))
    case 0xD105: return canonExposureModeTable[v]  ?? "Mode ?(0x\(String(v, radix: 16)))"
    case 0xD107: return canonMeteringModeTable[v]  ?? "Meter ?(0x\(String(v, radix: 16)))"
    case 0xD108: return canonFocusModeTable[v]     ?? "Focus ?(0x\(String(v, radix: 16)))"
    // 0xD10A on Canon EOS DSLRs reports the WB COLOR TEMPERATURE (Kelvin)
    // as the current value when the WB mode is set to "Color Temp", not a
    // WB mode code. The whole enum range is Kelvin values (2500..10000K).
    case 0xD10A:
        if v >= 1000 && v <= 12000 { return "\(v) K" }
        return canonWhiteBalanceTable[v] ?? "WB ?(0x\(String(v, radix: 16)))"
    case 0xD1B6: return v >= 1000 && v <= 12000 ? "\(v) K" : "EVF CT ?(0x\(String(v, radix: 16)))"
    default: return nil
    }
}

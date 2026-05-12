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

func formatExtPropRaw(_ value: NSNumber, propId: UInt32, vendor: CameraVendor = .unknown) -> String {
    if let name = nikonExtPropValueNames[propId]?[value.uint32Value] { return name }
    switch propId {
    case 0x5001: return "\(value.intValue)%"  // Standard PTP Battery Level
    case 0xD218:                              // Sony Battery Level
        // Sony reports -1 (Int8 0xFF) when the camera is running on external
        // power (AC adapter / USB power delivery) rather than the internal
        // battery; the actual battery isn't being drawn from so there's no
        // meaningful percentage to show.
        return value.intValue == -1 ? "External" : "\(value.intValue)%"
    case 0x5007, 0xD1A9: return String(format: "f/%.1f", Double(value.intValue) * 0.01)
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

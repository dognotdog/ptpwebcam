// CameraModel.swift
//
// Shared model for the extension-published camera state that flows through
// the `kDarwinCameraPropertyState` Darwin notify slot chain.
//
// Lives in PtpCameraAgent/ but is added as a build-file reference in both
// the PtpCameraAgent target (where the agent uses it for its menu) and the
// PtpWebcamApp target (where the host-app preview window's HUD overlay
// reads from the same property state). The CMIO extension does not import
// this file — it produces the slot payload from its own data structures
// and only needs the wire-format key strings (in PtpCameraAgentProtocol.swift).
//
// `ProtocolFamily` is declared in SupportedCameras.swift (already shared).

import Foundation

// MARK: - Model structs (formerly inlined at the bottom of PtpCameraAgent's AppDelegate.swift)

/// One PTP property descriptor + current value, in the form the agent
/// receives from the CMIO extension over the property-state slot chain.
struct ExtCameraProperty {
    let propertyId: UInt32
    let dataType: UInt16
    let writable: Bool
    let value: NSNumber
    let enumValues: [NSNumber]?
    let rangeMin: NSNumber?
    let rangeMax: NSNumber?
    let rangeStep: NSNumber?
    // Sony step-flags (default false for other vendors). `incremental` means
    // the camera is driven by SetPropStep — the menu shows +/- steppers
    // rather than a value picker. `isButton` is a momentary control.
    var incremental: Bool = false
    var isButton: Bool = false
}

/// Per-camera state the agent (and now the host app's HUD) reconstructs
/// from each `kDarwinCameraPropertyState` payload. Keyed by `cameraId`
/// in the parent dictionary; `name` is the user-visible camera label.
struct ExtCamera {
    let cameraId: String
    let name: String
    let claimKey: String
    let vid: UInt16
    let pid: UInt16
    let serial: String
    var properties: [UInt32: ExtCameraProperty]
    let orderedPropertyIds: [UInt32]
    let vendor: ProtocolFamily
    /// Apps known to keep ImageCapture sessions alive and therefore likely
    /// to be holding ptpcamerad against us. Populated when the extension
    /// publishes kDarwinUsbBlocked for this camera; reset to empty when
    /// the next successful property publish arrives. Keys = bundleId,
    /// values = display name. Surfaced in the menu as actionable items
    /// ("Quit Preview to use this camera").
    var blockingApps: [(bundleId: String, displayName: String)] = []
    /// True if the extension reported the camera was held but the agent
    /// couldn't identify a culprit from its `knownImageCaptureHolders`
    /// list (e.g. ptpcamerad is lingering after a holder quit, or some
    /// other process we don't recognise has the device). Menu falls back
    /// to a generic "⚠ Camera busy" message in this case — no quit
    /// action since we don't know what to terminate.
    var isBusyUnknownHolder: Bool = false
}

// MARK: - Semantic property roles

/// High-level camera control roles. The actual PTP property IDs differ
/// between vendors (Nikon shutter is 0xD100, Sony is 0xD20D, Canon uses
/// the PTP-standard 0x500D), so consumers ask for the role and let
/// `ExtCamera.propertyId(for:)` resolve to whichever propId the camera
/// actually exposes.
enum SemanticCameraProperty: CaseIterable {
    case iso
    case shutterSpeed
    case aperture
    case exposureCompensation
    case exposureMode
    case whiteBalance
    /// Real PTP property describing the camera's focus mode (Single,
    /// Continuous, Manual, etc). Vendor-specific on Nikon (0xD061),
    /// PTP-standard fallback (0x500A) for everyone else.
    case autofocusMode
    /// Virtual role with no underlying PTP property — the HUD just
    /// needs to know whether the camera supports the AF-trigger
    /// command at all, so it can decide whether to render the
    /// trigger button. Clicking the chip sends `cmd=4` on the
    /// per-camera command channel (see `ExtCamera.postAutofocusTrigger`),
    /// which the extension routes to its vendor-specific
    /// `triggerAutofocus()` implementation.
    case autofocusTrigger

    /// Ordered list of candidate PTP property IDs to try, from most
    /// vendor-specific to most generic. `ExtCamera.propertyId(for:)`
    /// walks this list and returns the first one the camera actually
    /// has in its `properties` dict.
    var candidatePropertyIds: [UInt32] {
        switch self {
        // 0xD21E is Sony's ISO-with-Auto-sentinel property (see the
        // formatter rule: 0xFFFFFF → "Auto", otherwise the value).
        // Most Sony bodies expose both 0xD21E and 0x500F; 0x500F is
        // sometimes a stale mirror, so prefer the vendor-specific
        // one. Falls back to 0x500F for Nikon / Canon / others.
        case .iso:                  return [0xD21E, 0x500F]
        case .shutterSpeed:         return [0xD100, 0xD20D, 0x500D]
        case .aperture:             return [0x5007, 0xD1A9]
        // PTP-standard ExposureBias (0x5010) covers Nikon/Sony in stills.
        // Nikon movie mode swaps to 0xD1AB. Canon proprietary 0xD104.
        case .exposureCompensation: return [0x5010, 0xD1AB, 0xD104]
        // ExposureProgramMode (0x500E) is PTP-standard; Canon uses 0xD105.
        case .exposureMode:         return [0x500E, 0xD105]
        case .whiteBalance:         return [0x5005]
        // Nikon-specific AF Mode (Single / Continuous / Auto-Select)
        // sits at 0xD061; falls back to the PTP-standard Focus Mode
        // (0x500A) on bodies that don't expose the Nikon vendor one.
        case .autofocusMode:        return [0xD061, 0x500A]
        // Virtual — no property backs it.
        case .autofocusTrigger:     return []
        }
    }

    /// Short label suitable for HUD chip display.
    var displayName: String {
        switch self {
        case .iso:                  return "ISO"
        case .shutterSpeed:         return "SS"
        case .aperture:             return "AV"
        case .exposureCompensation: return "EV"
        case .exposureMode:         return "M"
        case .whiteBalance:         return "WB"
        case .autofocusMode:        return "AF"
        case .autofocusTrigger:     return "AF"   // unused — the chip
                                                   // renders an icon, not text
        }
    }
}

extension ExtCamera {
    /// Returns the propertyId on this camera that fills the given
    /// semantic role, or nil if none of the candidates are present.
    /// Used by the HUD chip layout to decide whether a chip is
    /// applicable for the current camera.
    func propertyId(for role: SemanticCameraProperty) -> UInt32? {
        for candidate in role.candidatePropertyIds where properties[candidate] != nil {
            return candidate
        }
        return nil
    }

    /// Convenience: the `ExtCameraProperty` for a semantic role.
    func property(for role: SemanticCameraProperty) -> ExtCameraProperty? {
        guard let id = propertyId(for: role) else { return nil }
        return properties[id]
    }

    /// Composite-aware display string for the property at the given PTP
    /// id on this camera. Handles cases where the *human meaning* of one
    /// property depends on the value of another:
    ///
    ///  • Nikon / Sony PTP-standard WB (0x5005) set to "Color Temperature"
    ///    (0x8012) → look up the companion Kelvin property (Nikon 0xD01E,
    ///    Sony 0xD20F) and show its value instead of the static
    ///    "Color Temperature" enum name. The user actually wants to know
    ///    *what* color temperature, not just that it's in Color Temp mode.
    ///
    /// Falls back to `formatExtPropRaw(value, propId:, vendor:)` for every
    /// other case, so any property without a composite rule renders the
    /// same as before. Used by both the agent's menu and the host app's
    /// preview HUD — keeping the rule in one place means the two surfaces
    /// can't drift apart.
    func formattedValue(forPropertyId propId: UInt32) -> String? {
        guard let prop = properties[propId] else { return nil }

        // White-balance → color-temperature composite.
        if propId == 0x5005, prop.value.uint32Value == 0x8012 {
            for candidate in colorTemperatureCandidatePropIds {
                if let ct = properties[candidate] {
                    return formatExtPropRaw(ct.value, propId: candidate, vendor: vendor)
                }
            }
            // Fall through if no companion Kelvin property exists — the
            // formatter will produce "Color Temperature" which is at
            // least truthful even if not maximally informative.
        }
        return formatExtPropRaw(prop.value, propId: propId, vendor: vendor)
    }

    /// PTP property IDs that, when present, carry the Kelvin value
    /// the camera is using while WB is in Color Temperature mode.
    /// Ordered most-specific-first; we use the first candidate that's
    /// actually populated.
    private var colorTemperatureCandidatePropIds: [UInt32] {
        [
            0xD01E,   // Nikon: White Balance Color Temperature
            0xD20F,   // Sony: White Balance Color Temperature
        ]
    }

    /// True when the PTP property id holds a raw Kelvin reading that
    /// the HUD should expose with the Planckian-locus picker instead
    /// of the generic value-wheel. Numeric range properties whose
    /// value happens to be a Kelvin number (0xD01E Nikon / 0xD20F
    /// Sony) — the same set as `colorTemperatureCandidatePropIds`.
    public func isColorTemperatureProperty(_ propId: UInt32) -> Bool {
        propId == 0xD01E || propId == 0xD20F
    }
}

// MARK: - Planckian locus + chromaticity math (shared)

/// Cubic approximations of the CIE 1931 Planckian locus
/// chromaticity coordinates, from Kim et al. (2002). Same
/// piecewise polynomial split the camera-science world uses for
/// "blackbody temperature → CIE (x, y)" conversions.
///
/// Returns the chromaticity (x, y) for the given correlated colour
/// temperature in Kelvin. Valid for ~1667–25000 K; outside that
/// range the polynomial fit degrades but doesn't blow up.
///
/// Lives in the shared model file so both the host-app HUD
/// (`PreviewHud.swift`) and the agent menu's NSView-based picker
/// (`PlanckianLocusView.swift`) can use the same math.
public func planckianChromaticity(kelvin t: Double) -> (x: Double, y: Double) {
    let invT  = 1.0 / t
    let invT2 = invT * invT
    let invT3 = invT2 * invT
    let x: Double
    if t < 4000 {
        x = -0.2661239e9 * invT3 - 0.2343589e6 * invT2 + 0.8776956e3 * invT + 0.179910
    } else {
        x = -3.0258469e9 * invT3 + 2.1070379e6 * invT2 + 0.2226347e3 * invT + 0.240390
    }
    let x2 = x * x
    let x3 = x2 * x
    let y: Double
    if t < 2222 {
        y = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
    } else if t < 4000 {
        y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
    } else {
        y =  3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483
    }
    return (x, y)
}

/// Convert CIE 1931 (x, y) chromaticity coordinates (assuming
/// Y = 1) to a brightness-equalised sRGB triple suitable for
/// rendering. Standard sRGB transformation matrix, gamut clip,
/// max-channel normalisation, luminance-equalisation to a fixed
/// target Y, and sRGB gamma encoding — see the long header
/// comment in this function for the rationale.
///
/// Returns gamma-encoded sRGB components in `[0, 1]`. Callers
/// wrap in `Color`, `NSColor(srgbRed:...)`, or whatever fits
/// their surface.
public func chromaticityRGB(x: Double, y: Double) -> (Double, Double, Double) {
    guard y > 0 else { return (0, 0, 0) }
    // XYZ with Y = 1
    let X = x / y
    let Y = 1.0
    let Z = (1 - x - y) / y
    // sRGB linear (D65 reference white)
    var r =  3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z
    var g = -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z
    var b =  0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z
    // Clip out-of-gamut negatives.
    r = max(0, r); g = max(0, g); b = max(0, b)
    // Normalise to brightest channel = 1.
    let maxC = max(r, max(g, b))
    if maxC > 0 { r /= maxC; g /= maxC; b /= maxC }
    // Equalise to a target perceived luminance so the rendered
    // field reads as a smooth gradient instead of a bright spike
    // at the white point.
    let targetY: Double = 0.55
    let currentY = 0.2126 * r + 0.7152 * g + 0.0722 * b
    if currentY > 0 {
        if currentY >= targetY {
            let scale = targetY / currentY
            r *= scale; g *= scale; b *= scale
        } else if currentY < 1 {
            let t = (targetY - currentY) / (1 - currentY)
            r = (1 - t) * r + t
            g = (1 - t) * g + t
            b = (1 - t) * b + t
        }
    }
    // sRGB gamma encode.
    func encode(_ u: Double) -> Double {
        u <= 0.0031308 ? 12.92 * u : 1.055 * pow(u, 1 / 2.4) - 0.055
    }
    return (encode(r), encode(g), encode(b))
}

// MARK: - Tune (matrix / bar) visualisation

/// PTP property IDs that represent white-balance fine-tune controls,
/// rather than enums or simple numeric ranges. These get a visual
/// matrix (2D) or bar (1D) widget in the HUD instead of the regular
/// value-wheel — the actual integer they carry encodes a position on
/// a colour-tuning grid and is meaningless as a number to the user.
///
/// Matches `nikonWbTuneIds` in the agent menu (which is the same set
/// used to decide whether to build a `WbTuneGridView` submenu) plus
/// the Sony pair `0xD210` / `0xD21C` which are independent 1D axes.
private let tunePropertyIds: Set<UInt32> = [
    // Nikon WB mode-specific tunes (typically 1D, range 0..12,
    // with 6 = neutral; some bodies expose them as 2D in the
    // 0..168 / 0..1224 encodings).
    0xD017, 0xD018, 0xD019, 0xD01A, 0xD01B, 0xD01C, 0xD01D,
    // Nikon Color Temp Tune.
    0xD150,
    // Sony Green↔Magenta and Amber↔Blue axes (independent 1D),
    // plus the mode-specific Sony tunes that show up in the
    // 0..168 / 0..1224 encodings.
    0xD210, 0xD21C, 0xD212, 0xD213, 0xD215, 0xD216, 0xD218, 0xD219, 0xD21B,
]

/// Which colour axis a 1D tune bar represents. Drives the bar's
/// fill gradient — Sony's two-axis WB fine-tune uses the same
/// integer encoding for both axes, so the only way to tell them
/// apart at render time is by propId.
///
///   • `.greenMagenta` — green (low end) ↔ magenta (high end).
///     Used for the Nikon per-mode tunes, the Color Temp Tune,
///     and Sony's G-M tune (0xD210). Center cell renders gray.
///   • `.amberBlue` — yellow/amber (low end) ↔ blue (high end).
///     Used for Sony's A-B tune (0xD21C). Center cell renders
///     gray. Yellow and blue are true RGB complements, so the
///     same direct-RGB linear interpolation the green↔magenta
///     bar uses produces a neutral midpoint here too.
public enum TuneBarAxis: Equatable {
    case greenMagenta
    case amberBlue

    /// Pick the right axis for a tune property id. Today only
    /// Sony's 0xD21C is on the amber↔blue axis; everything else
    /// defaults to green↔magenta. Add propIds here as we
    /// encounter other A-B tunes (Panasonic, etc).
    public static func forPropertyId(_ propId: UInt32) -> TuneBarAxis {
        propId == 0xD21C ? .amberBlue : .greenMagenta
    }

    /// Direct sRGB linear interpolation between the two axis
    /// endpoints. Centre (`t = 0.5`) lands on exact neutral gray
    /// for both axes because the endpoints are RGB complements
    /// in each case.
    public func color(t: Double) -> (Double, Double, Double) {
        switch self {
        case .greenMagenta:
            // green (0, 1, 0) ↔ magenta (1, 0, 1)
            return (t, 1.0 - t, t)
        case .amberBlue:
            // yellow (1, 1, 0) ↔ blue (0, 0, 1)
            let a = (1.0, 1.0, 0.0)
            let b = (0.0, 0.0, 1.0)
            return (a.0 + (b.0 - a.0) * t,
                    a.1 + (b.1 - a.1) * t,
                    a.2 + (b.2 - a.2) * t)
        }
    }
}

/// Visual style for a HUD tune chip. The PreviewHud picks one based
/// on the property's published range — the same heuristic the agent
/// menu uses to decide between `buildWbTuneGridSubmenu` (2D grid)
/// and the regular slider/enum submenu (1D fallback).
public enum TuneStyle: Equatable {
    /// 13×13 grid. Property value encodes both axes; decoded via
    /// `(x + y*13)` for `rangeMax=168` or `(x*2 + y*100)` for
    /// `rangeMax=1224`. The chip shows a single colour-cell when
    /// collapsed; expanding grows the chip downward to reveal the
    /// full grid inline (no popover).
    case grid2D(rangeMax: Int)
    /// 13-cell horizontal strip on the green↔magenta axis. The
    /// chip shows a single colour-cell when collapsed; expanding
    /// reveals the full strip inline.
    case bar1D(rangeMin: Int, rangeMax: Int)

    /// True when this style is a 2D matrix — used by the HUD to
    /// pick the right background shape (rounded rectangle vs the
    /// regular capsule pill).
    public var isGrid2D: Bool {
        if case .grid2D = self { return true }
        return false
    }
}

extension ExtCamera {
    /// Returns the tune-widget style for the property if it's a
    /// known WB fine-tune control with a usable range; otherwise
    /// nil, meaning the HUD should render it with the default
    /// value-wheel instead.
    public func tuneStyle(forPropertyId propId: UInt32) -> TuneStyle? {
        guard tunePropertyIds.contains(propId),
              let prop = properties[propId],
              let rMin = prop.rangeMin?.intValue,
              let rMax = prop.rangeMax?.intValue,
              rMax > rMin else { return nil }
        // 2D grid: only the specific 0..168 (13×13 dense) and
        // 0..1224 (13×13 with x-step=2/y-step=100) encodings the
        // legacy DAL plugin's PtpGridTuneView documented.
        if rMin == 0, (rMax == 168 || rMax == 1224) {
            return .grid2D(rangeMax: rMax)
        }
        // Anything else falls back to the 1D inline bar.
        return .bar1D(rangeMin: rMin, rangeMax: rMax)
    }
}

// MARK: - White-balance fine-tune sub-properties

/// PTP property IDs that fine-tune the selected white balance mode.
/// Keyed by the value of `0x5005` (WhiteBalance) the camera is
/// currently set to. Mirrors `PtpCameraNikon.uiPtpSubProperties`
/// and the table used by the agent's menu to add sub-items under
/// each WB mode value — keeping the table here means the HUD and
/// the menu can't drift on which tune controls are relevant for a
/// given mode.
///
/// Color Temperature mode includes BOTH the Kelvin reading
/// (`0xD01E` Nikon / `0xD20F` Sony) AND the Color Temp Tune
/// (`0xD150`). The HUD's WB chip wheel renders enum value names
/// directly via `formatExtPropRaw`, so the wheel displays the
/// literal "Color Temperature" string — the actual Kelvin value
/// needs its own chip next to the WB chip for the user to see it
/// in the HUD. (The agent menu separately uses
/// `formattedValue(forPropertyId:)` which composites the Kelvin
/// into the WB row label, so the menu shows the Kelvin inline
/// AND the per-mode sub-item separately — that's intentional.)
private let nikonWhiteBalanceSubProperties: [UInt32: [UInt32]] = [
    0x0002: [0xD017, 0xD141],           // Auto              → WB Auto Tune + WB Auto Type
    0x0004: [0xD01A],                   // Daylight          → WB Sunny Tune
    0x0005: [0xD019, 0xD14F],           // Fluorescent       → WB Fluorescent Tune + Fluorescent Type
    0x0006: [0xD018],                   // Tungsten          → WB Incandescent Tune
    0x0007: [0xD01B],                   // Flash             → WB Flash Tune
    0x8010: [0xD01C],                   // Cloudy            → WB Cloudy Tune
    0x8011: [0xD01D],                   // Shade             → WB Shade Tune
    0x8012: [0xD01E, 0xD150, 0xD20F],   // Color Temperature → Kelvin (Nikon or Sony) + WB Color Temp Tune
]

extension ExtCamera {
    /// PTP property IDs of WB fine-tune controls relevant for the
    /// currently-selected white-balance mode. Used by both the agent
    /// menu (as sub-items under each WB mode) and the host-app HUD
    /// (as extra chips next to the WB chip). Filtered to only the
    /// IDs the camera actually exposes — entry-level bodies may not
    /// have every tune control listed in the canonical table.
    func whiteBalanceTunePropertyIds() -> [UInt32] {
        guard let wb = property(for: .whiteBalance) else { return [] }
        var result: [UInt32] = []
        // Nikon: per-mode tune IDs from the table above.
        if let nikonTunes = nikonWhiteBalanceSubProperties[wb.value.uint32Value] {
            result.append(contentsOf: nikonTunes.filter { properties[$0] != nil })
        }
        // Sony G-M / A-B tune grid: independent of WB mode, present
        // whenever the camera exposes them. Two separate properties
        // for the two axes — show both chips when they exist.
        for sonyId in [UInt32(0xD210), UInt32(0xD21C)] {
            if properties[sonyId] != nil { result.append(sonyId) }
        }
        return result
    }
}

// MARK: - Stepping through enum values

extension ExtCamera {
    /// Returns the enum values immediately before and after the
    /// property's current value, as published by the camera in its
    /// property descriptor. Used by the HUD's prev/next stepper to
    /// know what to display in the expanded side chips.
    ///
    /// Returns `(nil, nil)` if the property is missing, has no enum
    /// list (range or incremental property), or its current value
    /// isn't in the list (camera reports a value outside its own
    /// descriptor — rare, but possible during a property transition).
    /// Returns one-sided `(prev: X, next: nil)` or `(prev: nil, next: X)`
    /// at the ends of the list — callers display only the populated
    /// side of the stepper in that case.
    func adjacentEnumValues(forPropertyId propId: UInt32) -> (prev: NSNumber?, next: NSNumber?) {
        guard let prop = properties[propId],
              let enums = prop.enumValues,
              !enums.isEmpty else { return (nil, nil) }
        let currentVal = prop.value.uint32Value
        guard let idx = enums.firstIndex(where: { $0.uint32Value == currentVal }) else {
            return (nil, nil)
        }
        let prev = idx > 0                  ? enums[idx - 1] : nil
        let next = idx < enums.count - 1    ? enums[idx + 1] : nil
        return (prev, next)
    }
}

// MARK: - Per-camera Darwin notify command channel

/// Posts a SET_PROP command on the per-camera property command channel
/// the CMIO extension is listening on. Encodes the property and value
/// into a uint64 (cmd=3 in the high byte, propId in bits 47..32, value
/// in the low 32 bits) and writes/posts via Darwin notify — same wire
/// format the agent's menu uses, so the extension can't tell the
/// difference between an in-menu change and a HUD-stepper tap.
///
/// Returns immediately. The camera's response surfaces as the next
/// `kDarwinCameraPropertyState` publish, which the CameraPropertyStore
/// observes; the HUD re-renders from the updated `ExtCamera` value.
///
/// Lives on `ExtCamera` so both the agent and the host-app HUD can
/// reach it without duplicating the suffix/CRC computation.
extension ExtCamera {
    /// Low-24-bits of crc32(serial.utf8). Combined with VID and PID,
    /// produces the unique-per-camera Darwin-notify suffix used by
    /// claim/release and property-set channels.
    private static func crc24OfSerial(_ s: String) -> UInt32 {
        // Standard CRC-32 over the UTF-8 bytes. Implemented inline (no
        // table; we don't need throughput here — this is called on
        // user click, not in a hot loop). Same polynomial as the
        // agent's previous `crc32OfString`.
        var crc: UInt32 = 0xFFFFFFFF
        for byte in s.utf8 {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
            }
        }
        return (crc ^ 0xFFFFFFFF) & 0x00FFFFFF
    }

    /// Suffix appended to `kDarwinPropertyCmdSlot` / `kDarwinCameraPropertyCmd`
    /// (and the claim channels) to address commands at this specific
    /// camera. Format: VID.PID.CRC24 — matches what
    /// `PtpWebcamCameraExtensionProvider` registers on the extension
    /// side. Exposed on the model so callers don't need to know the
    /// CRC details.
    var darwinNotifySuffix: String {
        String(format: "%04x.%04x.%06x", vid, pid, Self.crc24OfSerial(serial))
    }

    /// Asks the extension to set this camera's property to a new value.
    /// Posts the SET_PROP command on `kDarwinCameraPropertyCmd.<suffix>`;
    /// the extension picks it up, calls the appropriate vendor-specific
    /// PTP set, then republishes property state. Both the agent menu
    /// and the host-app HUD use this to drive value changes.
    func postSet(propertyId: UInt32, value: UInt32) {
        let packed: UInt64 = (UInt64(3) << 56) | (UInt64(propertyId) << 32) | UInt64(value)
        postCommand(packed: packed)
    }

    /// Fires an autofocus trigger on this camera. Same wire format
    /// as `postSet`, but with `cmd=4` in the top byte and the
    /// propId / value fields zero. The extension routes this to
    /// the per-vendor `triggerAutofocus()` implementation
    /// (Nikon AfDrive, Sony AutofocusButton, Leica release-stages,
    /// Fuji Camera Action). Mirrors the agent menu's
    /// `postAutofocusCommand` so the HUD button and the menu
    /// trigger the exact same code path on the extension side.
    func postAutofocusTrigger() {
        let packed: UInt64 = UInt64(4) << 56
        postCommand(packed: packed)
    }

    private func postCommand(packed: UInt64) {
        let slotName   = kDarwinPropertyCmdSlot   + "." + darwinNotifySuffix
        let notifyName = kDarwinCameraPropertyCmd + "." + darwinNotifySuffix
        var token: Int32 = 0
        darwin_notify_register_check(slotName, &token)
        darwin_notify_set_state(token, packed)
        darwin_notify_post(notifyName)
        notify_cancel(token)
    }

    /// True iff the extension actually implements AF triggering for
    /// this camera's vendor. Mirrors the `supportsAf` switch in the
    /// agent menu's `addExtCameraMenu` so the HUD only shows the
    /// trigger button on bodies where it'll actually do something.
    ///   • Nikon — AfDrive (0x90C1), solid.
    ///   • Leica — LEReleaseStages (0x9004), solid.
    ///   • Sony  — only when 0xD2C1 is in the property set; the
    ///     A7-series tethered flow is flaky enough that the menu
    ///     labels this "experimental" — the HUD button just won't
    ///     appear on bodies that don't expose 0xD2C1.
    ///   • Fuji  — always-on; the extension logs and bails cleanly
    ///     if the prop write returns AccessDenied.
    ///   • Canon / Panasonic / Olympus / Sigma — not wired yet, so
    ///     no button.
    var supportsAutofocusTrigger: Bool {
        switch vendor {
        case .nikon, .leica: return true
        case .sony: return properties[0xD2C1] != nil
        case .fuji: return true
        default: return false
        }
    }
}

// MARK: - JSON parser

/// Result of parsing a single completed `kDarwinCameraPropertyState`
/// JSON payload. Returned by `ExtCamera.parse(jsonData:)` so the caller
/// can react to camera disconnects (remove from dict) and updates
/// (insert/replace) with a single switch.
enum ExtCameraParseResult {
    /// Camera disconnect message — caller should remove this id from
    /// its dictionary.
    case disconnected(cameraId: String)
    /// Successfully parsed camera state.
    case camera(ExtCamera)
    /// JSON didn't validate or required fields were missing. Caller
    /// should log and drop the message.
    case invalid
}

extension ExtCamera {
    /// Parses one full `kDarwinCameraPropertyState` JSON payload (already
    /// reassembled from its page chain by `CameraPropertyStatePageReassembler`)
    /// into either a disconnect signal or a fully populated `ExtCamera`.
    ///
    /// Pure function — no side effects, no dependency on agent or app
    /// state. Both the agent and the host app use it.
    static func parse(jsonData: Data) -> ExtCameraParseResult {
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let cameraId = json["id"] as? String else {
            return .invalid
        }

        if let removed = json["disconnected"] as? Bool, removed {
            return .disconnected(cameraId: cameraId)
        }

        guard let propsList = json["props"] as? [[String: Any]] else {
            return .invalid
        }

        let vid    = (json["vid"]    as? UInt16) ?? (json["vid"] as? Int).map { UInt16($0) } ?? 0
        let pid    = (json["pid"]    as? UInt16) ?? (json["pid"] as? Int).map { UInt16($0) } ?? 0
        let serial = (json["serial"] as? String) ?? ""
        let claimKey = serial.isEmpty
            ? String(format: "%04x:%04x", vid, pid)
            : String(format: "%04x:%04x:%@", vid, pid, serial)

        var properties: [UInt32: ExtCameraProperty] = [:]
        var orderedIds: [UInt32] = []

        for entry in propsList {
            guard let propId = (entry["i"] as? Int).map({ UInt32($0) }),
                  let dataType = (entry["dt"] as? Int).map({ UInt16($0) }),
                  let writable = (entry["w"] as? Int).map({ $0 != 0 }),
                  let value = entry["v"] as? NSNumber else { continue }
            let enumValues = (entry["e"] as? [NSNumber])
            var rangeMin: NSNumber?; var rangeMax: NSNumber?; var rangeStep: NSNumber?
            if let r = entry["r"] as? [String: NSNumber] {
                rangeMin = r["min"]; rangeMax = r["max"]; rangeStep = r["step"]
            }
            let incremental = (entry["inc"] as? Int) == 1
            let isButton    = (entry["btn"] as? Int) == 1
            let prop = ExtCameraProperty(
                propertyId: propId, dataType: dataType, writable: writable,
                value: value, enumValues: enumValues,
                rangeMin: rangeMin, rangeMax: rangeMax, rangeStep: rangeStep,
                incremental: incremental, isButton: isButton)
            properties[propId] = prop
            orderedIds.append(propId)
        }

        // Prefer the shared known-cameras lookup over the USB descriptor
        // name. USB names are inconsistent ("ILCE-1" vs the user-
        // recognisable "A1"); the agent's auto-claim and the host app's
        // HUD-to-AVCaptureDevice matching both prefer the friendly name.
        let usbName = (json["name"] as? String) ?? "PTP Camera"
        let name = PtpKnownCameras.displayName(vid: vid, pid: pid, fallback: usbName)
        let vendor = PtpKnownCameras.protocolFamily(forVid: vid, pid: pid)

        let camera = ExtCamera(
            cameraId: cameraId, name: name, claimKey: claimKey,
            vid: vid, pid: pid, serial: serial,
            properties: properties, orderedPropertyIds: orderedIds,
            vendor: vendor)
        return .camera(camera)
    }
}

// MARK: - Page reassembly

/// Stateful accumulator for the multi-page slot-chain protocol used by
/// `kDarwinCameraPropertyState`. Each page of the protocol contains
/// (slot 0) a header with totalLength + pageIndex + pageCount, (slots
/// 1..N-2) the page payload bytes, and (slot N-1) an additive checksum
/// of the page data.
///
/// Usage:
///   let reassembler = CameraPropertyStatePageReassembler()
///   // when kDarwinCameraPropertyState fires:
///   if let payload = reassembler.handlePage(slotTokens: propSlotTokens) {
///       // payload is the complete JSON for one full publish
///       let parsed = ExtCamera.parse(jsonData: payload)
///   }
///
/// Single-threaded — instantiate one per subscriber and call from the
/// same queue you registered the dispatch on.
final class CameraPropertyStatePageReassembler {
    /// Accumulating buffer for the current multi-page publish. Sized to
    /// `totalLength` from the page-0 header on first arrival; reset on
    /// disconnect, out-of-order, or checksum mismatch.
    private var buffer: Data? = nil
    private var totalLength: Int = 0
    private var pageCount: Int = 0
    private var nextPage: Int = 0
    /// Optional callback for log surfaces — the agent likes to log
    /// out-of-order / checksum-mismatch resets as faults so they show
    /// up in Console.app. Returning the strings via a callback rather
    /// than hard-coding `os_log` keeps the reassembler usable from
    /// both the agent and the host app without circular imports.
    var onError: ((String) -> Void)?

    /// Process one Darwin-notify firing. Returns the complete JSON
    /// payload when the last page has just arrived; returns nil at
    /// every other call (page accumulating, error, or no-op).
    func handlePage(slotTokens: [Int32]) -> Data? {
        guard slotTokens.count >= kDarwinPropertySlotCount else { return nil }

        var slot0: UInt64 = 0
        darwin_notify_get_state(slotTokens[0], &slot0)
        let total = Int(slot0 >> 32)
        let pageIndex = Int((slot0 >> 16) & 0xFFFF)
        let pages = Int(slot0 & 0xFFFF)
        guard total > 0, pages > 0, pageIndex < pages else { return nil }

        let pageDataSlots = kDarwinPropertySlotCount - 2
        let pageSize = pageDataSlots * 8
        let pageOffset = pageIndex * pageSize
        let pageLength = min(pageSize, total - pageOffset)
        guard pageLength > 0 else { return nil }

        // Start a fresh buffer on page 0 or any mismatched state.
        if pageIndex == 0 || buffer == nil || totalLength != total {
            buffer = Data(count: total)
            totalLength = total
            pageCount = pages
            nextPage = 0
        }

        guard var workingBuffer = buffer, pageIndex == nextPage else {
            onError?("CameraPropertyStatePageReassembler: page \(pageIndex) out of order (expected \(nextPage)), resetting")
            buffer = nil
            return nil
        }

        workingBuffer.withUnsafeMutableBytes { ptr in
            for i in 0..<((pageLength + 7) / 8) {
                var value: UInt64 = 0
                darwin_notify_get_state(slotTokens[i + 1], &value)
                let chunkOffset = pageOffset + i * 8
                let chunkSize = min(8, total - chunkOffset)
                if chunkSize > 0 { memcpy(ptr.baseAddress! + chunkOffset, &value, chunkSize) }
            }
        }
        buffer = workingBuffer

        var csValue: UInt64 = 0
        darwin_notify_get_state(slotTokens[kDarwinPropertySlotCount - 1], &csValue)
        let expectedChecksum = UInt32(csValue & 0xFFFFFFFF)
        var computedChecksum: UInt32 = 0
        for byte in workingBuffer[pageOffset..<(pageOffset + pageLength)] {
            computedChecksum = computedChecksum &+ UInt32(byte)
        }
        guard computedChecksum == expectedChecksum else {
            onError?("CameraPropertyStatePageReassembler: page \(pageIndex) checksum mismatch (\(computedChecksum) != \(expectedChecksum)), resetting")
            buffer = nil
            return nil
        }

        nextPage += 1
        if nextPage == pageCount {
            let completed = workingBuffer
            buffer = nil
            return completed
        }
        return nil
    }
}

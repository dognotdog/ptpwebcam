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
        // 0xD21E is Sony's ISO-with-Auto-sentinel; Canon EOS uses 0xD103
        // (proprietary), Nikon falls back to PTP-standard 0x500F.
        case .iso:                  return [0xD21E, 0xD103, 0x500F]
        // Nikon shutter 0xD100, Sony 0xD20D, Canon EOS 0xD102, PTP-std 0x500D.
        case .shutterSpeed:         return [0xD100, 0xD20D, 0xD102, 0x500D]
        // PTP-std aperture 0x5007 (Nikon), Sony 0xD1A9, Canon EOS 0xD101.
        case .aperture:             return [0x5007, 0xD1A9, 0xD101]
        // PTP-standard ExposureBias (0x5010) covers Nikon/Sony in stills.
        // Nikon movie mode swaps to 0xD1AB. Canon proprietary 0xD104.
        case .exposureCompensation: return [0x5010, 0xD1AB, 0xD104]
        // ExposureProgramMode (0x500E) is PTP-standard; Canon uses 0xD105.
        case .exposureMode:         return [0x500E, 0xD105]
        // PTP-std white balance 0x5005 (Nikon/Sony). On Canon EOS the
        // user-facing WB mode that the live-view (and our preview)
        // actually tracks is the "EVF White Balance" at 0xD1B4 —
        // writable enum of mode codes (Auto / Daylight / Cloudy /
        // Tungsten / Fluorescent / Flash / Custom / Shade / AWB
        // White Priority). The other Canon WB-related slot, 0xD10A,
        // is the still-capture WB which on R-series only exposes its
        // K values when the body is in "Color Temp" mode — so we
        // surface it as a separate CT chip via
        // `whiteBalanceTunePropertyIds()` + `isColorTemperatureProperty`.
        case .whiteBalance:         return [0x5005, 0xD1B4]
        // Nikon-specific AF Mode (Single / Continuous / Auto-Select)
        // sits at 0xD061; Canon EOS uses 0xD108; falls back to the PTP-
        // standard Focus Mode (0x500A) on bodies exposing neither.
        case .autofocusMode:        return [0xD061, 0xD108, 0x500A]
        // Virtual — no property backs it.
        case .autofocusTrigger:     return []
        }
    }

    /// Short label suitable for HUD chip display.
    var displayName: String {
        switch self {
        case .iso:                  return "ISO"
        case .shutterSpeed:         return "S"
        case .aperture:             return "A"
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
    ///
    /// Vendor-gating: Canon EOS reuses the 0xD1xx vendor-extension
    /// range for properties whose codes collide with Nikon's
    /// `PtpDeviceProperty*` codes (e.g. Canon 0xD102 = ShutterSpeed,
    /// Nikon 0xD102 = something else). When the camera isn't Canon
    /// we skip the Canon-only IDs so a Nikon body's accidental
    /// presence of e.g. 0xD103 doesn't get picked up as "ISO".
    func propertyId(for role: SemanticCameraProperty) -> UInt32? {
        for candidate in role.candidatePropertyIds where properties[candidate] != nil {
            if Self.canonOnlyPropertyIds.contains(candidate) && vendor != .canon {
                continue
            }
            return candidate
        }
        return nil
    }

    /// PTP vendor-extension codes Canon EOS uses for its UI properties.
    /// Other vendors also occupy parts of the 0xD1xx range with different
    /// meanings, so these IDs must only be matched on a Canon body.
    /// Kept in sync with `canonUiProperties` in
    /// `PtpWebcamCameraExtension/UsbCanonCamera.swift`.
    private static let canonOnlyPropertyIds: Set<UInt32> = [
        0xD101, 0xD102, 0xD103, 0xD104, 0xD105,
        0xD107, 0xD108, 0xD10A, 0xD129, 0xD12C,
        0xD1B0, 0xD1B1, 0xD1B2, 0xD1B4, 0xD1B6, 0xD1B7,
    ]

    /// True if `propId` is on a Canon EOS body but should be treated
    /// as the "WB color temperature" slot. Used in both the
    /// `isColorTemperatureProperty` check (to swap the chip out for
    /// a Planckian-locus picker) and the chip-plan tune-list builder
    /// (so 0xD1B6 appears next to the WB-mode chip when the body is
    /// in Color Temp mode).
    fileprivate var canonColorTemperaturePropertyId: UInt32? {
        guard vendor == .canon else { return nil }
        return properties[0xD1B6] != nil ? 0xD1B6 : nil
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

    /// True when the PTP property id holds a raw Kelvin reading
    /// that the HUD should expose with the Planckian-locus picker.
    /// Vendor-gated — `0xD01E` is Nikon's WB Color Temperature, and
    /// `0xD20F` is Sony's, but the PTP vendor-extension code space
    /// reuses these numbers freely (e.g. a Nikon Z8 exposes `0xD20F`
    /// with completely different semantics). Without the gate the
    /// chip plan would add a bogus second "CT 0K" chip on bodies
    /// that happen to expose the other vendor's id.
    public func isColorTemperatureProperty(_ propId: UInt32) -> Bool {
        switch vendor {
        case .nikon, .leica: return propId == 0xD01E
        case .sony:          return propId == 0xD20F
        // Canon EOS exposes the WB Color Temperature (Kelvin) as
        // 0xD1B6 ("EVF Color Temperature") — separate from the WB
        // mode selector at 0xD1B4. The property reports its current
        // K value plus a 76-entry enum of available K values, ideal
        // for the Planckian-locus picker.
        case .canon:         return propId == 0xD1B6
        default:             return false
        }
    }
}

// MARK: - WB 2D tune-grid encoding (shared)
//
// The WB fine-tune grid is a 13×13 matrix; the PTP property
// value encodes both axes in a single integer. Two encodings the
// menu / HUD pickers recognise, distinguished by the property's
// `rangeMax`:
//
//   • `rangeMax = 168`  (Nikon "dense"):  value = x + y * 13
//   • `rangeMax = 1224` (Sony "sparse"):  value = x * 2 + y * 100
//
// y = 0 is the visually top row in both encodings.

public let wbTuneGridSize: Int = 13

/// Decode a 2D grid value to its draw-loop `(x, y)` cell. `y = 0`
/// is the visually top row.
public func decodeWbTuneGrid(value: Int, rangeMax: Int) -> (x: Int, y: Int) {
    if rangeMax == 168 {
        let y = max(0, min(wbTuneGridSize - 1, value / wbTuneGridSize))
        let x = max(0, min(wbTuneGridSize - 1, value - y * wbTuneGridSize))
        return (x, y)
    }
    if rangeMax == 1224 {
        let y = max(0, min(wbTuneGridSize - 1, value / 100))
        let x = max(0, min(wbTuneGridSize - 1, (value - y * 100) / 2))
        return (x, y)
    }
    return (0, 0)
}

/// Inverse of `decodeWbTuneGrid`. Produces the canonical PTP
/// value for a `(x, y)` cell — what callers should send via
/// `postSet` when the user clicks that cell.
public func encodeWbTuneGrid(x: Int, y: Int, rangeMax: Int) -> Int {
    if rangeMax == 168  { return x + y * wbTuneGridSize }
    if rangeMax == 1224 { return x * 2 + y * 100 }
    return 0
}

/// 0..1 fraction of a grid coordinate (for colour blending).
public func wbTuneGridFraction(_ idx: Int) -> Double {
    Double(idx) / Double(wbTuneGridSize - 1)
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

// MARK: - Planckian locus geometry (shared)

/// View-independent locus geometry: the sampled chromaticities
/// from `rangeMin` to `rangeMax` in `step`-K increments, plus the
/// chromaticity extents (padded for breathing room) the picker
/// views map to view coordinates. Both the SwiftUI HUD picker
/// and the AppKit menu picker compute the same samples, so
/// pulling this here means the geometry stays bit-exact across
/// surfaces and we don't pay the polynomial-fit cost twice.
public struct PlanckianLocusGeometry {
    public struct Sample {
        public let kelvin: Int
        public let chromaticityX: Double
        public let chromaticityY: Double
    }

    public let samples: [Sample]
    public let minX: Double
    public let spanX: Double
    public let minY: Double
    public let spanY: Double

    public init(rangeMin: Int, rangeMax: Int, step: Int) {
        var rawSamples: [Sample] = []
        var t = rangeMin
        while t <= rangeMax {
            let (cx, cy) = planckianChromaticity(kelvin: Double(t))
            rawSamples.append(Sample(kelvin: t,
                                     chromaticityX: cx,
                                     chromaticityY: cy))
            t += step
        }
        // Pad the chromaticity window slightly so the locus
        // doesn't sit flush against the rendered chromaticity
        // background's edges.
        let pad: Double = 0.04
        let xs = rawSamples.map(\.chromaticityX)
        let ys = rawSamples.map(\.chromaticityY)
        let lowX  = (xs.min() ?? 0) - pad
        let highX = (xs.max() ?? 0) + pad
        let lowY  = (ys.min() ?? 0) - pad
        let highY = (ys.max() ?? 0) + pad
        self.samples = rawSamples
        self.minX  = lowX
        self.spanX = max(0.0001, highX - lowX)
        self.minY  = lowY
        self.spanY = max(0.0001, highY - lowY)
    }

    /// Map a sample's chromaticity coords to view-space (x, y),
    /// applying the inset margin on all sides. `y = 0` is the
    /// top of the view (y-down convention — flipped NSView or
    /// SwiftUI).
    public func viewPoint(for sample: Sample,
                          viewWidth: CGFloat, viewHeight: CGFloat,
                          inset: CGFloat) -> CGPoint {
        let nx = (sample.chromaticityX - minX) / spanX
        let ny = 1.0 - (sample.chromaticityY - minY) / spanY
        let px = inset + CGFloat(nx) * (viewWidth - 2 * inset)
        let py = inset + CGFloat(ny) * (viewHeight - 2 * inset)
        return CGPoint(x: px, y: py)
    }

    /// Find the sample whose view-space point is closest to the
    /// given drag location. Used by both pickers to map an
    /// arbitrary cursor position to the nearest CT.
    public func closestSample(to p: CGPoint,
                              viewWidth: CGFloat, viewHeight: CGFloat,
                              inset: CGFloat) -> Sample? {
        var best: Sample?
        var bestDist = CGFloat.infinity
        for s in samples {
            let q = viewPoint(for: s, viewWidth: viewWidth,
                              viewHeight: viewHeight, inset: inset)
            let dx = q.x - p.x, dy = q.y - p.y
            let d = dx * dx + dy * dy
            if d < bestDist { bestDist = d; best = s }
        }
        return best
    }
}

// MARK: - Chromaticity-fill image (shared)

#if canImport(CoreGraphics)
import CoreGraphics

/// Render the chromaticity-fill background for a Planckian-locus
/// picker into a `CGImage` once, so both the SwiftUI HUD picker
/// (`Image(decorative:scale:)`) and the AppKit menu picker
/// (`NSImage(cgImage:size:)`) can blit the same pixels without
/// running the per-pixel sRGB transform twice. `width` /
/// `height` are point sizes; the inset is the margin the locus
/// view uses internally (chromaticity coords map to `[inset,
/// size - inset]` inside this rect).
public func renderChromaticityFillImage(
    geometry: PlanckianLocusGeometry,
    width: Int, height: Int, inset: Int
) -> CGImage? {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
        return nil
    }
    let usableW = max(1, Double(width - 2 * inset))
    let usableH = max(1, Double(height - 2 * inset))
    for y in 0..<height {
        let nyd = (Double(y) + 0.5 - Double(inset)) / usableH
        let nyClamped = max(0, min(1, nyd))
        let chromY = geometry.minY + (1.0 - nyClamped) * geometry.spanY
        for x in 0..<width {
            let nxd = (Double(x) + 0.5 - Double(inset)) / usableW
            let nxClamped = max(0, min(1, nxd))
            let chromX = geometry.minX + nxClamped * geometry.spanX
            let (r, g, b) = chromaticityRGB(x: chromX, y: chromY)
            let offset = y * bytesPerRow + x * bytesPerPixel
            data[offset]     = UInt8(max(0, min(255, Int(r * 255))))
            data[offset + 1] = UInt8(max(0, min(255, Int(g * 255))))
            data[offset + 2] = UInt8(max(0, min(255, Int(b * 255))))
            data[offset + 3] = 255
        }
    }
    return context.makeImage()
}
#endif

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

/// PTP property IDs that represent WB fine-tune controls, split by
/// vendor because the Dxxx half of the PTP code space is vendor-
/// extension territory and the same numeric id often means
/// completely different things across vendors (e.g. Sony's 0xD21C
/// is "WB Tune A-B" but Nikon uses the same code for something
/// else on Z-series bodies — without this gating the HUD/menu
/// would render Nikon's 0xD21C as a Sony amber-blue tune bar with
/// nonsense range/step semantics).
private let nikonTunePropertyIds: Set<UInt32> = [
    // Nikon WB mode-specific tunes (typically 1D, range 0..12
    // with 6 = neutral; some bodies expose them as 2D in the
    // 0..168 / 0..1224 encodings).
    0xD017, 0xD018, 0xD019, 0xD01A, 0xD01B, 0xD01C, 0xD01D,
    // Nikon Color Temp Tune.
    0xD150,
]

private let sonyTunePropertyIds: Set<UInt32> = [
    // Sony Green↔Magenta and Amber↔Blue axes (independent 1D),
    // plus the mode-specific Sony tunes that show up in the
    // 0..168 / 0..1224 encodings.
    0xD210, 0xD21C, 0xD212, 0xD213, 0xD215, 0xD216, 0xD218, 0xD219, 0xD21B,
]

private let canonTunePropertyIds: Set<UInt32> = [
    // Canon EOS WB fine-tune offsets (signed 1D, neutral at 0).
    // Names from libgphoto2's PTP_DPC_CANON_EOS_WhiteBalanceAdjust*
    // codes — Canon calls the amber-blue axis "A" and the
    // green-magenta axis "B", flipped from Sony's convention.
    0xD10C, 0xD10D,
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
        // Amber↔blue tunes: Sony 0xD21C, Canon EOS 0xD10C
        // (PTP_DPC_CANON_EOS_WhiteBalanceAdjustA).
        switch propId {
        case 0xD21C, 0xD10C: return .amberBlue
        default:             return .greenMagenta
        }
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
    /// Horizontal colour strip with one cell per `values` entry —
    /// one cell per discrete value the camera accepts on this
    /// tune. Cell count varies per body / property:
    ///   • Nikon per-mode tunes: 13 cells (range 0..12, neutral 6).
    ///   • Sony G-M / A-B: 13 cells synthesised from the 0..255
    ///     range (camera takes any UInt8; the bar samples evenly).
    ///   • Canon EOS WhiteBalanceAdjust*: 19 cells (-9..+9
    ///     enumerated by the body).
    /// Clicking a cell writes that cell's exact value, so the
    /// bar's selection is always a real value the camera accepts.
    case bar1D(values: [Int])

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
    /// value-wheel instead. Vendor-gated — see the comment on
    /// `nikonTunePropertyIds` / `sonyTunePropertyIds` for why the
    /// same propId can mean different things on different
    /// vendors and must be matched against the right set.
    public func tuneStyle(forPropertyId propId: UInt32) -> TuneStyle? {
        let isTune: Bool
        switch vendor {
        // Leica reuses Nikon-style WB controls in its
        // PtpCameraNikon-derived flow, so the Nikon tune set
        // applies there too.
        case .nikon, .leica: isTune = nikonTunePropertyIds.contains(propId)
        case .sony:          isTune = sonyTunePropertyIds.contains(propId)
        case .canon:         isTune = canonTunePropertyIds.contains(propId)
        default:             isTune = false
        }
        guard isTune, let prop = properties[propId] else { return nil }

        // 2D grid: range form with the specific 0..168 (13×13
        // dense) and 0..1224 (13×13 with x-step=2/y-step=100)
        // encodings the legacy DAL plugin's PtpGridTuneView
        // documented.
        if let rMin = prop.rangeMin?.intValue,
           let rMax = prop.rangeMax?.intValue,
           rMin == 0, (rMax == 168 || rMax == 1224) {
            return .grid2D(rangeMax: rMax)
        }

        // 1D bar — collect the selectable values for this tune.
        // Prefer the camera's explicit enum (Canon EOS reports
        // each ±step as a discrete entry); fall back to synthesising
        // an evenly-spaced 13-cell strip from the property's range
        // form (Sony 0..255 tunes don't enumerate every UInt8).
        let values: [Int]
        if let enumValues = prop.enumValues, enumValues.count >= 2 {
            values = enumValues
                .map { signedIntValue(rawUInt32: $0.uint32Value, dataType: prop.dataType) }
                .sorted()
        } else if let rMin = prop.rangeMin?.intValue,
                  let rMax = prop.rangeMax?.intValue,
                  rMax > rMin {
            // 13 evenly-spaced cells across the range — keeps the
            // Sony G-M / A-B bars compact instead of stretching to
            // 256 cells.
            let cells = 13
            values = (0..<cells).map { idx in
                rMin + ((rMax - rMin) * idx) / (cells - 1)
            }
        } else {
            return nil
        }
        return .bar1D(values: values)
    }
}

/// Reinterpret an unsigned PTP-wire value back to its signed
/// counterpart when the property's `dataType` says so. Enum lists
/// arrive as `[NSNumber]` of `uint32Value`s, but signed tune offsets
/// like Canon's WhiteBalanceAdjustA (Int16, range -9..+9) come
/// across as 0xFFF7..0x0009 — those need to be sign-extended back
/// to native Swift `Int` before the strip sorts them, or "-1" sorts
/// AFTER "+9" and the bar comes out reversed.
private func signedIntValue(rawUInt32 raw: UInt32, dataType: UInt16) -> Int {
    // PTP DataType codes: 1=INT8, 3=INT16, 5=INT32. All other
    // codes are unsigned (UINT8=2 / UINT16=4 / UINT32=6) or
    // non-numeric — pass through unchanged.
    switch dataType {
    case 1: return Int(Int8(bitPattern: UInt8(raw & 0xFF)))
    case 3: return Int(Int16(bitPattern: UInt16(raw & 0xFFFF)))
    case 5: return Int(Int32(bitPattern: raw))
    default: return Int(raw)
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
    /// IDs the camera actually exposes AND that match the camera's
    /// vendor — the shared sub-properties table lists every
    /// vendor's Color Temp / tune propIds under each WB mode value
    /// for convenience, but the Dxxx code space overlaps so we
    /// need to drop the wrong-vendor entries here.
    func whiteBalanceTunePropertyIds() -> [UInt32] {
        guard let wb = property(for: .whiteBalance) else { return [] }
        var result = Self.whiteBalanceSubPropertyIds(forModeValue: wb.value.uint32Value)
            .filter { propId in
                guard properties[propId] != nil else { return false }
                // Vendor-specific CT propIds: only include the
                // one that actually means "Kelvin reading" on
                // this camera's vendor. Otherwise a Nikon Z8
                // exposing 0xD20F (something else entirely)
                // would get a bogus second CT chip showing 0K.
                switch propId {
                case 0xD01E: return vendor == .nikon || vendor == .leica
                case 0xD20F: return vendor == .sony
                default:     return true
                }
            }
        // Sony G-M / A-B tune grid: independent of WB mode, present
        // whenever the camera exposes them. Two separate properties
        // for the two axes — show both chips when they exist.
        // Gated on vendor: Nikon Z-series bodies reuse `0xD21C`
        // for something unrelated and would otherwise pick up a
        // bogus amber-blue chip.
        if vendor == .sony {
            for sonyId in [UInt32(0xD210), UInt32(0xD21C)] {
                if properties[sonyId] != nil { result.append(sonyId) }
            }
        }
        // Canon EOS: surface the EVF Color Temperature (0xD1B6) and
        // the WB fine-tune offsets (0xD10C amber-blue, 0xD10D green-
        // magenta) as sub-chips when the body actually exposes them.
        // CT is only relevant in Color-Temp WB mode — gate it on
        // the still-WB slot (0xD10A) reporting a K value (≥ 1000)
        // rather than a small mode code. The tune offsets are
        // always shown when present; the camera reports them as
        // read-only in CT mode and writable in mode-based WB modes,
        // and the chip pill renders correctly either way.
        if vendor == .canon {
            let inColorTemp =
                (properties[0xD10A]?.value.uint32Value ?? 0) >= 1000
            if inColorTemp, let ctId = canonColorTemperaturePropertyId {
                result.append(ctId)
            }
            for tuneId in [UInt32(0xD10C), UInt32(0xD10D)] {
                if properties[tuneId] != nil { result.append(tuneId) }
            }
        }
        return result
    }

    /// Raw sub-property table lookup, unfiltered. Used by the
    /// agent menu's per-mode sub-item builder, which iterates
    /// every WB enum value and offers the relevant sub-properties
    /// under each — distinct from `whiteBalanceTunePropertyIds()`
    /// which only returns IDs for the *currently-selected* mode.
    public static func whiteBalanceSubPropertyIds(forModeValue value: UInt32) -> [UInt32] {
        nikonWhiteBalanceSubProperties[value] ?? []
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

    /// Cancels an in-flight autofocus on this camera. Sent on AF
    /// chip mouse-up (after the press fired `postAutofocusTrigger`)
    /// so the body releases the shutter-half-press state — Canon
    /// in particular locks out subsequent `SetPropValueEx` writes
    /// and LV restart until this release arrives.
    func postAutofocusCancel() {
        let packed: UInt64 = UInt64(5) << 56
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
        // Canon EOS bodies support `DoAf` (0x9154); the extension's
        // `performAutofocus` first issues `AfCancel` (0x9160) to clear
        // any stuck half-press, then `DoAf`. We don't have the
        // supportedOps list on the agent side, but every Canon EOS we
        // care about advertises DoAf — falling through to a real AF
        // attempt is correct.
        case .canon: return true
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

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

    /// Ordered list of candidate PTP property IDs to try, from most
    /// vendor-specific to most generic. `ExtCamera.propertyId(for:)`
    /// walks this list and returns the first one the camera actually
    /// has in its `properties` dict.
    var candidatePropertyIds: [UInt32] {
        switch self {
        case .iso:                  return [0x500F]
        case .shutterSpeed:         return [0xD100, 0xD20D, 0x500D]
        case .aperture:             return [0x5007, 0xD1A9]
        // PTP-standard ExposureBias (0x5010) covers Nikon/Sony in stills.
        // Nikon movie mode swaps to 0xD1AB. Canon proprietary 0xD104.
        case .exposureCompensation: return [0x5010, 0xD1AB, 0xD104]
        // ExposureProgramMode (0x500E) is PTP-standard; Canon uses 0xD105.
        case .exposureMode:         return [0x500E, 0xD105]
        case .whiteBalance:         return [0x5005]
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
        let slotName   = kDarwinPropertyCmdSlot   + "." + darwinNotifySuffix
        let notifyName = kDarwinCameraPropertyCmd + "." + darwinNotifySuffix
        var token: Int32 = 0
        darwin_notify_register_check(slotName, &token)
        darwin_notify_set_state(token, packed)
        darwin_notify_post(notifyName)
        notify_cancel(token)
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

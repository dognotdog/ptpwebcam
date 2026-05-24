import Foundation
import IOSurface

let kPtpCameraAgentMachServiceName = "org.ptpwebcam.PtpWebcamApp.PtpCameraAgent"

let kPtpCameraStateNotification = "org.ptpwebcam.CameraStateChanged"
let kPtpCameraStateRequestNotification = "org.ptpwebcam.CameraStateRequest"
let kPtpCameraStatePath = "/tmp/org.ptpwebcam.cameras.plist"

// Darwin notification names (kernel-level, work across sandboxes)
let kDarwinCameraStateChanged = "org.ptpwebcam.darwin.CameraStateChanged"
let kDarwinCameraStateRequest = "org.ptpwebcam.darwin.CameraStateRequest"

// USB access coordination: extension → agent.
// Extension posts kDarwinNeedUsbAccess before opening the USB interface so
// the agent can kill ptpcamerad — Apple's PTP daemon holds the interface
// exclusively and ignores all kernel-level eviction messages
// (USBDeviceOpenSeize, USBInterfaceOpenSeize, IOUSBHost DeviceSeize) once
// it's settled on a device. The userspace SIGKILL from a co-resident
// process is the only reliable way short of IOUSBHost DeviceCapture, which
// needs the managed `com.apple.vm.device-access` entitlement.
//
// App Store gap: this side channel requires an unsandboxed agent (App
// Sandbox blocks cross-UID kill() with EPERM). Closing this gap requires
// either Apple granting `com.apple.vm.device-access` or finding another
// way to evict ptpcamerad that ptpcamerad actually honors.
let kDarwinNeedUsbAccess  = "org.ptpwebcam.darwin.NeedUsbAccess"
let kDarwinUsbAccessReady = "org.ptpwebcam.darwin.UsbAccessReady"

// State slots: each holds 8 bytes via notify_set_state/notify_get_state.
// Slot 0 high 32 bits = total byte length, low 32 bits = reserved.
// Slots 1..N hold the JSON payload.
let kDarwinStateSlotCount = 64
let kDarwinStateSlotPrefix = "org.ptpwebcam.darwin.state."

// Note: the kDarwinLiveViewStart / Stop / Cmd* / Surface* / Frame* channels
// were part of an earlier architecture where the extension shipped JPEG
// frames to the agent, the agent decoded them into a shared IOSurface, and
// the extension wrapped the surface in a CVPixelBuffer for CMIO. Cross-UID
// IOSurfaceLookup turned out to be blocked by the kernel, and the
// SurfaceSharingProtocol XPC workaround was never wired up end-to-end.
// All frame decoding now lives in the extension's UsbNikonCamera path
// (jpegIntoPixelBuffer → CVPixelBuffer → CMIO stream), so the entire set
// of slot definitions and the SurfaceSharingProtocol XPC service were
// removed when we cleaned up after the IOKit migration landed.


// Extension → Agent: camera property state publication (multi-page protocol).
// Slot 0 (header): [63:32] totalLength | [31:16] pageIndex | [15:0] pageCount
// Slots 1..(N-2) (data): payload bytes for the current page, 8 bytes per slot.
// Slot N-1 (checksum): additive byte sum of page data (UInt32 in low 32 bits).
// Page data capacity: (kDarwinPropertySlotCount-2)*8 = 8176 bytes/page.
// Posts kDarwinCameraPropertyState once per page; receiver reassembles pages.
let kDarwinCameraPropertyState = "org.ptpwebcam.darwin.PropertyState"
let kDarwinPropertySlotPrefix  = "org.ptpwebcam.darwin.prop."
let kDarwinPropertySlotCount   = 2048

// MARK: - Stream protocol (replaces kDarwinCameraPropertyState / paged slots)
//
// Streams arbitrary-length binary payloads over a 256-slot Darwin notify
// chain. The slot INDEX implicitly encodes a per-page sequence number
// (0..255), so each slot carries a full 8 bytes of payload — no
// in-band sequence byte is required.
//
//   Slots 0..254: data (8 bytes each).
//   Slot 255    : checkpoint, packed as:
//                   bits  0..31  CRC-32 over the cumulative dataset
//                                up to (and including) this page.
//                   bits 32..55  page index (24 bits).
//                   bits 56..63  reserved (must be zero).
//
// Each slot has its own Darwin notify name, so the kernel does NOT
// coalesce posts across slot boundaries within a single page — every
// slot write the publisher emits triggers exactly one receiver
// dispatch. Cross-page coalescing on the same slot name CAN still
// occur if the receiver hasn't drained the prior page's post for that
// slot before the publisher writes the next page; the NACK / CRC
// loop handles that case (see below).
//
// A "page" carries `kStreamDataSlotCount * 8 = 2040` bytes of
// payload. After each page the publisher writes the checkpoint slot
// (slot 255) with the post-page CRC and page index.
//
// Special page indices, written into the checkpoint slot:
//   • kStreamPageEndOfStream (0xFFFFFF) — sent as both the FIRST
//     packet (start-of-transmission) and the LAST packet
//     (end-of-transmission). The receiver resets all stream state
//     on observing this marker.
//   • kStreamPageRetransmitStart (0xFFFFFE) — sent before a NACK-
//     triggered retransmit so the receiver knows the upcoming page
//     is a retransmission (not the next forward page).
//   • 0..0xFFFFFD — normal monotonically increasing page indices.
//
// Retransmission: the receiver writes the failing page index into
// kDarwinCameraStreamNackSlot and posts kDarwinCameraStreamNack.
// The publisher retransmits starting with the page BEFORE the
// NACK'd one (giving the receiver a fresh baseline page) and
// continues forward through the rest of the dataset. The publisher
// retains transmitted-page data up to the most recent retransmit
// origin so it can satisfy the rewind. Stale NACKs (page index
// outside the current transmission's range) are dropped.
//
// Camera multiplexing: the channel is shared. Different cameras'
// transmissions serialise via the extension's `publishQueue`. The
// payload itself disambiguates ("id" field in the JSON).
let kDarwinCameraStreamSlotPrefix = "org.ptpwebcam.darwin.cs.slot."
let kDarwinCameraStreamSlotCount  = 256
let kDarwinCameraStreamNack       = "org.ptpwebcam.darwin.cs.nack"
let kDarwinCameraStreamNackSlot   = "org.ptpwebcam.darwin.cs.nack.slot"
/// Control-marker notify names + slots. Each control event
/// (transmission start, transmission end, retransmit start)
/// gets its OWN notify name, and never reuses the page-
/// checkpoint slot. Without this, a 1-page transmission posts
/// `slot.255` three times — start marker, page-0 checkpoint,
/// end marker — and the kernel coalesces them into a single
/// dispatch whose handler reads the latest slot value, losing
/// the start/end transitions entirely. With one name per
/// control type, each marker name is posted at most once per
/// transmission, so there's no same-name coalescing window.
let kDarwinCameraStreamStart        = "org.ptpwebcam.darwin.cs.start"
let kDarwinCameraStreamStartSlot    = "org.ptpwebcam.darwin.cs.start.slot"
let kDarwinCameraStreamEnd          = "org.ptpwebcam.darwin.cs.end"
let kDarwinCameraStreamEndSlot      = "org.ptpwebcam.darwin.cs.end.slot"
let kDarwinCameraStreamRetransmit   = "org.ptpwebcam.darwin.cs.retx"
let kDarwinCameraStreamRetransmitSlot = "org.ptpwebcam.darwin.cs.retx.slot"

/// Slot 255 in the chain is the page checkpoint; the other 255
/// carry data. Control markers (start, end, retransmit) live
/// on their own notify names above (NOT in this slot).
let kStreamDataSlotCount   = 255
let kStreamCheckpointIndex = 255
/// Payload bytes per page = 255 data slots × 8 bytes.
let kStreamPageSize        = kStreamDataSlotCount * 8

/// Maximum page index encodable in the 24-bit page-index field of
/// the page-checkpoint slot. Reserved markers
/// `kStreamPageEndOfStream` / `kStreamPageRetransmitStart` are
/// now only kept around for backwards-compatibility readers; the
/// active protocol uses the per-name control slots above to
/// signal start, end, and retransmit.
let kStreamPageEndOfStream    : UInt32 = 0xFFFFFF
let kStreamPageRetransmitStart: UInt32 = 0xFFFFFE
let kStreamPageMaxNormal      : UInt32 = 0xFFFFFD

/// Pack/unpack helpers for the 64-bit checkpoint slot value.
@inlinable
func packStreamCheckpoint(page: UInt32, crc: UInt32) -> UInt64 {
    let pageBits = UInt64(page & 0xFFFFFF) << 32
    return UInt64(crc) | pageBits
}

@inlinable
func unpackStreamCheckpoint(_ value: UInt64) -> (page: UInt32, crc: UInt32) {
    let crc  = UInt32(value & 0xFFFFFFFF)
    let page = UInt32((value >> 32) & 0xFFFFFF)
    return (page, crc)
}

/// CRC-32 (IEEE 802.3 polynomial 0xEDB88320). Shared by the stream
/// publisher (extension) and receivers (agent + host app) so any
/// off-by-one in one side will produce a deterministic, debuggable
/// mismatch on the other. Bitwise (not table-based) — payloads are
/// in the ~20 KB range and this runs once per page, so the
/// arithmetic-only form is fast enough and avoids carrying a 1 KB
/// lookup table around.
func ptpwebcamCRC32(_ bytes: some Sequence<UInt8>) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            let mask = UInt32(0) &- (crc & 1)
            crc = (crc >> 1) ^ (0xEDB88320 & mask)
        }
    }
    return crc ^ 0xFFFFFFFF
}

// Agent → Extension: please republish current camera + property state for
// every connected camera. Posted by the agent on startup, since Darwin
// notify posts aren't replayed for subscribers that weren't running. The
// extension reacts by re-firing publishCameraConnected + publishPropertyState
// for each known camera, so a freshly-relaunched agent recovers the menu
// instead of staying blank until the next camera plug event.
let kDarwinCameraStateRepublish = "org.ptpwebcam.darwin.CameraStateRepublish"

// Agent → Extension: camera claim/release command
// Agent writes packed uint64 to kDarwinClaimCameraSlot, then posts kDarwinClaimCamera.
// Bit layout: [63:56] cmd (1=claim, 2=release) | [55:32] crc32(serial.utf8) | [31:16] VID | [15:0] PID
let kDarwinClaimCamera     = "org.ptpwebcam.darwin.ClaimCamera"
let kDarwinClaimCameraSlot = "org.ptpwebcam.darwin.claim"

// Agent → Extension: property set command
// Agent writes a packed uint64 command to kDarwinPropertyCmdSlot, then posts kDarwinCameraPropertyCmd.
// Bit layout: [63:56] cmd (3=SET_PROP) | [55:48] reserved | [47:32] propId (UInt16) | [31:0] value (UInt32)
let kDarwinCameraPropertyCmd   = "org.ptpwebcam.darwin.PropertyCmd"
let kDarwinPropertyCmdSlot     = "org.ptpwebcam.darwin.propcmd"

// MARK: - Extension → Agent: live view start failure
//
// Posted when the per-vendor `startLiveViewSession` returns false (Nikon
// reports `LiveViewProhibitCondition`, Canon's EVF state-machine doesn't
// transition to ready, Sony refuses STARTLIVEVIEW, etc.). Without this
// the user sees a black QuickTime/Zoom preview window with no idea why.
// Payload is a UTF-8 string ("Camera Name: reason") delivered via the
// same multi-page slot chain protocol we use for property state.
let kDarwinLiveViewFailed         = "org.ptpwebcam.darwin.LiveViewFailed"
let kDarwinLiveViewFailedSlotPrefix = "org.ptpwebcam.darwin.lvfail."
let kDarwinLiveViewFailedSlotCount  = 64  // 64 × 8 = 512 bytes, plenty for an error

// MARK: - Extension → Agent: USB-busy / camera-held-by-other-app diagnostic
//
// Posted when openUsbCamera exhausts its retry loop with
// kIOReturnExclusiveAccess — meaning ptpcamerad (or another userspace
// driver) has the device claimed and won't release. The agent uses this
// signal to enumerate likely culprits (Preview, Photos, Image Capture,
// etc. — apps known to keep ImageCapture sessions alive) and surface them
// in the menu as actionable items ("Quit Preview to use this camera")
// instead of leaving the user staring at "Opening PTP session…".
//
// Payload is the cameraId string (e.g. "usb-0000000100002ebf") via the
// shared slot-chain protocol. The agent maps it back to the right
// ExtCamera and updates its `blockingApps` field.
let kDarwinUsbBlocked             = "org.ptpwebcam.darwin.UsbBlocked"
let kDarwinUsbBlockedSlotPrefix   = "org.ptpwebcam.darwin.usbblock."
let kDarwinUsbBlockedSlotCount    = 32  // 32 × 8 = 256 bytes, plenty for a cameraId

// MARK: Menu-bar status item visibility (agent → host app)
//
// The agent is a LSUIElement helper; it has no Dock icon, only an
// NSStatusItem in the menu bar. On macOS versions / device configurations
// where the menu bar is crowded — notably notched MacBook displays
// running many menu-bar utilities, or when third-party menu-bar managers
// (Bartender, Ice) collapse overflow items — our item can end up hidden
// without the user knowing the app is running. macOS 26 also added a
// "Menu Bar" pane in System Settings that lets users toggle individual
// menu bar items off.
//
// The agent detects this via three signals on the NSStatusItem's hosting
// window: (a) NSWindow.didChangeOcclusionStateNotification, (b) a delayed
// +3s sanity check after launch (the initial occlusion state is reported
// once and never re-fired if the item starts hidden), and (c) a 2-second
// polling timer covering the System-Settings-toggle case (the OS may
// destroy and re-create the NSStatusBarWindow on toggle, so the
// occlusion observer we registered on the old window stops firing).
//
// The slot payload is a single bool packed into the low byte. We
// experimented with a reason-byte distinction (overflow vs. user
// disabled the item) but the two states are observationally identical
// on macOS 26: the window's frame stays at its menu-bar slot, occlusion
// drops the .visible flag, and no defaults domain flips between them.
// The About-window banner therefore covers both possibilities in one
// message, branching only on OS version (since "System Settings → Menu
// Bar" doesn't exist on pre-26 macOS).
let kDarwinMenuBarHidden     = "org.ptpwebcam.darwin.MenuBarHidden"
let kDarwinMenuBarHiddenSlot = "org.ptpwebcam.darwin.menubarhidden"

// MARK: PTP property-dump channels (debugging unsupported cameras)
//
// Used by the app's "List PTP Properties" submenu. Lets the user generate a
// text dump of GetDeviceInfo + every property descriptor for any PTP-class
// USB device — including ones we don't have a UsbCamera subclass for yet.
//
// 1. App posts kDarwinPtpDumpDevicesRequest to ask for current device list.
// 2. Extension enumerates IOServiceGetMatchingServices(ptpMatchingDictionary)
//    and publishes a JSON list via kDarwinPtpDumpDevicesState using the same
//    multi-page slot chain protocol as kDarwinCameraPropertyState.
// 3. App writes locationID into kDarwinPtpDumpCmdSlot and posts
//    kDarwinPtpDumpCmd to request a dump for a specific device.
// 4. Extension performs the dump and publishes the resulting UTF-8 text back
//    over kDarwinPtpDumpText using the same multi-page slot chain (header
//    page + N data pages, additive checksum on each page).
// 5. App reassembles the text and opens it in TextEdit as an untitled
//    document via AppleScript (`make new document with properties {text:…}`)
//    — no file ever hits disk.
let kDarwinPtpDumpDevicesRequest = "org.ptpwebcam.darwin.PtpDumpDevicesRequest"
let kDarwinPtpDumpDevicesState   = "org.ptpwebcam.darwin.PtpDumpDevicesState"
let kDarwinPtpDumpDevicesSlotPrefix = "org.ptpwebcam.darwin.dumpdev."
let kDarwinPtpDumpDevicesSlotCount  = 256

let kDarwinPtpDumpCmd     = "org.ptpwebcam.darwin.PtpDumpCmd"
let kDarwinPtpDumpCmdSlot = "org.ptpwebcam.darwin.dumpcmd"  // payload: UInt64 locationID

let kDarwinPtpDumpText        = "org.ptpwebcam.darwin.PtpDumpText"
let kDarwinPtpDumpTextSlotPrefix = "org.ptpwebcam.darwin.dumptext."
let kDarwinPtpDumpTextSlotCount  = 2048  // ~16KB/page × multi-page = plenty for a dump

// Extension -> Agent: commands
@objc protocol PtpCameraAgentProtocol {
    func startLiveView(forCamera cameraId: String)
    func stopLiveView(forCamera cameraId: String)
    func setPropertyValue(_ value: Any, forProperty propertyId: NSNumber, onCamera cameraId: String)
}

// Agent -> Extension: events
@objc protocol PtpCameraAgentDelegateProtocol {
    func cameraConnected(_ cameraId: String, info: NSDictionary)
    func cameraDisconnected(_ cameraId: String)
    func receivedLiveViewJpegData(_ jpegData: Data, info: NSDictionary, forCamera cameraId: String)
    func propertyChanged(_ property: NSDictionary, forCamera cameraId: String)
}

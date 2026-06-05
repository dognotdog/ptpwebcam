
import Foundation
import IOSurface

let kPtpCameraAgentMachServiceName = "org.ptpwebcam.PtpWebcamApp.PtpCameraAgent"

let kPtpCameraStateNotification = "org.ptpwebcam.CameraStateChanged"
let kPtpCameraStateRequestNotification = "org.ptpwebcam.CameraStateRequest"
let kPtpCameraStatePath = "/tmp/org.ptpwebcam.cameras.plist"

// Darwin notification names (kernel-level, work across sandboxes)
let kDarwinCameraStateChanged = "org.ptpwebcam.darwin.CameraStateChanged"
let kDarwinCameraStateRequest = "org.ptpwebcam.darwin.CameraStateRequest"

// USB access coordination: extension → agent. See mirror copy in
// PtpCameraAgent/PtpCameraAgentProtocol.swift for the full App-Store-gap
// commentary. Required as long as ptpcamerad eviction depends on the
// agent's userspace kill rather than IOUSBHost DeviceCapture.
let kDarwinNeedUsbAccess  = "org.ptpwebcam.darwin.NeedUsbAccess"
let kDarwinUsbAccessReady = "org.ptpwebcam.darwin.UsbAccessReady"

// State slots: each holds 8 bytes via notify_set_state/notify_get_state.
// Slot 0 high 32 bits = total byte length, low 32 bits = reserved.
// Slots 1..N hold the JSON payload.
let kDarwinStateSlotCount = 64
let kDarwinStateSlotPrefix = "org.ptpwebcam.darwin.state."

// Note: the kDarwinLiveViewStart / Stop / Cmd* / Surface* / Frame* channels
// were part of an earlier architecture where the extension shipped JPEG
// frames to the agent for decoding into a shared IOSurface. Cross-UID
// IOSurfaceLookup is blocked by the kernel and the XPC fallback was never
// wired up end-to-end, so frame decoding now lives in the extension
// (jpegIntoPixelBuffer → CVPixelBuffer → CMIO stream). The slot
// definitions and the SurfaceSharingProtocol XPC service were removed
// when we cleaned up after the IOKit migration landed.

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
// See the host-side copy in PtpCameraAgent/PtpCameraAgentProtocol.swift
// for the full design notes — both copies are kept verbatim so each target
// can compile against its own module.
let kDarwinCameraStreamSlotPrefix = "org.ptpwebcam.darwin.cs.slot."
let kDarwinCameraStreamSlotCount  = 256
let kDarwinCameraStreamNack       = "org.ptpwebcam.darwin.cs.nack"
let kDarwinCameraStreamNackSlot   = "org.ptpwebcam.darwin.cs.nack.slot"
let kDarwinCameraStreamStart        = "org.ptpwebcam.darwin.cs.start"
let kDarwinCameraStreamStartSlot    = "org.ptpwebcam.darwin.cs.start.slot"
let kDarwinCameraStreamEnd          = "org.ptpwebcam.darwin.cs.end"
let kDarwinCameraStreamEndSlot      = "org.ptpwebcam.darwin.cs.end.slot"
let kDarwinCameraStreamRetransmit   = "org.ptpwebcam.darwin.cs.retx"
let kDarwinCameraStreamRetransmitSlot = "org.ptpwebcam.darwin.cs.retx.slot"

let kStreamDataSlotCount   = 255
let kStreamCheckpointIndex = 255
let kStreamPageSize        = kStreamDataSlotCount * 8

let kStreamPageEndOfStream    : UInt32 = 0xFFFFFF
let kStreamPageRetransmitStart: UInt32 = 0xFFFFFE
let kStreamPageMaxNormal      : UInt32 = 0xFFFFFD

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

/// CRC-32 (IEEE 802.3, polynomial 0xEDB88320). Identical implementation
/// to the host-side copy so the publisher and receiver compute matching
/// values byte-for-byte.
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

// Cross-process claim-state broadcast — see mirror in
// PtpCameraAgent/PtpCameraAgentProtocol.swift for the full design.
let kDarwinClaimAnnounce     = "org.ptpwebcam.darwin.ClaimAnnounce"
let kDarwinClaimAnnounceSlot = "org.ptpwebcam.darwin.claimannounce"

// Agent → Extension: property set command
// Agent writes a packed uint64 command to kDarwinPropertyCmdSlot, then posts kDarwinCameraPropertyCmd.
// Bit layout: [63:56] cmd (3=SET_PROP) | [55:48] reserved | [47:32] propId (UInt16) | [31:0] value (UInt32)
let kDarwinCameraPropertyCmd   = "org.ptpwebcam.darwin.PropertyCmd"
let kDarwinPropertyCmdSlot     = "org.ptpwebcam.darwin.propcmd"

// Extension → Agent: live view start failure. Mirrors agent-side protocol.
let kDarwinLiveViewFailed         = "org.ptpwebcam.darwin.LiveViewFailed"
let kDarwinLiveViewFailedSlotPrefix = "org.ptpwebcam.darwin.lvfail."
let kDarwinLiveViewFailedSlotCount  = 64

// USB-busy diagnostic — see mirror PtpCameraAgent/PtpCameraAgentProtocol.swift
// for the full commentary. Posted when openUsbCamera fails with
// kIOReturnExclusiveAccess so the agent can identify which app is
// holding ptpcamerad and offer to quit it.
let kDarwinUsbBlocked             = "org.ptpwebcam.darwin.UsbBlocked"
let kDarwinUsbBlockedSlotPrefix   = "org.ptpwebcam.darwin.usbblock."
let kDarwinUsbBlockedSlotCount    = 32

// Menu-bar status item visibility (mirrored from PtpCameraAgent copy).
let kDarwinMenuBarHidden     = "org.ptpwebcam.darwin.MenuBarHidden"
let kDarwinMenuBarHiddenSlot = "org.ptpwebcam.darwin.menubarhidden"

// Service-health heartbeats — see the mirror copy in
// PtpCameraAgent/PtpCameraAgentProtocol.swift for the full design notes.
let kDarwinExtensionHeartbeat      = "org.ptpwebcam.darwin.ExtensionHeartbeat"
let kDarwinExtensionHeartbeatSlot  = "org.ptpwebcam.darwin.extheartbeat"
let kDarwinAgentHeartbeat          = "org.ptpwebcam.darwin.AgentHeartbeat"
let kDarwinAgentHeartbeatSlot      = "org.ptpwebcam.darwin.agentheartbeat"
let kDarwinAgentSawExtension       = "org.ptpwebcam.darwin.AgentSawExtension"
let kDarwinAgentSawExtensionSlot   = "org.ptpwebcam.darwin.agentsawext"

// Per-camera streaming state — see mirror in
// PtpCameraAgent/PtpCameraAgentProtocol.swift for the full design.
let kDarwinStreamingChanged    = "org.ptpwebcam.darwin.StreamingChanged"
let kDarwinStreamingSlotPrefix = "org.ptpwebcam.darwin.streamcam."
let kDarwinStreamingSlotCount  = 8

// MARK: PTP property-dump channels (mirrored from PtpCameraAgent copy).
let kDarwinPtpDumpDevicesRequest = "org.ptpwebcam.darwin.PtpDumpDevicesRequest"
let kDarwinPtpDumpDevicesState   = "org.ptpwebcam.darwin.PtpDumpDevicesState"
let kDarwinPtpDumpDevicesSlotPrefix = "org.ptpwebcam.darwin.dumpdev."
let kDarwinPtpDumpDevicesSlotCount  = 256

let kDarwinPtpDumpCmd     = "org.ptpwebcam.darwin.PtpDumpCmd"
let kDarwinPtpDumpCmdSlot = "org.ptpwebcam.darwin.dumpcmd"

let kDarwinPtpDumpText        = "org.ptpwebcam.darwin.PtpDumpText"
let kDarwinPtpDumpTextSlotPrefix = "org.ptpwebcam.darwin.dumptext."
let kDarwinPtpDumpTextSlotCount  = 2048

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

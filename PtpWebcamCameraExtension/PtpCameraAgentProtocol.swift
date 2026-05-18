
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

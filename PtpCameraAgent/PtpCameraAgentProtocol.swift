import Foundation
import IOSurface

let kPtpCameraAgentMachServiceName = "org.ptpwebcam.PtpWebcamApp.PtpCameraAgent"

let kPtpCameraStateNotification = "org.ptpwebcam.CameraStateChanged"
let kPtpCameraStateRequestNotification = "org.ptpwebcam.CameraStateRequest"
let kPtpCameraStatePath = "/tmp/org.ptpwebcam.cameras.plist"

// Darwin notification names (kernel-level, work across sandboxes)
let kDarwinCameraStateChanged = "org.ptpwebcam.darwin.CameraStateChanged"
let kDarwinCameraStateRequest = "org.ptpwebcam.darwin.CameraStateRequest"

// Note: the kDarwinNeedUsbAccess / kDarwinUsbAccessReady channels used to
// ask the agent to kill ptpcamerad before the extension's USB open. Removed
// when the bridge switched to IOUSBHost's
// `IOUSBHostObjectInitOptionsDeviceSeize` — that newer eviction message is
// honored by ptpcamerad, so no userspace kill is needed and the agent runs
// inside the sandbox now.

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

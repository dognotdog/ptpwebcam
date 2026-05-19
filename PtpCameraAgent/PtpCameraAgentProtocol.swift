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


import Foundation
import IOSurface

let kPtpCameraAgentMachServiceName = "org.ptpwebcam.PtpCameraAgent"

let kPtpCameraStateNotification = "org.ptpwebcam.CameraStateChanged"
let kPtpCameraStateRequestNotification = "org.ptpwebcam.CameraStateRequest"
let kPtpCameraStatePath = "/tmp/org.ptpwebcam.cameras.plist"

// Darwin notification names (kernel-level, work across sandboxes)
let kDarwinCameraStateChanged = "org.ptpwebcam.darwin.CameraStateChanged"
let kDarwinCameraStateRequest = "org.ptpwebcam.darwin.CameraStateRequest"

// USB access coordination: extension → agent
// Extension posts this before opening IOUSBHostInterface so the agent can kill
// ptpcamerad (Apple's PTP daemon that otherwise holds exclusive USB ownership).
let kDarwinNeedUsbAccess  = "org.ptpwebcam.darwin.NeedUsbAccess"
// Agent posts this when ptpcamerad has been terminated and USB is free.
let kDarwinUsbAccessReady = "org.ptpwebcam.darwin.UsbAccessReady"

// State slots: each holds 8 bytes via notify_set_state/notify_get_state.
// Slot 0 high 32 bits = total byte length, low 32 bits = reserved.
// Slots 1..N hold the JSON payload.
let kDarwinStateSlotCount = 64
let kDarwinStateSlotPrefix = "org.ptpwebcam.darwin.state."

// Live view: extension → agent commands
let kDarwinLiveViewStart = "org.ptpwebcam.darwin.LiveViewStart"
let kDarwinLiveViewStop = "org.ptpwebcam.darwin.LiveViewStop"
// Command payload slots: slot 0 = cameraId length (UInt64), slots 1-8 = cameraId bytes
let kDarwinLiveViewCmdSlotPrefix = "org.ptpwebcam.darwin.lvcmd."
let kDarwinLiveViewCmdSlotCount = 9

// Live view: agent → extension surface registration
// Agent creates the IOSurface; extension (_cmiodalassistants / UID 262) calls IOSurfaceLookup.
let kDarwinLiveViewSurfaceReady = "org.ptpwebcam.darwin.LiveViewSurfaceReady"
// Surface payload slots: slot 0 = (IOSurfaceID << 32) | cameraId length, slots 1-8 = cameraId bytes
let kDarwinLiveViewSurfaceSlotPrefix = "org.ptpwebcam.darwin.lvsurface."
let kDarwinLiveViewSurfaceSlotCount = 9

// Live view: agent → extension frame-ready notification
// Agent draws JPEG into extension's IOSurface, then notifies via this name.
// Frame payload slots: slot 0 = cameraId length, slots 1-8 = cameraId bytes
let kDarwinLiveViewFrame = "org.ptpwebcam.darwin.LiveViewFrame"
let kDarwinLiveViewFrameSlotPrefix = "org.ptpwebcam.darwin.lvframe."
let kDarwinLiveViewFrameSlotCount = 9

// Extension → Agent: camera property state publication (multi-page protocol).
// Slot 0 (header): [63:32] totalLength | [31:16] pageIndex | [15:0] pageCount
// Slots 1..(N-2) (data): payload bytes for the current page, 8 bytes per slot.
// Slot N-1 (checksum): additive byte sum of page data (UInt32 in low 32 bits).
// Page data capacity: (kDarwinPropertySlotCount-2)*8 = 8176 bytes/page.
// Posts kDarwinCameraPropertyState once per page; receiver reassembles pages.
let kDarwinCameraPropertyState = "org.ptpwebcam.darwin.PropertyState"
let kDarwinPropertySlotPrefix  = "org.ptpwebcam.darwin.prop."
let kDarwinPropertySlotCount   = 2048

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

// Extension -> Agent: commands
@objc protocol PtpCameraAgentProtocol {
    func startLiveView(forCamera cameraId: String)
    func stopLiveView(forCamera cameraId: String)
    func setPropertyValue(_ value: Any, forProperty propertyId: NSNumber, onCamera cameraId: String)
}

// Dedicated surface-sharing protocol — agent exposes this on kPtpSurfaceSharingMachServiceName.
// IOSurface is transferred via Mach send right (NSXPCConnection / IOSurfaceCreateXPCObject internals),
// bypassing the cross-UID IOSurfaceLookup restriction.
let kPtpSurfaceSharingMachServiceName = "org.ptpwebcam.PtpCameraAgent.surface"

// Temp-file directory for live view frames (cross-UID, cross-sandbox-namespace).
// Agent writes JPEG atomically (write + rename); extension reads on Darwin notify.
// Both sandboxes allow this path via temporary-exception.files.absolute-path.read/write.
let kLiveViewDir = "/private/tmp/org.ptpwebcam.liveview"

@objc protocol SurfaceSharingProtocol {
    // Extension pushes its surface to the agent (agent draws JPEG into it).
    func receiveSurface(_ surface: IOSurface, cameraId: String, reply: @escaping (Bool) -> Void)
    // Extension pulls the agent's surface (agent creates it, extension wraps in CVPixelBuffer).
    func requestSurface(cameraId: String, reply: @escaping (IOSurface?) -> Void)
}

// Agent -> Extension: events
@objc protocol PtpCameraAgentDelegateProtocol {
    func cameraConnected(_ cameraId: String, info: NSDictionary)
    func cameraDisconnected(_ cameraId: String)
    func receivedLiveViewJpegData(_ jpegData: Data, info: NSDictionary, forCamera cameraId: String)
    func propertyChanged(_ property: NSDictionary, forCamera cameraId: String)
}

import Foundation

let kPtpCameraAgentMachServiceName = "org.ptpwebcam.PtpCameraAgent"

let kPtpCameraStateNotification = "org.ptpwebcam.CameraStateChanged"
let kPtpCameraStateRequestNotification = "org.ptpwebcam.CameraStateRequest"
let kPtpCameraStatePath = "/tmp/org.ptpwebcam.cameras.plist"

// Darwin notification names (kernel-level, work across sandboxes)
let kDarwinCameraStateChanged = "org.ptpwebcam.darwin.CameraStateChanged"
let kDarwinCameraStateRequest = "org.ptpwebcam.darwin.CameraStateRequest"

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

// Live view: agent → extension frame delivery via IOSurface
let kDarwinLiveViewFrame = "org.ptpwebcam.darwin.LiveViewFrame"
// Frame payload slots: slot 0 = (IOSurfaceID << 32) | cameraId length, slots 1-8 = cameraId bytes
let kDarwinLiveViewFrameSlotPrefix = "org.ptpwebcam.darwin.lvframe."
let kDarwinLiveViewFrameSlotCount = 9

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

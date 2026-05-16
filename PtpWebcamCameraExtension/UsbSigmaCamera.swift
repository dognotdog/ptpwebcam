// UsbSigmaCamera.swift
// Sigma fp / fp L PTP scaffold (VID 0x1003).
//
// Sigma's protocol family is distinct from Panasonic despite the cameras
// being often mentioned alongside (both are L-mount). Sigma uses their own
// 0x90xx opcode family (`Sigma.GetCamCanSetInfo`, `Sigma.SetCamDataGroup1-4`,
// `Sigma.SnapCommand`, `Sigma.GetCamViewFrame`, etc.) plus the standard
// `GetDevicePropDesc` for most settable properties.
//
// For now this class is a placeholder — the base class default discovery
// (`GetDevicePropDesc` over `standardPropertyIds`) produces a useful dump.
// Live view via `Sigma.GetCamViewFrame` and property writes via
// `Sigma.SetCamDataGroup*` are follow-up work that needs a real fp to
// validate against.

import Foundation

final class UsbSigmaCamera: UsbPtpCameraBase {

    init(transport: UsbPtpTransport) {
        super.init(transport: transport, logTag: "UsbSigmaCamera")
    }
}

// UsbLeicaCamera.swift
// Modern Leica PTP scaffold (VID 0x1A98).
//
// Covers M9 / M10 / M11, Q-series, SL-series, S3. These bodies speak
// fairly standard PTP and honour `GetDevicePropDesc` after `OpenSession`,
// so the base class default discovery handles property listing. Live
// view exists on Q and SL bodies but uses Leica-specific opcodes that
// are out of scope for this preliminary scaffold.
//
// Legacy Leica D-LUX / V-Lux / C-Lux bodies on VID 0x04DA are rebadged
// Panasonic Lumix firmware and dispatch to `UsbPanasonicCamera` instead
// via `protocolFamily(forVid:pid:)` — they never reach this class.

import Foundation

final class UsbLeicaCamera: UsbPtpCameraBase {

    init(transport: UsbPtpTransport) {
        super.init(transport: transport, logTag: "UsbLeicaCamera")
    }
}

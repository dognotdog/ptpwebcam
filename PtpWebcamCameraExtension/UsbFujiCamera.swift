// UsbFujiCamera.swift
// Fujifilm X/GFX PTP scaffold.
//
// Fuji bodies advertise the standard PTP property model — `GetDevicePropDesc`
// (0x1014) works directly after `OpenSession`. The base class's default
// `discoverAllProperties` already does exactly that, so this subclass is
// just a vendor-typed placeholder: it lets the registry return a non-nil
// object, and gives PtpDumper a real class instance to introspect.
//
// Tethered live view on Fuji uses `InitiateOpenCapture(0,0)` once, then
// repeated `GetObjectInfo(0x80000001)` + `GetObject` to fetch JPEG frames.
// That'll get added here when we wire frame fetch.

import Foundation

final class UsbFujiCamera: UsbPtpCameraBase {

    init(transport: UsbPtpTransport) {
        super.init(transport: transport, logTag: "UsbFujiCamera")
    }
}

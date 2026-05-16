// UsbPentaxCamera.swift
// Pentax K-series / Ricoh GR PTP scaffold.
//
// Pentax K-1 / K-3 III and Ricoh GR III / IIIx use standard PTP. Properties
// come through `GetDevicePropDesc` after a plain `OpenSession`, with no
// vendor handshake required — the base class default handles it. Live
// view on K-1 / K-3 III exists but uses a vendor-specific opcode that's
// out of scope for this preliminary scaffold.

import Foundation

final class UsbPentaxCamera: UsbPtpCameraBase {

    init(transport: UsbPtpTransport) {
        super.init(transport: transport, logTag: "UsbPentaxCamera")
    }
}

// UsbCameraRegistry.swift
// Maps USB vendor IDs to the appropriate UsbCameraProtocol implementation.

import Foundation

enum UsbCameraRegistry {
    static func makeCamera(transport: UsbPtpTransport) -> (any UsbCameraProtocol)? {
        switch transport.vendorId {
        case 0x04B0: return UsbNikonCamera(transport: transport)
        case 0x04A9: return UsbCanonCamera(transport: transport)
        case 0x054C: return UsbSonyCamera(transport: transport)
        default:     return nil
        }
    }
}

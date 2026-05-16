// UsbCameraRegistry.swift
// Maps USB vendor IDs to the appropriate UsbCameraProtocol implementation.

import Foundation

enum UsbCameraRegistry {
    static func makeCamera(transport: UsbPtpTransport) -> (any UsbCameraProtocol)? {
        switch PtpKnownCameras.protocolFamily(forVid: transport.vendorId,
                                              pid: transport.productId) {
        case .nikon:     return UsbNikonCamera(transport: transport)
        case .canon:     return UsbCanonCamera(transport: transport)
        case .sony:      return UsbSonyCamera(transport: transport)
        case .fuji:      return UsbFujiCamera(transport: transport)
        case .olympus:   return UsbOlympusCamera(transport: transport)
        case .panasonic: return UsbPanasonicCamera(transport: transport)
        case .pentax:    return UsbPentaxCamera(transport: transport)
        case .leica:     return UsbLeicaCamera(transport: transport)
        case .sigma:     return UsbSigmaCamera(transport: transport)
        case .unknown:   return nil
        }
    }
}

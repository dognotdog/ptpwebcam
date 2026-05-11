import Foundation
import IOSurface
import os.log

private let log = Logger(subsystem: "org.ptpwebcam.PtpCameraAgent", category: "SurfaceSharing")
private func slog(_ msg: String) { log.fault("\(msg, privacy: .public)") }

// MARK: - AgentXPCDelegate

/// Separate NSXPCListener for SurfaceSharingProtocol, listening on kPtpSurfaceSharingMachServiceName.
/// The extension connects here (via the mach-lookup exception entitlement) to exchange IOSurface objects.
/// IOSurface is transferred as a Mach send right — no IOSurfaceLookup needed.
class AgentXPCDelegate: NSObject, NSXPCListenerDelegate, SurfaceSharingProtocol {

    // Surfaces indexed by cameraId, either created by the agent or received from the extension.
    private var surfaces: [String: IOSurface] = [:]
    // Called by AppDelegate after it creates/receives a surface.
    var onSurfaceRegistered: ((_ surface: IOSurface, _ cameraId: String) -> Void)?

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        slog("SurfaceSharing: shouldAcceptNewConnection from PID \(connection.processIdentifier)")

        guard isConnectionAuthorized(connection) else {
            slog("SurfaceSharing: connection rejected (unauthorized)")
            return false
        }

        let interface = NSXPCInterface(with: SurfaceSharingProtocol.self)
        // receiveSurface(_:cameraId:reply:) — IOSurface is argument 0 (not the reply).
        interface.setClasses(
            NSSet(array: [IOSurface.self]) as! Set<AnyHashable>,
            for: #selector(SurfaceSharingProtocol.receiveSurface(_:cameraId:reply:)),
            argumentIndex: 0, ofReply: false)
        // requestSurface(cameraId:reply:) — IOSurface? is argument 0 of the reply block.
        interface.setClasses(
            NSSet(array: [IOSurface.self]) as! Set<AnyHashable>,
            for: #selector(SurfaceSharingProtocol.requestSurface(cameraId:reply:)),
            argumentIndex: 0, ofReply: true)

        connection.exportedInterface = interface
        connection.exportedObject = self
        connection.invalidationHandler = {
            slog("SurfaceSharing: connection from PID \(connection.processIdentifier) invalidated")
        }
        connection.resume()
        slog("SurfaceSharing: connection accepted from PID \(connection.processIdentifier)")
        return true
    }

    // MARK: SurfaceSharingProtocol

    func receiveSurface(_ surface: IOSurface, cameraId: String, reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            slog("SurfaceSharing: receiveSurface id=\(IOSurfaceGetID(surface)) cameraId=\(cameraId)")
            self.surfaces[cameraId] = surface
            self.onSurfaceRegistered?(surface, cameraId)
            reply(true)
        }
    }

    func requestSurface(cameraId: String, reply: @escaping (IOSurface?) -> Void) {
        DispatchQueue.main.async {
            let surface = self.surfaces[cameraId]
            slog("SurfaceSharing: requestSurface cameraId=\(cameraId) → id=\(surface.map { "\(IOSurfaceGetID($0))" } ?? "nil")")
            reply(surface)
        }
    }

    // Called by AppDelegate to store an agent-created surface so the extension can request it.
    func storeSurface(_ surface: IOSurface, cameraId: String) {
        DispatchQueue.main.async {
            self.surfaces[cameraId] = surface
        }
    }

    func removeSurface(cameraId: String) {
        DispatchQueue.main.async {
            self.surfaces.removeValue(forKey: cameraId)
        }
    }

    // MARK: Authorization

    private func isConnectionAuthorized(_ connection: NSXPCConnection) -> Bool {
        // The Mach service is registered via launchd with a private name, so only processes
        // that have the mach-lookup entitlement for this name can reach us.
        // Accept all code-signed connections (CMIO extension uses Apple's team, not ours).
        slog("SurfaceSharing: authorizing connection from PID \(connection.processIdentifier)")
        return true
    }
}

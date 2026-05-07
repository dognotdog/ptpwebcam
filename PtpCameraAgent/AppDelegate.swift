//
//  AppDelegate.swift
//  PtpCameraAgent
//
//  Created by Dömötör Gulyás on 02.12.2023.
//  Copyright © 2023 org.ptpwebcam. All rights reserved.
//

import Cocoa
import ImageCaptureCore
import os.log

@main
class AppDelegate: NSObject, NSApplicationDelegate, ICDeviceBrowserDelegate, ICDeviceDelegate {

    private let logger = Logger(subsystem: "org.ptpwebcam.PtpCameraAgent", category: "Agent")
    private var deviceBrowser: ICDeviceBrowser!
    private var xpcListener: NSXPCListener!
    private static let logFile: FileHandle? = {
        let path = "/tmp/PtpCameraAgent.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static func log(_ msg: String) {
        let line = "\(Date()): \(msg)\n"
        logFile?.seekToEndOfFile()
        logFile?.write(line.data(using: .utf8)!)
        NSLog("%@", msg)
    }
    private var connectedCameras: [String: ICDevice] = [:]
    private var extensionConnections: [NSXPCConnection] = []

    private var simulatedCameras: [String: NSDictionary] = [:]

    private var darwinSlotTokens: [Int32] = []

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        AppDelegate.log("PtpCameraAgent: applicationDidFinishLaunching")

        darwinSlotTokens = (0..<kDarwinStateSlotCount).map { i in
            var token: Int32 = 0
            darwin_notify_register_check(kDarwinStateSlotPrefix + "\(i)", &token)
            return token
        }

        var requestToken: Int32 = 0
        darwin_notify_register_dispatch(kDarwinCameraStateRequest, &requestToken, .main) { [weak self] _ in
            AppDelegate.log("PtpCameraAgent: received Darwin state request")
            self?.publishCameraState()
        }

        xpcListener = NSXPCListener(machServiceName: kPtpCameraAgentMachServiceName)
        xpcListener.delegate = self
        xpcListener.resume()
        AppDelegate.log("PtpCameraAgent: XPC listener started on \(kPtpCameraAgentMachServiceName)")

        deviceBrowser = ICDeviceBrowser()
        deviceBrowser.delegate = self
        deviceBrowser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        deviceBrowser.start()
        AppDelegate.log("PtpCameraAgent: ICDeviceBrowser started")

        #if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.addSimulatedCamera()
        }
        #endif
    }

    #if DEBUG
    private func addSimulatedCamera() {
        let cameraId = "simulated-nikon-d800"
        let info: NSDictionary = [
            "name": "Simulated Nikon D800",
            "cameraId": cameraId,
        ]
        simulatedCameras[cameraId] = info
        AppDelegate.log("PtpCameraAgent: Adding simulated camera: \(cameraId)")
        publishCameraState()
    }
    #endif

    private func publishCameraState() {
        var cameras: [[String: String]] = []
        for (cameraId, device) in connectedCameras {
            cameras.append(["cameraId": cameraId, "name": device.name ?? "Unknown Camera"])
        }
        #if DEBUG
        for (cameraId, info) in simulatedCameras {
            cameras.append(["cameraId": cameraId, "name": info["name"] as? String ?? "Simulated"])
        }
        #endif

        guard let jsonData = try? JSONSerialization.data(withJSONObject: cameras) else { return }
        let maxPayload = (kDarwinStateSlotCount - 1) * 8
        guard jsonData.count <= maxPayload else {
            AppDelegate.log("PtpCameraAgent: camera state too large (\(jsonData.count) bytes, max \(maxPayload))")
            return
        }

        // Slot 0: length in high 32 bits
        darwin_notify_set_state(darwinSlotTokens[0], UInt64(jsonData.count) << 32)

        // Slots 1..N: 8-byte chunks of JSON
        for i in 0..<((jsonData.count + 7) / 8) {
            let offset = i * 8
            var value: UInt64 = 0
            let chunkSize = min(8, jsonData.count - offset)
            jsonData.withUnsafeBytes { ptr in
                memcpy(&value, ptr.baseAddress! + offset, chunkSize)
            }
            darwin_notify_set_state(darwinSlotTokens[i + 1], value)
        }

        darwin_notify_post(kDarwinCameraStateChanged)
        AppDelegate.log("PtpCameraAgent: published \(cameras.count) camera(s), \(jsonData.count) bytes via Darwin state slots")
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        deviceBrowser.stop()
        try? FileManager.default.removeItem(atPath: kPtpCameraStatePath)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - ICDeviceBrowserDelegate

    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        AppDelegate.log("PtpCameraAgent: deviceBrowserDidEnumerateLocalDevices, devices: \(browser.devices?.count ?? 0)")
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        AppDelegate.log("PtpCameraAgent: deviceBrowser didAdd device: \(device.name ?? "unnamed") type=\(device.type.rawValue)")
        guard device is ICCameraDevice else { return }

        let cameraId = device.uuidString ?? device.name ?? "unknown"
        AppDelegate.log("PtpCameraAgent: Camera added: \(cameraId) (\(device.name ?? "unnamed"))")

        connectedCameras[cameraId] = device
        device.delegate = self
        publishCameraState()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let cameraId = device.uuidString ?? device.name ?? "unknown"
        AppDelegate.log("PtpCameraAgent: Camera removed: \(cameraId)")
        connectedCameras.removeValue(forKey: cameraId)
        publishCameraState()
    }

    // MARK: - ICDeviceDelegate

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error = error {
            logger.error("Failed to open session: \(error.localizedDescription)")
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
    }

    func didRemove(_ device: ICDevice) {
    }
}

// MARK: - NSXPCListenerDelegate

extension AppDelegate: NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        AppDelegate.log("PtpCameraAgent: shouldAcceptNewConnection from PID \(newConnection.processIdentifier)")

        let agentInterface = NSXPCInterface(with: PtpCameraAgentProtocol.self)
        newConnection.exportedInterface = agentInterface
        newConnection.exportedObject = self

        let delegateInterface = NSXPCInterface(with: PtpCameraAgentDelegateProtocol.self)
        newConnection.remoteObjectInterface = delegateInterface

        newConnection.invalidationHandler = { [weak self] in
            self?.extensionConnections.removeAll { $0 === newConnection }
            AppDelegate.log("PtpCameraAgent: XPC connection invalidated")
        }

        extensionConnections.append(newConnection)
        newConnection.resume()
        AppDelegate.log("PtpCameraAgent: XPC connection accepted")

        // Send current camera list to newly connected client
        DispatchQueue.main.async {
            guard let proxy = newConnection.remoteObjectProxy as? PtpCameraAgentDelegateProtocol else { return }
            for (cameraId, device) in self.connectedCameras {
                let info: NSDictionary = [
                    "name": device.name ?? "Unknown Camera",
                    "cameraId": cameraId,
                ]
                proxy.cameraConnected(cameraId, info: info)
            }
            #if DEBUG
            for (cameraId, info) in self.simulatedCameras {
                proxy.cameraConnected(cameraId, info: info)
            }
            #endif
        }

        return true
    }
}

// MARK: - PtpCameraAgentProtocol

extension AppDelegate: PtpCameraAgentProtocol {
    func startLiveView(forCamera cameraId: String) {
        logger.info("startLiveView requested for \(cameraId)")
        // TODO: open session and start live view on the ICCameraDevice
    }

    func stopLiveView(forCamera cameraId: String) {
        logger.info("stopLiveView requested for \(cameraId)")
        // TODO: stop live view
    }

    func setPropertyValue(_ value: Any, forProperty propertyId: NSNumber, onCamera cameraId: String) {
        logger.info("setProperty \(propertyId) requested for \(cameraId)")
        // TODO: send PTP property change command
    }
}


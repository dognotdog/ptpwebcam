//
//  AppDelegate.swift
//  PtpWebcamApp
//
//  Created by Dömötör Gulyás on 02.12.2023.
//  Copyright © 2023 org.ptpwebcam. All rights reserved.
//

import Cocoa
import SystemExtensions
import OSLog
import ServiceManagement

@main
class AppDelegate: NSObject, NSApplicationDelegate, OSSystemExtensionRequestDelegate {

	@IBOutlet var window: NSWindow!

	func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
		return OSSystemExtensionRequest.ReplacementAction.replace
	}
	
	func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
		
	}
	
	func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
		os_log("loaded system extension with result %{public}i", Int(result.rawValue))
	}
	
	func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
		os_log("failed to load system extension with error %{public}@", error.localizedDescription)
	}

	func applicationDidFinishLaunching(_ aNotification: Notification) {
		// Insert code here to initialize your application

		// The bundle identifier of your extension.
		let exitensionIdentifier = "org.ptpwebcam.CameraExtension"

		// Submit an activation request.
		let activationRequest = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: exitensionIdentifier, queue: .main)
		activationRequest.delegate = self
		OSSystemExtensionManager.shared.submitRequest(activationRequest)

		let service = SMAppService.agent(plistName: "org.ptpwebcam.CameraAgent.plist")

		async {
			do {
				try service.register()
				print("Successfully registered \(service)")
			} catch {
				print("Unable to register \(error)")
				exit(1)
			}
		}
	}

	func applicationWillTerminate(_ aNotification: Notification) {
		// Insert code here to tear down your application
	}

	func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
		return true
	}


}


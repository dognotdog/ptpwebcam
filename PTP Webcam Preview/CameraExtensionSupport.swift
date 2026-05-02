//
//  CameraExtensionSupport.swift
//  PTP Webcam Preview
//
//  Created by Dömötör Gulyás on 02.12.2023.
//  Copyright © 2023 InRobCo. All rights reserved.
//

import Foundation
import SystemExtensions
import OSLog
import ServiceManagement

class CameraExtensionSupport: NSObject, OSSystemExtensionRequestDelegate {
	
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
	
	override init() {
		super.init()
		
		// The bundle identifier of your extension.
		let exitensionIdentifier = "org.ptpwebcam.PtpWebcamCameraExtension"


		// Submit an activation request.
		let activationRequest = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: exitensionIdentifier, queue: .main)
		activationRequest.delegate = self
		OSSystemExtensionManager.shared.submitRequest(activationRequest)

		let service = SMAppService.agent(plistName: "com.xpc.example.agent.plist")

		do {
			try service.register()
			print("Successfully registered \(service)")
		} catch {
			print("Unable to register \(error)")
			exit(1)
		}

	}
}

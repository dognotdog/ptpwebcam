//
//  AppDelegate.swift
//  CameraAgent
//
//  Created by Dömötör Gulyás on 02.12.2023.
//  Copyright © 2023 org.ptpwebcam. All rights reserved.
//

import Cocoa
import ImageCaptureCore
import AVKit

@main
class AppDelegate: NSObject, NSApplicationDelegate, ICDeviceBrowserDelegate,  ICDeviceDelegate {
	
	@IBOutlet var window: NSWindow!
	
	var discoverySession : AVCaptureDevice.DiscoverySession? = nil

	
	func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
		return
	}
	
	func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
		return
	}
	
	func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
		return
	}
	
	func didRemove(_ device: ICDevice) {
		return
	}
	
	func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
		return
	}
	
	func applicationDidFinishLaunching(_ aNotification: Notification) {
		// Insert code here to initialize your application
		var matchTime = NSDate().timeIntervalSinceReferenceDate
		var matchSource = DispatchSource.makeUserDataOrSource()
		matchSource.setEventHandler(handler: {
			self.scanForUvcDevices()
			
			var now = NSDate().timeIntervalSinceReferenceDate
			
			if (now - matchTime < 10.0) {
				DispatchQueue.main.schedule(after: .init(.now() + 3)) {
					matchSource.or(data: 1)
				}
			}
			
			matchSource.or(data: 1)
		})
	}

	func applicationWillTerminate(_ aNotification: Notification) {
		// Insert code here to tear down your application
	}

	func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
		return true
	}

	func scanForUvcDevices() {
		if #available(macOS 14.0, *) {
			discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: AVCaptureDevice.Position.unspecified)
		} else {
			discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown], mediaType: .video, position: AVCaptureDevice.Position.unspecified)
		}
		
//		discoverySession.st
		
//		var devices = session.devices
		
	}

}


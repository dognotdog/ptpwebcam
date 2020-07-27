//
//  PtpWebcamAssistantService.m
//  PtpWebcamAssistantService
//
//  Created by Dömötör Gulyás on 22.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamAssistantService.h"
#import "PtpCameraProtocol.h"
#import "PtpCamera.h"
#import "PtpWebcamAlerts.h"

#import <AppKit/AppKit.h>

@interface PtpWebcamAssistantService ()
{
	ICDeviceBrowser* deviceBrowser;
	
}
@end

@implementation PtpWebcamAssistantService

- (instancetype) init
{
	if (!(self = [super init]))
		return nil;
	
	self.devices = @{};
	self.connections = @[];
	
	
	deviceBrowser = [[ICDeviceBrowser alloc] init];
	deviceBrowser.delegate = self;
	deviceBrowser.browsedDeviceTypeMask |= ICDeviceTypeMaskCamera | ICDeviceLocationTypeMaskLocal;
	

	[deviceBrowser start];
	
	return self;
}


- (void) deviceDidBecomeReadyWithCompleteContentCatalog:(ICCameraDevice *) icCamera
{
	PtpLog(@"");
	
	// create and register stream and device
	
	PtpCamera* device = [[PtpCamera alloc] initWithIcCamera: icCamera service: self];
	
	if (!device)
	{
		PtpWebcamShowCatastrophicAlert(@"Camera with USB Vendor ID 0x%04X, Product ID 0x%04X could not be instantiated.", icCamera.usbVendorID, icCamera.usbProductID);
		return;
	}
	
	@synchronized (self) {
		NSMutableDictionary* devices = self.devices.mutableCopy;
		devices[device.cameraId] = device;
		self.devices = devices;
	}
}

- (void)deviceBrowser:(ICDeviceBrowser*)browser didAddDevice:(ICDevice*)camera moreComing:(BOOL) moreComing
{
//	NSLog(@"add device %@", device);
	NSDictionary* cameraInfo = [PtpCamera isDeviceSupported: camera];
	if (cameraInfo)
	{
		if (![cameraInfo[@"confirmed"] boolValue])
		{
			PTPWebcamShowCameraIssueBlockingAlert(cameraInfo[@"make"], cameraInfo[@"model"]);
		}
//		NSLog(@"camera capabilities %@", camera.capabilities);
		camera.delegate = self;
		[camera requestOpenSession];

	}
}

- (void)deviceBrowser:(nonnull ICDeviceBrowser *)browser didRemoveDevice:(nonnull ICDevice *)icDevice moreGoing:(BOOL)moreGoing
{
	NSLog(@"remove device %@", icDevice);
	
	for(id cameraId in self.devices.copy)
	{
		
//			PtpCamera* cam = (id)device;
//			if ([icDevice isEqual: cam.icCamera])
//				[cam didRemoveDevice];
		@synchronized (self) {
			NSMutableDictionary* devices = self.devices.mutableCopy;
			[devices removeObjectForKey: cameraId];
			self.devices = devices;
		}
	}
}


- (void) device:(ICDevice *)device didOpenSessionWithError:(NSError *)error
{
	NSLog(@"device didOpenSession");
	if (error)
		NSLog(@"device could not open session because %@", error);
	
}

- (void)device:(nonnull ICDevice *)device didCloseSessionWithError:(nonnull NSError *)error {
}


- (void)didRemoveDevice:(nonnull ICDevice *)device
{
	// do nothing, as we receive a notification from the device browser, roo
}


- (void) cameraReady: (PtpCamera*) camera
{
	NSDictionary* cameraInfo = @{
		@"make" : camera.make,
		@"model" : camera.model,
		@"serialNumber" : camera.icCamera.serialNumberString,
	};
	for (NSXPCConnection* connection in self.connections)
	{
		[[connection remoteObjectProxy] cameraConnected: camera.cameraId withInfo: cameraInfo];
	}
}

- (void) camera:(PtpCamera *)camera didReceiveLiveViewJpegImage:(NSData *)jpegData withInfo:(NSDictionary *)info
{
	for (NSXPCConnection* connection in self.connections)
	{
		[[connection remoteObjectProxy] receivedLiveViewJpegImageData: jpegData withInfo: @{} forCameraWithId: camera.cameraId];
	}

}

- (void) cameraLiveViewReady:(PtpCamera *)camera
{
	PtpLog(@"");
	for (NSXPCConnection* connection in self.connections)
	{
		[[connection remoteObjectProxy] liveViewReadyforCameraWithId: camera.cameraId];
	}
}

// MARK: Assistant Service Delegate

- (void) pingService: (void (^)(void))pongCallback
{
	PtpLog(@"ping received.");
	pongCallback();
}

- (void) startLiveViewForCamera:(id)cameraId
{
	PtpCamera* camera = self.devices[cameraId];
	[camera startLiveView];
}

- (void) stopLiveViewForCamera:(id)cameraId
{
	PtpCamera* camera = self.devices[cameraId];
	[camera stopLiveView];
}


- (void) requestLiveViewImageForCamera:(id)cameraId
{
	PtpCamera* camera = self.devices[cameraId];
	
	[camera requestLiveViewImage];
	
}


@end

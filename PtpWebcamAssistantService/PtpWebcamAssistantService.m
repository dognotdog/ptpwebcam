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
#import "PtpCameraMachAssistant.h"
#import "../PtpWebcamDalPlugin/PtpWebcamAlerts.h"

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
	
	PtpCameraMachAssistant* cameraDelegate = [[PtpCameraMachAssistant alloc] init];
	cameraDelegate.service = self;
	
	PtpCamera* device = [PtpCamera cameraWithIcCamera: icCamera delegate: cameraDelegate];
	cameraDelegate.camera = device;
	
	if (!device)
	{
		PtpWebcamShowCatastrophicAlert(@"Camera with USB Vendor ID 0x%04X, Product ID 0x%04X could not be instantiated.", icCamera.usbVendorID, icCamera.usbProductID);
		return;
	}
	
	@synchronized (self) {
		NSMutableDictionary* devices = self.devices.mutableCopy;
		devices[device.cameraId] = cameraDelegate;
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
		
		PtpCamera* camera = [self.devices[cameraId] camera];
		
		if ([icDevice isEqual: camera.icCamera])
		{
			// remove camera from devices list
			@synchronized (self) {
				NSMutableDictionary* devices = self.devices.mutableCopy;
				[devices removeObjectForKey: cameraId];
				self.devices = devices;
			}
			
			// notify clients that camera is gone
			for (NSXPCConnection* connection in self.connections)
			{
				[[connection remoteObjectProxy] cameraDisconnected: camera.cameraId];
			}

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

- (NSDictionary*) cameraConnectionInfo: (PtpCamera*) camera
{
	NSDictionary* cameraInfo = @{
		@"make" : camera.make,
		@"model" : camera.model,
		@"serialNumber" : camera.icCamera.serialNumberString,
	};
	return cameraInfo;
}

- (void) cameraReady: (PtpCamera*) camera
{
	NSDictionary* cameraInfo = [self cameraConnectionInfo: camera];
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

// MARK: Listener Delegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection
{
    // This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
	    
    // Configure the connection.
    // First, set the interface that the exported object implements.
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpWebcamAssistantServiceProtocol)];
	
//	NSXPCInterface* cameraInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpCameraProtocol)];
	
	NSXPCInterface* remoteInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpWebcamAssistantDelegateProtocol)];
//	[remoteInterface setInterface: cameraInterface forSelector: @selector(cameraConnected:) argumentIndex: 0 ofReply: NO];
	
	
	newConnection.remoteObjectInterface = remoteInterface;
    
    // Next, set the object that the connection exports. All messages sent on the connection to this service will be sent to the exported object to handle. The connection retains the exported object.
    newConnection.exportedObject = self;
    
	// remove connection from list when it becomes invalidated
	__weak NSXPCConnection* weakConnection = newConnection;
	newConnection.invalidationHandler = ^{
		PtpLog(@"connection died");
		NSXPCConnection* connection = weakConnection;
		if (connection)
		{
			@synchronized (self) {
				NSMutableArray* connections = self.connections.mutableCopy;
				[connections removeObject: connection];
				self.connections = connections;
			}
		}
	};

	@synchronized (self) {
		self.connections = [self.connections arrayByAddingObject: newConnection];
	}

    // Resuming the connection allows the system to deliver more incoming messages.
    [newConnection resume];
	    
    // Returning YES from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call -invalidate on the connection and return NO.
    return YES;
}


// MARK: Assistant Service Delegate

- (void) pingService: (void (^)(void))pongCallback
{
	PtpLog(@"ping received.");
	pongCallback();
	
	// after the initial ping, also inform the client of already connected devices
	NSXPCConnection* connection = [NSXPCConnection currentConnection];
	for (PtpCameraMachAssistant* cameraDelegate in self.devices.allValues)
	{
		PtpCamera* camera = cameraDelegate.camera;
		[[connection remoteObjectProxy] cameraConnected: camera.cameraId withInfo: [self cameraConnectionInfo: camera]];
	}
}

- (void) startLiveViewForCamera:(id)cameraId
{
	PtpCamera* camera = [self.devices[cameraId] camera];
	[camera startLiveView];
}

- (void) stopLiveViewForCamera:(id)cameraId
{
	PtpCamera* camera = [self.devices[cameraId] camera];
	[camera stopLiveView];
}


- (void) requestLiveViewImageForCamera:(id)cameraId
{
	PtpCamera* camera = [self.devices[cameraId] camera];
	
	[camera requestLiveViewImage];
	
}


@end

//
//  PtpWebcamPlugin.m
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 30.05.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamPlugin.h"
#import "PtpWebcamPtpDevice.h"
#import "PtpWebcamPtpStream.h"
#import "PtpWebcamXpcDevice.h"
#import "PtpWebcamXpcStream.h"
#import "PtpWebcamDummyDevice.h"
#import "PtpWebcamDummyStream.h"
#import "PtpWebcamAlerts.h"

#import "../PtpWebcamAssistantService/PtpWebcamAssistantServiceProtocol.h"
#import "../PtpWebcamAssistantService/PtpCameraProtocol.h"
//#import "../PtpWebcamAgent/PtpWebcamAgentProtocol.h"

#import <ImageCaptureCore/ImageCaptureCore.h>

#import <ServiceManagement/ServiceManagement.h>

// define DUMMY_DEVICE_ENABLED to enable the dummy device to test that the DAL plugin can deliver images without a camera connection
//#define DUMMY_DEVICE_ENABLED=1

@interface PtpWebcamPlugin ()
{
	ICDeviceBrowser* deviceBrowser;
	
	NSXPCConnection* assistantConnection;
}
@end

@implementation PtpWebcamPlugin

- (instancetype) init
{
	if (!(self = [super init]))
		return nil;
	
	self.devices = @{};
	
	return self;
}

- (BOOL) isDalaSystemInitingOrExiting
{
	CMIOObjectPropertyAddress propAddr = {
		.mSelector = kCMIOHardwarePropertyIsInitingOrExiting,
		.mScope = kCMIOObjectPropertyScopeGlobal,
		.mElement = kCMIOObjectPropertyElementMaster,
	};
	uint32_t dataUsed = 0;
	uint32_t isInitingOrExiting = 0;
	CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &propAddr, 0, NULL, sizeof(isInitingOrExiting), &dataUsed, &isInitingOrExiting);
	
	return isInitingOrExiting != 0;
}

- (BOOL) isDalaSystemMaster
{
	CMIOObjectPropertyAddress propAddr = {
		.mSelector = kCMIOHardwarePropertyProcessIsMaster,
		.mScope = kCMIOObjectPropertyScopeGlobal,
		.mElement = kCMIOObjectPropertyElementMaster,
	};
	uint32_t dataUsed = 0;
	uint32_t isMaster = 0;
	CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &propAddr, 0, NULL, sizeof(isMaster), &dataUsed, &isMaster);
	
	return isMaster != 0;

}

- (void) deviceRemoved: (id) device
{
	
}

- (OSStatus) initialize
{
	[self connectToAssistantService];
	
	deviceBrowser = [[ICDeviceBrowser alloc] init];
	deviceBrowser.delegate = self;
	deviceBrowser.browsedDeviceTypeMask |= ICDeviceTypeMaskCamera | ICDeviceLocationTypeMaskLocal;
	
//	[deviceBrowser start];
	
#ifdef DUMMY_DEVICE_ENABLED
	[self createDummyDeviceAndStream];
#endif
	
//	[self createStatusItem];

	return kCMIOHardwareNoError;
}

- (OSStatus) teardown
{
	if (deviceEventDispatchSource)
	{
		dispatch_source_cancel(deviceEventDispatchSource);
		deviceEventDispatchSource = NULL;
	}
	
	// Do the full teardown if this is outside of the process being torn down or this is the master process
	if (![self isDalaSystemInitingOrExiting] || [self isDalaSystemMaster])
	{
		for (id device in self.devices.copy)
		{
			[self deviceRemoved: device];
		}
	}
	else
	{
		for (PtpWebcamDevice* device in self.devices.copy)
		{
			[device unplugDevice];
			[device finalizeDevice];
		}

	}
	
//	[self removeStatusItem];

	return kCMIOHardwareNoError;
}


- (void) createDummyDeviceAndStream
{
	PtpWebcamDummyDevice* device = [[PtpWebcamDummyDevice alloc] initWithPluginInterface: self.pluginInterfaceRef];
	[device createCmioDeviceWithPluginId: self.objectId];
	[PtpWebcamObject registerObject: device];
	
	PtpWebcamDummyStream* stream = [[PtpWebcamDummyStream alloc] initWithPluginInterface: self.pluginInterfaceRef];
	[stream createCmioStreamWithDevice: device];
	[PtpWebcamObject registerObject: stream];

	// then publish stream and device
	[device publishCmioDevice];
	[stream publishCmioStream];
	
	@synchronized (self) {
		NSMutableDictionary* devices = self.devices.mutableCopy;
		devices[@"dummy"] = device;
		self.devices = devices;
	}

}

- (void) deviceDidBecomeReadyWithCompleteContentCatalog:(ICCameraDevice *)camera
{
	NSLog(@"deviceDidBecomeReadyWithCompleteContentCatalog %@", camera);
	
	// create and register stream and device
	
	PtpWebcamPtpDevice* device = [[PtpWebcamPtpDevice alloc] initWithIcDevice: camera pluginInterface: self.pluginInterfaceRef];
	[device createCmioDeviceWithPluginId: self.objectId];
	[PtpWebcamObject registerObject: device];
	
	PtpWebcamPtpStream* stream = [[PtpWebcamPtpStream alloc] initWithPluginInterface: self.pluginInterfaceRef];
	stream.ptpDevice = device;
	[stream createCmioStreamWithDevice: device];
	[PtpWebcamObject registerObject: stream];

	// then publish stream and device
	[device publishCmioDevice];
	[stream publishCmioStream];
	
	@synchronized (self) {
		NSMutableDictionary* devices = self.devices.mutableCopy;
		devices[device.deviceUid] = device;
		self.devices = devices;
	}
}

- (void)deviceBrowser:(ICDeviceBrowser*)browser didAddDevice:(ICDevice*)camera moreComing:(BOOL) moreComing
{
//	NSLog(@"add device %@", device);
	NSDictionary* cameraInfo = [PtpWebcamPtpDevice supportsCamera: camera];
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
	
	for(PtpWebcamDevice* device in self.devices)
	{
		if([device isKindOfClass: [PtpWebcamPtpDevice class]])
		{
			PtpWebcamPtpDevice* ptpDevice = (id)device;
			if ([icDevice isEqual: ptpDevice.cameraDevice])
				[ptpDevice unplugDevice];
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


- (void)didRemoveDevice:(nonnull ICDevice *)device {
}



//- (void)deviceBrowser:(ICDeviceBrowser*)browser didRemoveDevice:(ICDevice*)device moreGoing:(BOOL) moreGoing
//{
//	NSLog(@"remove device %@", device);
//
////	if (self.device.cameraDevice == cameraDevice)
////	{
////		[self.device.stream stopStream];
////		cameraDevice = nil;
////	}
//
//}

//- (NSData * _Nullable)getPropertyDataForAddress:(CMIOObjectPropertyAddress)address qualifierData:(nonnull NSData *)qualifierData {
//	<#code#>
//}
//
//- (uint32_t)getPropertyDataSizeForAddress:(CMIOObjectPropertyAddress)address qualifierData:(NSData * _Nullable)qualifierData {
//	<#code#>
//}
//
//- (BOOL)hasPropertyWithAddress:(CMIOObjectPropertyAddress)address {
//	<#code#>
//}
//
//- (BOOL)isPropertySettable:(CMIOObjectPropertyAddress)address {
//	<#code#>
//}
//
//- (OSStatus)setPropertyDataForAddress:(CMIOObjectPropertyAddress)address qualifierData:(NSData * _Nullable)qualifierData data:(nonnull NSData *)data {
//	<#code#>
//}

- (void) connectToAssistantService
{
//	assistantConnection = [[NSXPCConnection alloc] initWithMachServiceName: @"org.ptpwebcam.PtpWebcamAssistant" options: 0];

	
	
//	NSString* agentPath = @"/Library/CoreMediaIO/Plug-ins/DAL/PtpWebcamDalPlugin.plugin/Contents/Library/LoginItems/PtpWebcamAgent.app";
//	OSStatus err =  LSRegisterURL((__bridge CFURLRef)[NSURL fileURLWithPath: agentPath], false);
//	assert(noErr == err);

	assistantConnection = [[NSXPCConnection alloc] initWithServiceName: @"org.ptpwebcam.PtpWebcamAssistantService"];
//	NSString* agentId = @"org.ptpwebcam.PtpWebcamAgent";
//	SMLoginItemSetEnabled((__bridge CFStringRef)agentId, true);
//	assistantConnection = [[NSXPCConnection alloc] initWithMachServiceName: @"org.ptpwebcam.PtpWebcamAgent" options: 0];
	assistantConnection.invalidationHandler = ^{
		NSLog(@"oops, connection failed: %@", self->assistantConnection);
	};
	assistantConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpWebcamAssistantServiceProtocol)];
	
//	NSXPCInterface* cameraInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PtpCameraProtocol)];
	NSXPCInterface* exportedInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PtpWebcamAssistantDelegateProtocol)];
//	[exportedInterface setInterface: cameraInterface forSelector: @selector(cameraConnected:) argumentIndex: 0 ofReply: NO];
	
	assistantConnection.exportedObject = self;
	assistantConnection.exportedInterface = exportedInterface;
	
	[assistantConnection resume];
	
	// send message to get the service started by launchd
	[[assistantConnection remoteObjectProxy] pingService:^{
		PtpLog(@"pong received.");
	}];

}

- (void) cameraConnected: (id) cameraId withInfo: (NSDictionary*) cameraInfo
{
//	PtpLog(@"");
	
	// create and register stream and device
	
	PtpWebcamXpcDevice* device = [[PtpWebcamXpcDevice alloc] initWithCameraId: cameraId info: cameraInfo pluginInterface: self.pluginInterfaceRef];

	// checking and adding to self.devices must happen atomically, hence the @sync block
	@synchronized (self) {
		// do nothing if we already know of the camera
		if (self.devices[cameraId])
			return;
		
		// add to devices list
		NSMutableDictionary* devices = self.devices.mutableCopy;
		devices[device.cameraId] = device;
		self.devices = devices;
	}

	device.xpcConnection = assistantConnection;

	[device createCmioDeviceWithPluginId: self.objectId];
	[PtpWebcamObject registerObject: device];
	
	PtpWebcamXpcStream* stream = [[PtpWebcamXpcStream alloc] initWithPluginInterface: self.pluginInterfaceRef];
	stream.xpcDevice = device;
	[stream createCmioStreamWithDevice: device];
	[PtpWebcamObject registerObject: stream];

	// then publish stream and device
	[device publishCmioDevice];
	[stream publishCmioStream];
	

}

- (void)cameraDisconnected:(id)cameraId {
	
	PtpWebcamXpcDevice* device = nil;
	@synchronized (self) {
		// do nothing if we didn't know about the camera
		if (!(device = self.devices[cameraId]))
			return;
		
		// remove from devices list
		NSMutableDictionary* devices = self.devices.mutableCopy;
		[devices removeObjectForKey: device.cameraId];
		self.devices = devices;
	}
	
	[device unplugDevice];

}


- (void) liveViewReadyforCameraWithId:(id)cameraId
{
	PtpWebcamXpcDevice* device = self.devices[cameraId];
	PtpWebcamXpcStream* stream = (id)device.stream;
	[stream liveViewStreamReady];

}

- (void) receivedLiveViewJpegImageData:(NSData *)jpegData withInfo:(NSDictionary *)info forCameraWithId:(id)cameraId
{
	PtpWebcamXpcDevice* device = self.devices[cameraId];
	PtpWebcamXpcStream* stream = (id)device.stream;
	[stream receivedLiveViewJpegImageData: jpegData withInfo: info];
}


//- (void)propertyChanged:(NSDictionary *)property forCameraWithId:(id)cameraId {
//	<#code#>
//}


@end

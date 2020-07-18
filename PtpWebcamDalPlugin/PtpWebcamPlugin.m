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
#import "PtpWebcamDummyDevice.h"
#import "PtpWebcamDummyStream.h"

#import <ImageCaptureCore/ImageCaptureCore.h>

// define DUMMY_DEVICE_ENABLED to enable the dummy device to test that the DAL plugin can deliver images without a camera connection
//#define DUMMY_DEVICE_ENABLED=1

@interface PtpWebcamPlugin ()
{
	ICDeviceBrowser* deviceBrowser;
}
@end

@implementation PtpWebcamPlugin

- (instancetype) init
{
	if (!(self = [super init]))
		return nil;
	
	self.devices = [NSArray array];
	
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
	
	deviceBrowser = [[ICDeviceBrowser alloc] init];
	deviceBrowser.delegate = self;
	deviceBrowser.browsedDeviceTypeMask |= ICDeviceTypeMaskCamera | ICDeviceLocationTypeMaskLocal;
	
	[deviceBrowser start];
	
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
		self.devices = [self.devices arrayByAddingObject: device];
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
		self.devices = [self.devices arrayByAddingObject: device];
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

@end

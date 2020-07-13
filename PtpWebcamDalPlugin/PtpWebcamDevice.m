//
//  PtpWebcamDevice.m
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 30.05.2020.
//  Copyright © 2020 InRobCo. All rights reserved.
//

#import "PtpWebcamDevice.h"
#import "PtpWebcamStream.h"

#import <ImageCaptureCore/ImageCaptureCore.h>


@interface PtpWebcamDevice ()
{
}
@end

@implementation PtpWebcamDevice

- (void) createCmioDeviceWithPluginId: (CMIOObjectID) pluginId
{
	// create device as systemobject
		CMIOObjectID deviceId = 0;
		OSStatus createErr = CMIOObjectCreate(self.pluginInterfaceRef, kCMIOObjectSystemObject, kCMIODeviceClassID, &deviceId);
		if (createErr != kCMIOHardwareNoError)
		{
			NSLog(@"failed to create device with error %d", createErr);
			assert(0);
		}
		self.objectId = deviceId;
		self.pluginId = pluginId;
}

- (void) publishCmioDevice
{
	CMIOObjectID deviceId = self.objectId;
	OSStatus err = CMIOObjectsPublishedAndDied(self.pluginInterfaceRef, kCMIOObjectSystemObject, 1, &deviceId, 0, NULL);
	if (err != kCMIOHardwareNoError)
	{
		NSLog(@"failed to publish device with error %d", err);
		assert(0);
	}
	NSLog(@"published device %u", deviceId);
}

- (void) unpublishCmioDevice
{
	CMIOObjectID deviceId = self.objectId;
	OSStatus err = CMIOObjectsPublishedAndDied(self.pluginInterfaceRef, kCMIOObjectSystemObject, 0, NULL, 1, &deviceId);
	if (err != kCMIOHardwareNoError)
	{
		NSLog(@"failed to publish device with error %d", err);
		assert(0);
	}
	NSLog(@"published device %u", deviceId);

}

- (void) deleteCmioDevice
{
	[self unpublishCmioDevice];
}

- (uint32_t) numStreams
{
	return 1;
}

- (uint32_t) getPropertyDataSizeForAddress: (CMIOObjectPropertyAddress) address qualifierData: (NSData*) qualifierData
{
	switch(address.mSelector)
	{
		case kCMIOObjectPropertyName:
		case kCMIOObjectPropertyManufacturer:
		case kCMIOObjectPropertyElementCategoryName:
		case kCMIOObjectPropertyElementNumberName:
			return sizeof(CFStringRef);
//		case kCMIOObjectPropertyOwnedObjects:
//		{
//			// qualifierData contains classIds for which we return objectIds as data
//			//
//			uint32_t ownedObjects = 0;
//			for (size_t i = 0; i < qualifierData.length; ++i)
//			{
//				
//			}
//			return ownedObjects*sizeof(CMIOObjectID);
//		}
		case kCMIODevicePropertyPlugIn:
			return sizeof(CMIOObjectID);
		case kCMIODevicePropertyDeviceUID:
		case kCMIODevicePropertyModelUID:
			return sizeof(CFStringRef);
		case kCMIODevicePropertyTransportType:
		case kCMIODevicePropertyDeviceIsAlive:
		case kCMIODevicePropertyDeviceHasChanged:
		case kCMIODevicePropertyDeviceIsRunning:
		case kCMIODevicePropertyDeviceIsRunningSomewhere:
		case kCMIODevicePropertyDeviceCanBeDefaultDevice:
			return sizeof(uint32_t);
		case kCMIODevicePropertyHogMode:
		case kCMIODevicePropertyDeviceMaster:
			return sizeof(pid_t);
		case kCMIODevicePropertyLatency:
			return sizeof(uint32_t);
		case kCMIODevicePropertyStreams:
			if ([self respondsToSelector: @selector(numStreams)])
				return sizeof(CMIOStreamID)*[self numStreams];
			else
				return 0;
		case kCMIODevicePropertyStreamConfiguration:
			if ([self respondsToSelector: @selector(numStreams)])
				return sizeof(uint32_t)*(1+[self numStreams]);
			else
				return sizeof(uint32_t);
		case kCMIODevicePropertyExcludeNonDALAccess:
			return sizeof(uint32_t);
		case kCMIODevicePropertyCanProcessAVCCommand:
		case kCMIODevicePropertyCanProcessRS422Command:
			return sizeof(Boolean);
		case kCMIODevicePropertyLinkedCoreAudioDeviceUID:
			return sizeof(CFStringRef);
		default:
			return [super getPropertyDataSizeForAddress: address qualifierData: qualifierData];
	}
}

- (BOOL) hasPropertyWithAddress: (CMIOObjectPropertyAddress) address
{
	switch (address.mSelector)
	{
		case kCMIOObjectPropertyName:
			return self.name != nil;
		case kCMIOObjectPropertyManufacturer:
			return self.manufacturer != nil;
		case kCMIOObjectPropertyElementCategoryName:
			return self.elementCategoryName != nil;
		case kCMIOObjectPropertyElementNumberName:
			return self.elementNumberName != nil;
		case kCMIODevicePropertyLocation:
			return NO; // not supporting location data
		case kCMIODevicePropertyPlugIn:
			return YES;
		case kCMIODevicePropertyDeviceUID:
			return self.deviceUid != nil;
		case kCMIODevicePropertyModelUID:
			return self.modelUid != nil;
		case kCMIODevicePropertyTransportType:
		case kCMIODevicePropertyDeviceIsAlive:
		case kCMIODevicePropertyDeviceHasChanged:
		case kCMIODevicePropertyDeviceIsRunning:
		case kCMIODevicePropertyDeviceIsRunningSomewhere:
		case kCMIODevicePropertyDeviceCanBeDefaultDevice:
		case kCMIODevicePropertyHogMode:
		case kCMIODevicePropertyLatency:
		case kCMIODevicePropertyStreams:
		case kCMIODevicePropertyStreamConfiguration:
		case kCMIODevicePropertyExcludeNonDALAccess:
		case kCMIODevicePropertyDeviceMaster:
		case kCMIODevicePropertyCanProcessAVCCommand:
		case kCMIODevicePropertyCanProcessRS422Command:
			return YES;
		case kCMIODevicePropertyLinkedCoreAudioDeviceUID:
		case kCMIODevicePropertySuspendedByUser:
			return NO;
			
		default:
			return [super hasPropertyWithAddress: address];
	}
}

- (BOOL) isPropertySettable: (CMIOObjectPropertyAddress) address
{
	NSLog(@"device isPropertySettable: '%c%c%c%c'",
		  (address.mSelector >> 24) & 0xFF,
		  (address.mSelector >> 16) & 0xFF,
		  (address.mSelector >> 8) & 0xFF,
		  (address.mSelector >> 0) & 0xFF);

	switch (address.mSelector)
	{
		case kCMIOObjectPropertyName:
		case kCMIOObjectPropertyManufacturer:
		case kCMIOObjectPropertyElementCategoryName:
		case kCMIOObjectPropertyElementNumberName:
		case kCMIODevicePropertyPlugIn:
		case kCMIODevicePropertyDeviceUID:
		case kCMIODevicePropertyModelUID:
		case kCMIODevicePropertyTransportType:
		case kCMIODevicePropertyDeviceIsAlive:
		case kCMIODevicePropertyDeviceHasChanged:
		case kCMIODevicePropertyDeviceIsRunning:
		case kCMIODevicePropertyDeviceIsRunningSomewhere:
		case kCMIODevicePropertyDeviceCanBeDefaultDevice:
		case kCMIODevicePropertyHogMode:
		case kCMIODevicePropertyLatency:
		case kCMIODevicePropertyStreams:
		case kCMIODevicePropertyStreamConfiguration:
//		case kCMIODevicePropertyExcludeNonDALAccess:
		case kCMIODevicePropertyCanProcessAVCCommand:
		case kCMIODevicePropertyCanProcessRS422Command:
		case kCMIODevicePropertyLinkedCoreAudioDeviceUID:
			return NO;
		case kCMIODevicePropertyExcludeNonDALAccess:
		case kCMIODevicePropertyDeviceMaster:
			return YES;
		default:
			return [super isPropertySettable: address];
	}
}

- (NSData* __nullable) getPropertyDataForAddress: (CMIOObjectPropertyAddress) address qualifierData: (NSData*) qualifierData
{
	switch (address.mSelector)
	{
		case kCMIOObjectPropertyName:
		{
			CFStringRef stringRef = (__bridge_retained CFStringRef)self.name;
			return [NSData dataWithBytes: &stringRef length: sizeof(stringRef)];
		}
		case kCMIOObjectPropertyManufacturer:
		{
			CFStringRef stringRef = (__bridge_retained CFStringRef)self.manufacturer;
			return [NSData dataWithBytes: &stringRef length: sizeof(stringRef)];
		}
		case kCMIOObjectPropertyElementCategoryName:
		{
			CFStringRef stringRef = (__bridge_retained CFStringRef)self.elementCategoryName;
			return [NSData dataWithBytes: &stringRef length: sizeof(stringRef)];
		}
		case kCMIOObjectPropertyElementNumberName:
		{
			CFStringRef stringRef = (__bridge_retained CFStringRef)self.elementNumberName;
			return [NSData dataWithBytes: &stringRef length: sizeof(stringRef)];
		}
		case kCMIODevicePropertyPlugIn:
		{
			CMIOObjectID objectId = self.pluginId;
			return [NSData dataWithBytes: &objectId length: sizeof(objectId)];
		}
		case kCMIODevicePropertyDeviceUID:
		{
			CFStringRef stringRef = (__bridge_retained CFStringRef)self.deviceUid;
			return [NSData dataWithBytes: &stringRef length: sizeof(stringRef)];
		}
		case kCMIODevicePropertyModelUID:
		{
			CFStringRef stringRef = (__bridge_retained CFStringRef)self.modelUid;
			return [NSData dataWithBytes: &stringRef length: sizeof(stringRef)];
		}
		case kCMIODevicePropertyTransportType:
		{
			uint32_t transportType = self.transportType;
			return [NSData dataWithBytes: &transportType length: sizeof(transportType)];
		}
		case kCMIODevicePropertyDeviceIsAlive:
		{
//			uint32_t isAlive = self.isAlive;
			uint32_t isAlive = YES;
			return [NSData dataWithBytes: &isAlive length: sizeof(isAlive)];
		}
		case kCMIODevicePropertyDeviceHasChanged:
		{
//			uint32_t hasChanged = self.hasChanged;
			uint32_t hasChanged = NO;
			return [NSData dataWithBytes: &hasChanged length: sizeof(hasChanged)];
		}
		case kCMIODevicePropertyDeviceIsRunning:
		{
//			uint32_t isRunning = self.isRunning;
			uint32_t isRunning = YES;
			return [NSData dataWithBytes: &isRunning length: sizeof(isRunning)];
		}
		case kCMIODevicePropertyDeviceIsRunningSomewhere:
		{
//			uint32_t isRunning = self.isRunningSomewhere;
			uint32_t isRunning = YES;
			return [NSData dataWithBytes: &isRunning length: sizeof(isRunning)];
		}
		case kCMIODevicePropertyDeviceCanBeDefaultDevice:
		{
			// it's an input device, can be default
			uint32_t canBeDefault = YES;
			return [NSData dataWithBytes: &canBeDefault length: sizeof(canBeDefault)];
		}
		case kCMIODevicePropertyHogMode:
		{
			// never in hog mode, thus return -1
			pid_t pid = -1;
			return [NSData dataWithBytes: &pid length: sizeof(pid)];
		}
		case kCMIODevicePropertyExcludeNonDALAccess:
		{
			uint32_t val = self.excludeNonDalAccess;
			return [NSData dataWithBytes: &val length: sizeof(val)];
		}
		case kCMIODevicePropertyDeviceMaster:
		{
			pid_t pid = self.masterPid;
			return [NSData dataWithBytes: &pid length: sizeof(pid)];
		}
		case kCMIODevicePropertyLatency:
		{
//			uint32_t latency = self.latency;
			uint32_t latency = 0;
			return [NSData dataWithBytes: &latency length: sizeof(latency)];
		}
		case kCMIODevicePropertyStreams:
		{
			CMIOStreamID streamId = self.streamId;
			return [NSData dataWithBytes: &streamId length: sizeof(streamId)];
		}
		case kCMIODevicePropertyStreamConfiguration:
		case kCMIODevicePropertyCanProcessAVCCommand:
		case kCMIODevicePropertyCanProcessRS422Command:
		case kCMIODevicePropertyLinkedCoreAudioDeviceUID:
		default:
			return [super getPropertyDataForAddress: address qualifierData: qualifierData];
	}

}

- (OSStatus) setPropertyDataForAddress: (CMIOObjectPropertyAddress) address qualifierData: (NSData* __nullable) qualifierData data: (NSData*) data
{
	switch(address.mSelector)
	{
		case kCMIODevicePropertyExcludeNonDALAccess:
		{
			uint32_t aBool = 0;
			[data getBytes: &aBool length: sizeof(aBool)];
			self.excludeNonDalAccess = (aBool != 0);
			return kCMIOHardwareNoError;
		}
		case kCMIODevicePropertyDeviceMaster:
		{
			pid_t aPid = 0;
			[data getBytes: &aPid length: sizeof(aPid)];
			self.masterPid = aPid;
			return kCMIOHardwareNoError;
		}
		default:
			return [super setPropertyDataForAddress: address qualifierData: qualifierData data: data];
	}
}

- (OSStatus) startStream: (CMIOObjectID) streamId
{
	PtpWebcamStream* stream = [PtpWebcamObject objectWithId: streamId];
	if (!stream)
		return kCMIOHardwareBadObjectError;
	
	return [self.stream startStream];
}

- (OSStatus) stopStream: (CMIOObjectID) streamId
{
	PtpWebcamStream* stream = [PtpWebcamObject objectWithId: streamId];
	if (!stream)
		return kCMIOHardwareBadObjectError;
	
	return [self.stream stopStream];
}

- (void) unplugDevice
{
	[self doesNotRecognizeSelector: _cmd];
}
- (void) finalizeDevice
{
	[self doesNotRecognizeSelector: _cmd];
}
- (OSStatus) resume
{
	[self doesNotRecognizeSelector: _cmd];
	return kCMIOHardwareIllegalOperationError;
}
- (OSStatus) suspend
{
	[self doesNotRecognizeSelector: _cmd];
	return kCMIOHardwareIllegalOperationError;
}

@end

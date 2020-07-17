//
//  PtpWebcamStream.m
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 03.06.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamStream.h"
#import "PtpWebcamDevice.h"

#import <CoreMediaIO/CMIOSampleBuffer.h>

@interface PtpWebcamStream ()
{

}
@end

@implementation PtpWebcamStream

- (instancetype) initWithPluginInterface: (CMIOHardwarePlugInRef)pluginInterface
{
	if (!(self = [super initWithPluginInterface: pluginInterface]))
		return nil;
		
	{
		OSStatus err = CMSimpleQueueCreate(kCFAllocatorDefault,WEBCAM_STREAM_FPS, &cmQueue);
		if (err)
		{
			PtpWebcamShowCatastrophicAlert(@"-initWithPluginInterface: failed to allocate CMQueue with error %d.", err);
			return nil;
		}
	}

	{
		OSStatus err = CMIOStreamClockCreate(kCFAllocatorDefault, CFSTR("webcamPluginStreamClock"), (__bridge void*)self, CMTimeMake(1, WEBCAM_STREAM_FPS), WEBCAM_STREAM_BASE, 10, &streamClock);
		
		if (err)
		{
			PtpWebcamShowCatastrophicAlert(@"-initWithPluginInterface: failed to allocate CMIOClock with error %d.", err);
			return nil;
		}
	}

	return self;
}

- (void) dealloc
{
	CMIOStreamClockInvalidate(streamClock);
	CFRelease(streamClock);
	CFRelease(cmQueue);
}

- (void) createCmioStreamWithDevice: (PtpWebcamDevice*) device
{
	// create stream as child of device
	CMIOObjectID streamId = 0;
	OSStatus createErr = CMIOObjectCreate(self.pluginInterfaceRef, device.objectId, kCMIOStreamClassID, &streamId);
	if (createErr != kCMIOHardwareNoError)
	{
		PtpWebcamShowCatastrophicAlert(@"-createCmioStreamWithDevice: failed to create CMIOObject for stream with error %d.", createErr);
	}
	self.objectId = streamId;
	device.streamId = streamId;
	device.stream = self;
	self.pluginId = device.pluginId;
	self.deviceId = device.objectId;
	self.device = device;
}

- (void) publishCmioStream
{
	CMIOObjectID streamId = self.objectId;
//	OSStatus err = CMIOObjectsPublishedAndDied(&_pluginInterface, kCMIOObjectSystemObject, 1, &streamId, 0, NULL);
	OSStatus err = CMIOObjectsPublishedAndDied(self.pluginInterfaceRef, self.deviceId, 1, &streamId, 0, NULL);
	if (err != kCMIOHardwareNoError)
	{
		PtpWebcamShowCatastrophicAlert(@"-createCmioStreamWithDevice: failed to publish stream with error %d.", err);
		return;
	}
	NSLog(@"published stream %u", streamId);

}

- (void) unpublishCmioStream
{
	CMIOObjectID streamId = self.objectId;
//	OSStatus err = CMIOObjectsPublishedAndDied(&_pluginInterface, kCMIOObjectSystemObject, 1, &streamId, 0, NULL);
	OSStatus err = CMIOObjectsPublishedAndDied(self.pluginInterfaceRef, self.deviceId, 0, NULL, 1, &streamId);
	if (err != kCMIOHardwareNoError)
	{
		PtpWebcamShowCatastrophicAlert(@"-createCmioStreamWithDevice: failed to unpublish stream with error %d.", err);
		return;
	}
	NSLog(@"unpublished stream %u", streamId);

}

- (void) deleteCmioStream
{
	[self unpublishCmioStream];
}


- (OSStatus) startStream
{
	[self doesNotRecognizeSelector: _cmd];

	return kCMIOHardwareNoError;
}

- (OSStatus) stopStream
{
	[self doesNotRecognizeSelector: _cmd];

	return kCMIOHardwareNoError;
}

- (void) unplugDevice
{
	[self stopStream];
	[self deleteCmioStream];
}


- (BOOL) hasPropertyWithAddress: (CMIOObjectPropertyAddress) address
{
	switch (address.mSelector)
	{
		case kCMIOObjectPropertyName:
		case kCMIOObjectPropertyElementName:
		case kCMIOObjectPropertyListenerAdded:
		case kCMIOObjectPropertyListenerRemoved:
		case kCMIOStreamPropertyFormatDescriptions:
		case kCMIOStreamPropertyFormatDescription:
		case kCMIOStreamPropertyFrameRateRanges:
		case kCMIOStreamPropertyFrameRates:
		case kCMIOStreamPropertyFrameRate:
		case kCMIOStreamPropertyMinimumFrameRate:
		case kCMIOStreamPropertyDirection:
		case kCMIOStreamPropertyClock:
			return YES;
		default:
			return [super hasPropertyWithAddress: address];
	}
}

- (uint32_t) getPropertyDataSizeForAddress: (CMIOObjectPropertyAddress) address qualifierData: (NSData*) qualifierData
{
	switch(address.mSelector)
	{
		case kCMIOObjectPropertyName:
		case kCMIOObjectPropertyElementName:
			return sizeof(CFStringRef);
		case kCMIOStreamPropertyFormatDescriptions:
			return sizeof(CFArrayRef);
		case kCMIOStreamPropertyFormatDescription:
            return sizeof(CMFormatDescriptionRef);
		case kCMIOStreamPropertyFrameRateRanges:
			return sizeof(AudioValueRange);
		case kCMIOStreamPropertyFrameRates:
		case kCMIOStreamPropertyFrameRate:
		case kCMIOStreamPropertyMinimumFrameRate:
			return sizeof(Float64);
		case kCMIOStreamPropertyDirection:
			return sizeof(uint32_t);
		case kCMIOStreamPropertyClock:
            return sizeof(CFTypeRef);
		default:
			return [super getPropertyDataSizeForAddress: address qualifierData: qualifierData];
	}
}

- (NSData* __nullable) getPropertyDataForAddress: (CMIOObjectPropertyAddress) address qualifierData: (NSData*) qualifierData
{
	NSLog(@"stream getPropertyDataForAddress: '%@",
		  [PtpWebcamObject cmioPropertyIdToString: address.mSelector]);

	switch (address.mSelector)
	{
		case kCMIOObjectPropertyName:
		{
			CFStringRef stringRef = (__bridge_retained CFStringRef)self.name;
			return [NSData dataWithBytes: &stringRef length: sizeof(stringRef)];
		}
		case kCMIOObjectPropertyElementName:
		{
			CFStringRef stringRef = (__bridge_retained CFStringRef)self.elementName;
			return [NSData dataWithBytes: &stringRef length: sizeof(stringRef)];
		}
		case kCMIOStreamPropertyDirection:
		{
			uint32_t direction = 1;
			return [NSData dataWithBytes: &direction length: sizeof(direction)];
		}
		case kCMIOStreamPropertyFormatDescription:
		{
			NSLog(@"DUMMY returning kCMIOStreamPropertyFormatDescription");
			CMVideoFormatDescriptionRef formatRef = [self createFormatDescription];
			return [NSData dataWithBytes: &formatRef length: sizeof(formatRef)];
		}
		case kCMIOStreamPropertyFormatDescriptions:
		{
			NSLog(@"DUMMY returning kCMIOStreamPropertyFormatDescriptions");
			CMVideoFormatDescriptionRef formatRef = [self createFormatDescription];
			CFArrayRef arrayRef = (__bridge_retained CFArrayRef)@[(__bridge_transfer id)formatRef];
			return [NSData dataWithBytes: &arrayRef length: sizeof(arrayRef)];
		}
		case kCMIOStreamPropertyFrameRateRanges:
		{
			AudioValueRange range = {
				.mMinimum = WEBCAM_STREAM_FPS,
				.mMaximum = WEBCAM_STREAM_FPS,
			};
			return [NSData dataWithBytes: &range length: sizeof(range)];
		}
		case kCMIOStreamPropertyFrameRate:
		case kCMIOStreamPropertyFrameRates:
		case kCMIOStreamPropertyMinimumFrameRate:
		{
			Float64 rate = WEBCAM_STREAM_FPS;
			return [NSData dataWithBytes: &rate length: sizeof(rate)];
		}
		case kCMIOStreamPropertyClock:
		{
	
			if (!streamClock)
			{
				PtpWebcamShowCatastrophicAlertOnce(@"-getPropertyDataForAddress:qualifierData: stream clock invalid.");
				return nil;
			}
			CFTypeRef clock = CFRetain(streamClock);
			return [NSData dataWithBytes: &clock length: sizeof(clock)];
		}
		default:
		{
			return [super getPropertyDataForAddress: address qualifierData: qualifierData];
		}
	}
}

- (CMVideoFormatDescriptionRef) createFormatDescription
{
	CMVideoFormatDescriptionRef format = NULL;
//	CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_422YpCbCr8, 640, 480, NULL, &format);
	CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_JPEG, 640, 480, NULL, &format);
	return format;
}

- (BOOL) isPropertySettable: (CMIOObjectPropertyAddress) address
{
	return [super isPropertySettable: address];
}

- (OSStatus) setPropertyDataForAddress: (CMIOObjectPropertyAddress) address qualifierData: (NSData* __nullable) qualifierData data: (NSData*) data
{
	switch(address.mSelector)
	{
		default:
			return [super setPropertyDataForAddress: address qualifierData: qualifierData data: data];
	}
}

- (CMSimpleQueueRef) copyBufferQueueWithAlteredProc: (CMIODeviceStreamQueueAlteredProc) queueAlteredProc refCon: (void*) refCon
{
	alteredProc = queueAlteredProc;
	alteredRefCon = refCon;
	
	return (CMSimpleQueueRef)CFRetain(cmQueue);
}


@end

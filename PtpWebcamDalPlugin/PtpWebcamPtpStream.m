//
//  PtpWebcamPtpStream.m
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 06.06.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamPtpStream.h"
#import "PtpWebcamPtpDevice.h"
#import "PtpWebcamAlerts.h"
#import "PtpWebcamPtp.h"

#import <CoreMediaIO/CMIOSampleBuffer.h>

@interface PtpWebcamPtpStream ()
{
	dispatch_source_t frameTimerSource;
	dispatch_queue_t frameQueue;
	BOOL isStreaming;
	BOOL liveViewShouldBeEnabled; // indicate that live view should be running, so try to restart stream on error
}
@end

@implementation PtpWebcamPtpStream

- (instancetype) initWithPluginInterface: (_Nonnull CMIOHardwarePlugInRef) pluginInterface
{
	if (!(self = [super initWithPluginInterface: pluginInterface]))
		return nil;
		
	self.name = @"PTP Webcam Plugin Stream";
	self.elementName = @"PTP Webcam Plugin Stream Element";

	frameQueue = dispatch_queue_create("PtpWebcamStreamFrameQueue", DISPATCH_QUEUE_SERIAL);
		
	frameTimerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, frameQueue);
	dispatch_source_set_timer(frameTimerSource, DISPATCH_TIME_NOW, 1.0/WEBCAM_STREAM_FPS*NSEC_PER_SEC, 1u*NSEC_PER_MSEC);

	__weak id weakSelf = self;
	dispatch_source_set_event_handler(frameTimerSource, ^{
		[weakSelf asyncGetLiveViewImage];
	});
	
	return self;
}

- (void) dealloc
{
	if (frameTimerSource)
		dispatch_suspend(frameTimerSource);
}


- (void) asyncGetLiveViewImage
{
	[self.ptpDevice.camera requestLiveViewImage];
}


- (OSStatus) startStream
{
	if (!self.ptpDevice)
	{
		PtpWebcamShowCatastrophicAlert(@"-startStream failed because stream's PTP device is not set.");
		return kCMIOHardwareBadStreamError;
	}
	
	isStreaming = YES;

	BOOL liveStarted = [self.ptpDevice.camera startLiveView];
	
	if (!liveStarted)
	{
		isStreaming = NO;
		return kCMIOHardwareUnspecifiedError;
	}
	
	
	return kCMIOHardwareNoError;
}

- (void) cameraFailedToStartLiveView
{
	@synchronized (self) {
		liveViewShouldBeEnabled = NO;
		isStreaming = NO;
	}
}


- (void) cameraDidBecomeReadyForLiveViewStreaming
{
	@synchronized (self) {
		if (isStreaming && !liveViewShouldBeEnabled)
		{
			if (frameTimerSource)
				dispatch_resume(frameTimerSource);
			liveViewShouldBeEnabled = YES;
		}

	}
	
}

- (void) cameraLiveViewStreamDidBecomeInterrupted
{
	@synchronized (self) {
		if (liveViewShouldBeEnabled)
		{
			if (frameTimerSource)
				dispatch_suspend(frameTimerSource);
			liveViewShouldBeEnabled = NO;
		}

	}
	
}


- (OSStatus) stopStream
{
	// only suspend frame timer if it has been resumed when camera signalled ready, otherwise the suspend count is too high and it won't resume next time (eg. when the camera could not start live view because of an error condition)
	@synchronized (self) {
		if (frameTimerSource && liveViewShouldBeEnabled)
			dispatch_suspend(frameTimerSource);
		
		liveViewShouldBeEnabled = NO;
		isStreaming = NO;
	}

	[self.ptpDevice.camera stopLiveView];

	return kCMIOHardwareNoError;
}

- (void) restartStreamIfRunning
{
	if (isStreaming)
	{
		[self stopStream];
		[self startStream];
	}
}

- (void) receivedLiveViewJpegImageData: (NSData*) jpegData withInfo: (NSDictionary*) info
{
	uint64_t now = mach_absolute_time();

	// queue is full, don't add another image
	if (CMSimpleQueueGetFullness(self->cmQueue) >= 1.0)
		return;
	
#ifndef JPEG_OUTPUT
	NSImage* img = [[NSImage alloc] initWithData: jpegData];
	if (!img)
		return;
	CVPixelBufferRef pixels = [self createPixelBufferWithNSImage: img];
	if (!pixels)
		return;
#endif

	CMTimeScale scale = 600;
	CMSampleTimingInfo timingInfo = {
		.duration = CMTimeMake(1*scale, WEBCAM_STREAM_FPS*scale),
		.presentationTimeStamp = CMTimeMake(now*(1.0/NSEC_PER_SEC)*scale, scale),
		.decodeTimeStamp = kCMTimeInvalid,
	};
	
	OSStatus err = CMIOStreamClockPostTimingEvent(timingInfo.presentationTimeStamp, now, true, self->streamClock);
	
	if (err)
	{
		PtpWebcamShowCatastrophicAlertOnce(@"-parsePtpLiveViewImageResponse:data: failed to post stream clock timing event with error %d.", err);
	}

	
	self->sequenceNumber = CMIOGetNextSequenceNumber(self->sequenceNumber);

	CMSampleBufferRef buf = NULL;

#ifdef JPEG_OUTPUT
	CMFormatDescriptionRef format = [self createFormatDescription];
	CMBlockBufferRef pixels = NULL;
	CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nil, jpegData.length,  kCFAllocatorDefault, NULL, 0, jpegData.length, 0, &pixels);
	CMIOSampleBufferCreate(kCFAllocatorDefault,
						   pixels, format,
						   1, 1, &timingInfo, 0, NULL,
						   sequenceNumber, kCMIOSampleBufferNoDiscontinuities, &buf);
#else
	CMFormatDescriptionRef format = NULL;
	CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixels,  &format);
	CMIOSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixels, format, &timingInfo, self->sequenceNumber, kCMIOSampleBufferNoDiscontinuities, &buf);
#endif
	CFRelease(pixels);
	CFRelease(format);
	
	CMSimpleQueueEnqueue(self->cmQueue, buf);
	
	if (self->alteredProc)
	{
		self->alteredProc(self.objectId, buf, self->alteredRefCon);
	}
	
//	if (isStreaming)
//		[self asyncGetLiveViewImage];

}

- (NSData* __nullable) getPropertyDataForAddress: (CMIOObjectPropertyAddress) address qualifierData: (NSData*) qualifierData
{
//	NSLog(@"stream getPropertyDataForAddress: '%@",
//		  [PtpWebcamObject cmioPropertyIdToString: address.mSelector]);

	switch (address.mSelector)
	{
		case kCMIOStreamPropertyFormatDescriptions:
		{
			NSArray* formatDescriptions = [self createFormatDescriptions];
			CFArrayRef arrayRef = (__bridge_retained CFArrayRef)formatDescriptions;
			return [NSData dataWithBytes: &arrayRef length: sizeof(arrayRef)];
		}
		default:
		{
			return [super getPropertyDataForAddress: address qualifierData: qualifierData];
		}
	}
}

- (OSStatus) setPropertyDataForAddress: (CMIOObjectPropertyAddress) address qualifierData: (NSData* __nullable) qualifierData data: (NSData*) data
{
	switch(address.mSelector)
	{
		case kCMIOStreamPropertyFormatDescription:
		{
			CMVideoFormatDescriptionRef formatRef = nil;
			[data getBytes: &formatRef length: sizeof(formatRef)];
			CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatRef);
			NSNumber* imageSizeNumber = nil;

			if (dimensions.width == 320 && dimensions.height == 240)
			{
				imageSizeNumber = @(1);
			}
			else if (dimensions.width == 640 && dimensions.height == 480)
			{
				imageSizeNumber = @(2);
			}
			else if (dimensions.width == 1024 && dimensions.height == 768)
			{
				imageSizeNumber = @(2);
			}

			if (!imageSizeNumber)
				return kCMIOHardwareBadObjectError;
			
			[self.ptpDevice.camera ptpSetProperty: PTP_PROP_NIKON_LV_IMAGESIZE toValue: imageSizeNumber];
			return kCMIOHardwareNoError;
		}
		default:
			return [super setPropertyDataForAddress: address qualifierData: qualifierData data: data];
	}
}

- (BOOL) isPropertySettable: (CMIOObjectPropertyAddress) address
{
	switch (address.mSelector)
	{
		case kCMIOStreamPropertyFormatDescription:
			return self.ptpDevice.camera.liveViewImageSizes.count > 1;
		default:
			return [super isPropertySettable: address];
	}
}


- (NSArray*) createFormatDescriptions
{
	NSArray* liveViewSizes = self.ptpDevice.camera.liveViewImageSizes;
	NSMutableArray* formats = [NSMutableArray arrayWithCapacity: liveViewSizes.count];
	for (NSValue* imageSize in liveViewSizes)
	{
		CMVideoFormatDescriptionRef format = [self createFormatDescriptionWithSize: imageSize.sizeValue];
		[formats addObject: (__bridge_transfer id)format];
	}
	
	return formats;
}

- (CMVideoFormatDescriptionRef) createFormatDescriptionWithSize: (NSSize) size
{
	CMVideoFormatDescriptionRef format = NULL;
	CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_422YpCbCr8, size.width, size.height, NULL, &format);
	return format;
}

- (CMVideoFormatDescriptionRef) createFormatDescription
{
	CMVideoFormatDescriptionRef format = NULL;
	CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_422YpCbCr8, 640, 480, NULL, &format);
//	CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_JPEG, 640, 480, NULL, &format);
	return format;
}

@end

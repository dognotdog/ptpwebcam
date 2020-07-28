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
	dispatch_source_set_timer(frameTimerSource, DISPATCH_TIME_NOW, 1.0/WEBCAM_STREAM_FPS*NSEC_PER_SEC, 1000u*NSEC_PER_SEC);

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
	
	[self.ptpDevice.camera startLiveView];
	
	return kCMIOHardwareNoError;
}

- (void) cameraDidBecomeReadyForLiveViewStreaming
{
	if (frameTimerSource)
		dispatch_resume(frameTimerSource);
}

- (OSStatus) stopStream
{
	if (frameTimerSource)
		dispatch_suspend(frameTimerSource);
	
	liveViewShouldBeEnabled = NO;

	[self.ptpDevice.camera stopLiveView];

	isStreaming = NO;
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

- (nullable NSData*) extractNikonLiveViewJpegData: (NSData*) liveViewData
{
	// TODO: JPEG SOI marker might appear in other data, so just using that is not enough to reliably extract JPEG without knowing more
	// use JPEG SOI marker (0xFF 0xD8) to find image start
	const uint8_t soi[2] = {0xFF, 0xD8};
	const uint8_t* buf = liveViewData.bytes;
	
	const uint8_t* soiPtr = memmem(buf, liveViewData.length, soi, sizeof(soi));
	
	if (!soiPtr)
		return nil;
	
	size_t offs = soiPtr-buf;
	
	return [liveViewData subdataWithRange: NSMakeRange( offs, liveViewData.length - offs)];
	
}



- (CMVideoFormatDescriptionRef) createFormatDescription
{
	CMVideoFormatDescriptionRef format = NULL;
	CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_422YpCbCr8, 640, 480, NULL, &format);
//	CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_JPEG, 640, 480, NULL, &format);
	return format;
}

@end

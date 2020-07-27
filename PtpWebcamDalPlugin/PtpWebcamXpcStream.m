//
//  PtpWebcamXpcStream.m
//  PTPWebcamDALPlugin
//
//  Created by Dömötör Gulyás on 26.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamXpcStream.h"
#import "PtpWebcamXpcDevice.h"
#import "PtpWebcamAssistantServiceProtocol.h"
#import "PtpWebcamAlerts.h"

#import <CoreMediaIO/CMIOSampleBuffer.h>

@interface PtpWebcamXpcStream ()
{
	dispatch_source_t frameTimerSource;
	dispatch_queue_t frameQueue;
	BOOL isStreaming;
}
@end

@implementation PtpWebcamXpcStream

- (instancetype) initWithPluginInterface: (_Nonnull CMIOHardwarePlugInRef) pluginInterface
{
	if (!(self = [super initWithPluginInterface: pluginInterface]))
		return nil;
		
	self.name = @"PTP Webcam Plugin Stream";
	self.elementName = @"PTP Webcam Plugin Stream Element";

	dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
	frameQueue = dispatch_queue_create("PtpWebcamStreamFrameQueue", queueAttributes);

	frameTimerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, frameQueue);
	dispatch_source_set_timer(frameTimerSource, DISPATCH_TIME_NOW, 1.0/WEBCAM_STREAM_FPS*NSEC_PER_SEC, 1000u*NSEC_PER_SEC);

	__weak id weakSelf = self;
	dispatch_source_set_event_handler(frameTimerSource, ^{
		[weakSelf asyncGetLiveViewImage];
	});
	
	return self;
}

- (OSStatus) startStream
{
	[[self.xpcDevice.xpcConnection remoteObjectProxy] startLiveViewForCamera: self.xpcDevice.cameraId];
	
	isStreaming = YES;
	
	
	return kCMIOHardwareNoError;
}

- (void) liveViewStreamReady
{
	if (frameTimerSource)
		dispatch_resume(frameTimerSource);
	
//	[self asyncGetLiveViewImage];

}

- (OSStatus) stopStream
{
	if (frameTimerSource)
		dispatch_suspend(frameTimerSource);

	isStreaming = NO;

	[[self.xpcDevice.xpcConnection remoteObjectProxy] stopLiveViewForCamera: self.xpcDevice.cameraId];

	return kCMIOHardwareNoError;
}

- (void) asyncGetLiveViewImage
{
	[[self.xpcDevice.xpcConnection remoteObjectProxy] requestLiveViewImageForCamera: self.xpcDevice.cameraId];
}

- (void) receivedLiveViewJpegImageData: (NSData*) jpegData withInfo: (NSDictionary*) info
{
	uint64_t now = mach_absolute_time();

	// queue is full, don't add another image
	if (CMSimpleQueueGetFullness(self->cmQueue) >= 1.0)
		return;
	
	NSImage* img = [[NSImage alloc] initWithData: jpegData];
	if (!img)
		return;
	CVPixelBufferRef pixels = [self createPixelBufferWithNSImage: img];
	if (!pixels)
		return;

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

	CMFormatDescriptionRef format = NULL;
	CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixels,  &format);
	CMIOSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixels, format, &timingInfo, self->sequenceNumber, kCMIOSampleBufferNoDiscontinuities, &buf);

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

- (CMVideoFormatDescriptionRef) createFormatDescription
{
	CMVideoFormatDescriptionRef format = NULL;
	CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_422YpCbCr8, 640, 480, NULL, &format);
//	CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_JPEG, 640, 480, NULL, &format);
	return format;
}



- (CVPixelBufferRef) createPixelBufferWithNSImage:(NSImage*)image
{
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    NSDictionary* pixelBufferProperties = @{(id)kCVPixelBufferCGImageCompatibilityKey:@YES, (id)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES};
    CVPixelBufferRef pixelBuffer = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, [image size].width, [image size].height, k32ARGBPixelFormat, (__bridge CFDictionaryRef)pixelBufferProperties, &pixelBuffer);
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void* baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    CGContextRef context = CGBitmapContextCreate(baseAddress, [image size].width, [image size].height, 8, bytesPerRow, colorSpace, kCGImageAlphaNoneSkipFirst);
    NSGraphicsContext* imageContext = [NSGraphicsContext graphicsContextWithCGContext:context flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:imageContext];
    [image compositeToPoint:NSMakePoint(0.0, 0.0) operation:NSCompositingOperationCopy];
    [NSGraphicsContext restoreGraphicsState];
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    CFRelease(context);
    CGColorSpaceRelease(colorSpace);
    return pixelBuffer;
}

@end

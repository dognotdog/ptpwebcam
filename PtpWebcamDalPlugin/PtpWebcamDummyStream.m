//
//  PtpWebcamDummyStream.m
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 06.06.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamDummyStream.h"

#import <CoreMediaIO/CMIOSampleBuffer.h>

@interface PtpWebcamDummyStream ()
{
	dispatch_source_t frameTimerSource;
	dispatch_queue_t frameQueue;
	
	uint64_t firstFrameMachTime;
	
}
@end


@implementation PtpWebcamDummyStream

- (instancetype) init
{
	if (!(self = [super init]))
		return nil;
		
	self.name = @"Dummy Webcam Plugin Stream";
	self.elementName = @"Dummy Webcam Plugin Stream Element";

	frameQueue = dispatch_queue_create("PtpWebcamDummyStreamFrameQueue", DISPATCH_QUEUE_SERIAL);
		
	frameTimerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, frameQueue);
	dispatch_source_set_timer(frameTimerSource, DISPATCH_TIME_NOW, 1.0/60.0*NSEC_PER_SEC, 1u*NSEC_PER_MSEC);

	__weak id weakSelf = self;
	dispatch_source_set_event_handler(frameTimerSource, ^{
		[weakSelf getFrame];
	});
	
	return self;
}

- (void) dealloc
{
	dispatch_suspend(frameTimerSource);
}

- (OSStatus) startStream
{
	dispatch_resume(frameTimerSource);

	return kCMIOHardwareNoError;
}

- (OSStatus) stopStream
{
	dispatch_suspend(frameTimerSource);

	return kCMIOHardwareNoError;
}

- (CVPixelBufferRef)createPixelBufferWithTestAnimation {
    int width = 1280;
    int height = 720;

    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
                             [NSNumber numberWithBool:YES], kCVPixelBufferCGImageCompatibilityKey,
                             [NSNumber numberWithBool:YES], kCVPixelBufferCGBitmapContextCompatibilityKey, nil];
    CVPixelBufferRef pxbuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, (__bridge CFDictionaryRef) options, &pxbuffer);
#pragma unused(status)
	
    NSParameterAssert(status == kCVReturnSuccess && pxbuffer != NULL);

    CVPixelBufferLockBaseAddress(pxbuffer, 0);
    void *pxdata = CVPixelBufferGetBaseAddress(pxbuffer);
    NSParameterAssert(pxdata != NULL);

    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pxdata, width, height, 8, CVPixelBufferGetBytesPerRow(pxbuffer), rgbColorSpace, kCGImageAlphaPremultipliedFirst | kCGImageByteOrder32Big);
    NSParameterAssert(context);

    double time = ((double)mach_absolute_time()) / NSEC_PER_SEC;
    CGFloat pos = time - floor(time);

    CGColorRef whiteColor = CGColorCreateGenericRGB(1, 1, 1, 1);
    CGColorRef redColor = CGColorCreateGenericRGB(1, 0, 0, 1);

    CGContextSetFillColorWithColor(context, whiteColor);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));

    CGContextSetFillColorWithColor(context, redColor);
    CGContextFillRect(context, CGRectMake(pos * width, 310, 100, 100));

    CGColorRelease(whiteColor);
    CGColorRelease(redColor);

    CGColorSpaceRelease(rgbColorSpace);
    CGContextRelease(context);

    CVPixelBufferUnlockBaseAddress(pxbuffer, 0);

    return pxbuffer;
}

- (void) getFrame
{
    if (CMSimpleQueueGetFullness(self->cmQueue) >= 1.0) {
        NSLog(@"Queue is full, bailing out");
        return;
    }
	
    CVPixelBufferRef pixelBuffer = [self createPixelBufferWithTestAnimation];

	// initialize frame timing with absolute time
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		firstFrameMachTime = mach_absolute_time();
	});

	
    CMTimeScale scale = WEBCAM_STREAM_FPS * WEBCAM_STREAM_BASE;
    CMTime firstFrameTime = CMTimeMake((firstFrameMachTime / (CFTimeInterval)NSEC_PER_SEC) * scale, scale);
    CMTime frameDuration = CMTimeMake(scale / WEBCAM_STREAM_FPS, scale);
    CMTime framesSinceBeginning = CMTimeMake(frameDuration.value * self->sequenceNumber, scale);
    CMTime presentationTime = CMTimeAdd(firstFrameTime, framesSinceBeginning);

    CMSampleTimingInfo timing;
    timing.duration = frameDuration;
    timing.presentationTimeStamp = presentationTime;
    timing.decodeTimeStamp = presentationTime;
    OSStatus err = CMIOStreamClockPostTimingEvent(presentationTime, mach_absolute_time(), true, self->streamClock);
    if (err != noErr) {
        NSLog(@"CMIOStreamClockPostTimingEvent err %d", err);
    }

    CMFormatDescriptionRef format;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format);

    self->sequenceNumber = CMIOGetNextSequenceNumber(self->sequenceNumber);

    CMSampleBufferRef buffer;
    err = CMIOSampleBufferCreateForImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        format,
        &timing,
        self->sequenceNumber,
        kCMIOSampleBufferNoDiscontinuities,
        &buffer
    );
    CFRelease(pixelBuffer);
    CFRelease(format);
    if (err != noErr) {
        NSLog(@"CMIOSampleBufferCreateForImageBuffer err %d", err);
    }

    CMSimpleQueueEnqueue(self->cmQueue, buffer);

    // Inform the clients that the queue has been altered
    if (self->alteredProc)
	{
        (self->alteredProc)(self.objectId, buffer, self->alteredRefCon);
    }

	
}

- (CMVideoFormatDescriptionRef) createFormatDescription
{
	CMVideoFormatDescriptionRef format = NULL;
	CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_422YpCbCr8, 1280, 720, NULL, &format);
	return format;
}

@end

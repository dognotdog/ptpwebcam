//
//  PtpWebcamPtpStream.m
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 06.06.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamPtpStream.h"
#import "PtpWebcamPtpDevice.h"

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
		
	self.name = @"D800 Webcam Plugin Stream";
	self.elementName = @"D800 Webcam Plugin Stream Element";

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
	[self.ptpDevice.cameraDevice requestSendPTPCommand: [self.ptpDevice ptpCommandWithType: PTP_TYPE_COMMAND code: PTP_CMD_GETLIVEVIEWIMG transactionId: [self.ptpDevice nextTransactionId]]
								outData: nil
					sendCommandDelegate: self
				 didSendCommandSelector: @selector(didSendPTPCommand:inData:response:error:contextInfo:)
							contextInfo: NULL];
	
}

- (OSStatus) startStream
{
	if (!self.ptpDevice)
	{
		PtpWebcamShowCatastrophicAlert(@"-startStream failed because stream's PTP device is not set.");
		return kCMIOHardwareBadStreamError;
	}
	
	
	[self.ptpDevice.cameraDevice requestSendPTPCommand: [self.ptpDevice ptpCommandWithType: PTP_TYPE_COMMAND code: PTP_CMD_STARTLIVEVIEW transactionId: [self.ptpDevice nextTransactionId]]
						  outData: nil
			  sendCommandDelegate: self
		   didSendCommandSelector: @selector(didSendPTPCommand:inData:response:error:contextInfo:)
					  contextInfo: NULL];

	dispatch_resume(frameTimerSource);
	
	isStreaming = YES;
	
	// refresh device properties after live view is on, having given the camera little time to switch
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
		self->liveViewShouldBeEnabled = YES;
		[self.ptpDevice ptpQueryKnownDeviceProperties];
	});

	return kCMIOHardwareNoError;
}

- (OSStatus) stopStream
{
	if (frameTimerSource)
		dispatch_suspend(frameTimerSource);
	
	liveViewShouldBeEnabled = NO;

	[self.ptpDevice.cameraDevice requestSendPTPCommand: [self.ptpDevice ptpCommandWithType: PTP_TYPE_COMMAND code: PTP_CMD_STOPLIVEVIEW transactionId: [self.ptpDevice nextTransactionId]]
						  outData: nil
			  sendCommandDelegate: self
		   didSendCommandSelector: @selector(didSendPTPCommand:inData:response:error:contextInfo:)
					  contextInfo: NULL];
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

- (void)didSendPTPCommand:(NSData*)command inData:(NSData*)data response:(NSData*)response error:(NSError*)error contextInfo:(void*)contextInfo
{
	if (error)
		NSLog(@"didSendPTPCommand error=%@", error);
	
	uint16_t cmd = 0;
	[command getBytes: &cmd range: NSMakeRange(6, 2)];
	
	switch (cmd)
	{
		case PTP_CMD_GETLIVEVIEWIMG:
			[self parsePtpLiveViewImageResponse: response data: data];
			break;
		default:
			NSLog(@"didSendPTPCommand  cmd=%@", command);
			NSLog(@"didSendPTPCommand data=%@", data);
			break;
	}
	
}

- (void) parsePtpLiveViewImageResponse: (NSData*) response data: (NSData*) data
{
	// response structure
	// 32bit length
	// 16bit 0x0003 type = response
	// 16bit response code
	// 32bit transaction id
	// 32bit response parameter
	
	
    uint64_t now = mach_absolute_time();
	
	uint32_t len = 0;
	[response getBytes: &len range: NSMakeRange(0, 4)];
	uint16_t type = 0;
	[response getBytes: &type range: NSMakeRange(4, 2)];
	uint16_t code = 0;
	[response getBytes: &code range: NSMakeRange(6, 2)];
	uint32_t transId = 0;
	[response getBytes: &transId range: NSMakeRange(8, 4)];

	bool isDeviceBusy = code == PTP_RSP_DEVICEBUSY;
	
	if (!data) // no data means no image to present
	{
		NSLog(@"parsePtpLiveViewImageResponse: no data!");
		
		// restart live view if it got turned off after timeout or error
		// device busy does not restart, as it does not indicate a permanent error condition that necessitates cycling.
		if (liveViewShouldBeEnabled && !isDeviceBusy)
		{
			[self stopStream];
			[self startStream];
		}
		
		return;
	}
	
	
	switch (code)
	{
		case PTP_RSP_NIKON_NOTLIVEVIEW:
		{
			NSLog(@"camera not in liveview, no image.");
			//			[self asyncGetLiveViewImage];
			return;
		}
		case PTP_RSP_OK:
		{
			// OK means proceed with image
			break;
		}
		default:
		{
			NSLog(@"len = %u type = 0x%X, code = 0x%X, transId = %u", len, type, code, transId);
			break;
		}
			
	}
	
	
	// D800 LiveView image has a heaer of length 384 with metadata, with the rest being the JPEG image.
	size_t headerLen = self.ptpDevice.liveViewHeaderLength;
	NSData* jpegData = [data subdataWithRange:NSMakeRange( headerLen, data.length - headerLen)];
	
	
	// queue is full, don't add another image
	if (CMSimpleQueueGetFullness(cmQueue) >= 1.0)
		return;
	
#ifndef JPEG_OUTPUT
	NSImage* img = [[NSImage alloc] initWithData: jpegData];
	CVPixelBufferRef pixels = [self createPixelBufferWithNSImage: img];
#endif
	
	CMTimeScale scale = 600;
	CMSampleTimingInfo timingInfo = {
		.duration = CMTimeMake(1*scale, WEBCAM_STREAM_FPS*scale),
		.presentationTimeStamp = CMTimeMake(now*(1.0/NSEC_PER_SEC)*scale, scale),
		.decodeTimeStamp = kCMTimeInvalid,
	};
	
	OSStatus err = CMIOStreamClockPostTimingEvent(timingInfo.presentationTimeStamp, now, true, streamClock);
	
	if (err)
	{
		PtpWebcamShowCatastrophicAlertOnce(@"-parsePtpLiveViewImageResponse:data: failed to post stream clock timing event with error %d.", err);
	}

	
	sequenceNumber = CMIOGetNextSequenceNumber(sequenceNumber);

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
	CMIOSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixels, format, &timingInfo, sequenceNumber, kCMIOSampleBufferNoDiscontinuities, &buf);
#endif

	

	CFRelease(pixels);
	CFRelease(format);
	
	CMSimpleQueueEnqueue(cmQueue, buf);
	
	if (alteredProc)
	{
		alteredProc(self.objectId, buf, alteredRefCon);
	}
	
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

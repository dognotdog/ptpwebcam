//
//  PtpWebcamStream.h
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 03.06.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <CoreMediaIO/CMIOHardwarePlugIn.h>

#import "PtpWebcamObject.h"

#define WEBCAM_STREAM_FPS	(30.0)
#define WEBCAM_STREAM_BASE	(100)

NS_ASSUME_NONNULL_BEGIN

@class PtpWebcamDevice;

@interface PtpWebcamStream : PtpWebcamObject
{
	uint64_t sequenceNumber;
	CFTypeRef streamClock;
	CMSimpleQueueRef cmQueue;
	CMIODeviceStreamQueueAlteredProc alteredProc;
	void* alteredRefCon;

}

@property CMIOObjectID pluginId;
@property CMIOObjectID deviceId;
@property NSString* name;
@property NSString* elementName;

@property(weak) PtpWebcamDevice* device;

- (void) createCmioStreamWithDevice: (PtpWebcamDevice*) device;
- (void) publishCmioStream;
- (void) deleteCmioStream;

- (CMSimpleQueueRef) copyBufferQueueWithAlteredProc: (CMIODeviceStreamQueueAlteredProc) queueAlteredProc refCon: (void*) refCon;

- (CMVideoFormatDescriptionRef) createFormatDescription;
- (CVPixelBufferRef) createPixelBufferWithNSImage: (NSImage*) image;

- (void) unplugDevice;

- (OSStatus) startStream;
- (OSStatus) stopStream;
//- (void) restartStreamIfRunning;


@end

NS_ASSUME_NONNULL_END

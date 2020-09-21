//
//  PtpWebcamDevice.h
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 30.05.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "PtpWebcamPlugin.h"

#import <CoreMediaIO/CMIOHardwarePlugIn.h>

NS_ASSUME_NONNULL_BEGIN

@class ICCameraDevice, PtpWebcamStream;

@interface PtpWebcamDevice : PtpWebcamObject

//@property CMIOObjectID objectId;
@property CMIOObjectID pluginId;
@property CMIOObjectID streamId;

@property NSString* name;
@property NSString* manufacturer;
@property NSString* elementCategoryName;
@property NSString* elementNumberName;
@property NSString* deviceUid;
@property NSString* modelUid;

@property uint32_t transportType;
@property uint32_t latency;
@property pid_t masterPid;
@property BOOL isAlive;
@property BOOL hasChanged;
@property BOOL isRunning;
@property BOOL isRunningSomewhere;
@property BOOL excludeNonDalAccess;

@property PtpWebcamStream* stream;

- (void) createCmioDeviceWithPluginId: (CMIOObjectID) pluginId;
- (void) publishCmioDevice;
- (void) unpublishCmioDevice;

- (void) deleteCmioDevice;

- (void) unplugDevice;
- (void) finalizeDevice;

- (OSStatus) startStream: (CMIOObjectID) streamId;
- (OSStatus) stopStream: (CMIOObjectID) streamId;
- (OSStatus) suspend;
- (OSStatus) resume;

@end

NS_ASSUME_NONNULL_END

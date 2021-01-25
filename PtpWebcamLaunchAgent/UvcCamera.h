//
//  UvcCamera.h
//  PtpWebcamLaunchAgent
//
//  Created by Dömötör Gulyás on 24.01.2021.
//  Copyright © 2021 InRobCo. All rights reserved.
//

#import <Foundation/Foundation.h>

@class AVCaptureDevice;

NS_ASSUME_NONNULL_BEGIN

@class UvcCamera;

@protocol UvcCameraDelegate <NSObject>

- (void) cameraRemoved: (UvcCamera*) camera;

@end

@interface UvcCamera : NSObject

+ (NSDictionary<id, NSString*>*) settingsNames;
+ (NSDictionary<id, NSDictionary*>*) settingsValueNames;


- (instancetype) initWithCaptureDevice: (AVCaptureDevice*) device;

- (BOOL) setCurrentValue: (NSNumber*) value forSetting: (id) setting;
- (void) readSettingInfo: (id) setting;
- (nullable NSNumber*) rawValueForSetting: (id) setting fromData: (NSData*) data;

@property AVCaptureDevice* device;

@property NSMutableDictionary* supportedSettings;
@property NSMutableDictionary* settingsInfos;
@property uint32_t locationId;

@property(weak, nullable) id<UvcCameraDelegate> delegate;

@end

NS_ASSUME_NONNULL_END

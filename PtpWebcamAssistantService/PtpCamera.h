//
//  PtpCamera.h
//  PtpWebcamAssistantService
//
//  Created by Dömötör Gulyás on 25.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <ImageCaptureCore/ImageCaptureCore.h>

NS_ASSUME_NONNULL_BEGIN

@class PtpWebcamAssistantService;

@interface PtpCamera : NSObject <ICCameraDeviceDelegate, NSPortDelegate>

@property PtpWebcamAssistantService* service;
@property ICCameraDevice* icCamera;
@property id cameraId;

@property NSString* make;
@property NSString* model;

@property NSDictionary* ptpDeviceInfo;
@property NSDictionary* ptpPropertyInfos;

@property size_t liveViewHeaderLength;

- (uint32_t) nextTransactionId;

- (instancetype) initWithIcCamera: (ICCameraDevice*) camera service: (PtpWebcamAssistantService*) service;

+ (nullable NSDictionary*) isDeviceSupported: (ICDevice*) device;

- (void) startLiveView;
- (void) stopLiveView;
- (void) requestLiveViewImage;

@end

NS_ASSUME_NONNULL_END

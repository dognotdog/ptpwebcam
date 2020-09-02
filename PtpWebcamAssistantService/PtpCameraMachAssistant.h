//
//  PtpCameraMachAssistant.h
//  PtpWebcamAssistantService
//
//  Created by Dömötör Gulyás on 27.07.2020.
//  Copyright © 2020 InRobCo. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "PtpCamera.h"

NS_ASSUME_NONNULL_BEGIN

@protocol PtpWebcamMachAssistantDaemonProtocol <NSObject>

- (void) cameraReady: (PtpCamera*) camera;
//- (void) camera: (PtpCamera*) camera propertyChanged: (NSDictionary*) propertyInfo;
- (void) camera: (PtpCamera*) camera didReceiveLiveViewJpegImage: (NSData*) jpegData withInfo: (NSDictionary*) info;
- (void) cameraLiveViewReady: (PtpCamera*) camera;

@end

@class PtpWebcamAssistantService;

@interface PtpCameraMachAssistant : NSObject <PtpCameraDelegate, NSPortDelegate>

@property PtpCamera* camera;
@property id <PtpWebcamMachAssistantDaemonProtocol> service;

@end

NS_ASSUME_NONNULL_END

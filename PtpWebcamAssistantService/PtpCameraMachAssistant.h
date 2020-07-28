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

@class PtpWebcamAssistantService;

@interface PtpCameraMachAssistant : NSObject <PtpCameraDelegate, NSPortDelegate>

@property PtpCamera* camera;
@property PtpWebcamAssistantService* service;

@end

NS_ASSUME_NONNULL_END

//
//  PtpCameraSettingsController.h
//  PTP Webcam
//
//  Created by Dömötör Gulyás on 02.09.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "PtpCamera.h"

NS_ASSUME_NONNULL_BEGIN

@interface PtpCameraSettingsController : NSObject <PtpCameraLiveViewDelegate>

@property PtpCamera* camera;
@property NSString* name;
@property int streamCounter;

- (instancetype) initWithCamera: (PtpCamera*) camera;

- (void) removeStatusItem;

@end

NS_ASSUME_NONNULL_END

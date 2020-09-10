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

@class PtpWebcamStreamView;

@interface PtpCameraSettingsController : NSObject <PtpCameraLiveViewDelegate, NSWindowDelegate>

@property PtpCamera* camera;
@property NSString* name;
@property int streamCounter;

@property(nullable) NSWindow* streamPreviewWindow;
@property(nullable) PtpWebcamStreamView* streamView;

- (instancetype) initWithCamera: (PtpCamera*) camera;

- (void) removeStatusItem;

- (BOOL) incrementStreamCount;
- (void) decrementStreamCount;


@end

NS_ASSUME_NONNULL_END

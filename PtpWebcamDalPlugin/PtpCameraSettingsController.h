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

@protocol PtpCameraSettingsControllerDelegate <NSObject>

- (void) showCameraStatusItem: (NSMenuItem*) menuItem;
- (void) removeCameraStatusItem: (NSMenuItem*) menuItem;

@end

@interface PtpCameraSettingsController : NSObject <PtpCameraLiveViewDelegate, NSWindowDelegate>

@property PtpCamera* camera;
@property NSString* name;
@property int streamCounter;

@property(nullable) NSWindow* streamPreviewWindow;
@property(nullable) PtpWebcamStreamView* streamView;

@property(nullable) id <PtpCameraSettingsControllerDelegate> delegate;

- (instancetype) initWithCamera: (PtpCamera*) camera delegate: (nullable id <PtpCameraSettingsControllerDelegate>) delegate;

- (void) removeStatusItem;

- (BOOL) incrementStreamCount;
- (void) decrementStreamCount;


@end

NS_ASSUME_NONNULL_END

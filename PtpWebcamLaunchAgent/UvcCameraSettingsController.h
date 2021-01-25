//
//  UvcCameraSettingsController.h
//  PtpWebcamLaunchAgent
//
//  Created by Dömötör Gulyás on 24.01.2021.
//  Copyright © 2021 InRobCo. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "UvcCamera.h"

NS_ASSUME_NONNULL_BEGIN

@class UvcCamera;
@class NSMenuItem;

@protocol UvcCameraSettingsControllerDelegate <NSObject>

- (void) showCameraStatusItem: (NSMenuItem*) menuItem;
- (void) removeCameraStatusItem: (NSMenuItem*) menuItem;

@end

@interface UvcCameraSettingsController : NSObject <UvcCameraDelegate>

- (instancetype) initWithCamera: (UvcCamera*) camera delegate: (nullable id <UvcCameraSettingsControllerDelegate>) delegate;

@property UvcCamera* camera;
@property(nullable) id <UvcCameraSettingsControllerDelegate> delegate;

- (void) removeStatusItem;

@end

NS_ASSUME_NONNULL_END

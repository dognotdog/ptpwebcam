//
//  PtpWebcamPtpDevice.h
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 06.06.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamDevice.h"

#import "PtpWebcamPlugin.h"

#import <CoreMediaIo/CMIOHardwarePlugIn.h>
#import "PtpCamera.h"


NS_ASSUME_NONNULL_BEGIN


@interface PtpWebcamPtpDevice : PtpWebcamDevice <PtpCameraLiveViewDelegate>

@property PtpCamera* camera;

- (instancetype) initWithCamera: (PtpCamera*) camera pluginInterface: (_Nonnull CMIOHardwarePlugInRef) pluginInterface;

@end

NS_ASSUME_NONNULL_END

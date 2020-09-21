//
//  PtpWebcamXpcDevice.h
//  PTPWebcamDALPlugin
//
//  Created by Dömötör Gulyás on 26.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamDevice.h"

#import <CoreMediaIO/CMIOHardwarePlugIn.h>

NS_ASSUME_NONNULL_BEGIN

@interface PtpWebcamXpcDevice : PtpWebcamDevice

@property NSXPCConnection* xpcConnection;
@property id cameraId;

- (instancetype) initWithCameraId: (id) cameraId info: (NSDictionary*) cameraInfo pluginInterface: (CMIOHardwarePlugInRef _Nonnull )pluginInterface;

@end

NS_ASSUME_NONNULL_END

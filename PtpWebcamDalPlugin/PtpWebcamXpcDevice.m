//
//  PtpWebcamXpcDevice.m
//  PTPWebcamDALPlugin
//
//  Created by Dömötör Gulyás on 26.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamXpcDevice.h"
#import "PtpWebcamXpcStream.h"

@implementation PtpWebcamXpcDevice

- (instancetype) initWithCameraId:(id)cameraId info:(NSDictionary *)cameraInfo pluginInterface:(CMIOHardwarePlugInRef)pluginInterface
{
	if (!(self = [super initWithPluginInterface: pluginInterface]))
		return nil;
	
	self.cameraId = cameraId;
	self.manufacturer = cameraInfo[@"make"];
	self.name = cameraInfo[@"model"];
	self.deviceUid = cameraId;
	self.modelUid = [NSString stringWithFormat: @"ptp-webcam-plugin-model-%@-%@", self.manufacturer, self.name];
	
	return self;
}

- (void) unplugDevice
{
	
	[self.stream unplugDevice];

	[self deleteCmioDevice];
	
}

@end

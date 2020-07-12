//
//  PTPWebcamDummyDevice.m
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 06.06.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamDummyDevice.h"

@implementation PtpWebcamDummyDevice

- (instancetype) init
{
	if (!(self = [super init]))
		return nil;
	
	self.name = @"Dummy Webcam Device";
	self.manufacturer = @"Dummy";
	self.elementNumberName = @"1";
	self.elementCategoryName = @"Dummy Webcam";
	self.deviceUid = @"dummy-webcam-plugin-device";
	self.modelUid = @"dummy-webcam-plugin-model";

	return self;
}

@end

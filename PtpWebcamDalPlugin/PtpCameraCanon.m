//
//  PtpCameraCanon.m
//  PTP Webcam
//
//  Created by Dömötör Gulyás on 29.07.2020.
//  Copyright © 2020 Doemeotoer Gulyas. All rights reserved.
//

#import "PtpCameraCanon.h"
#import "PtpWebcamPtp.h"

@implementation PtpCameraCanon

static NSDictionary* _ptpPropertyNames = nil;
static NSDictionary* _ptpPropertyValueNames = nil;

+ (void) initialize
{
	if (self == [PtpCameraCanon self])
	{
		NSDictionary* supportedCameras = @{
			@(0x049A) : @{
				@(0x3294) : @[@"Canon", @"80D", [PtpCameraCanon class]],
			},
		};
		
		[PtpCamera registerSupportedCameras: supportedCameras byClass: [PtpCameraCanon class]];

		NSMutableDictionary* propertyNames = [super ptpStandardPropertyNames].mutableCopy;
		[propertyNames addEntriesFromDictionary: @{
			@(PTP_PROP_CANON_EVF_OUTPUTDEVICE) : @"LiveView Output Device",
			@(PTP_PROP_CANON_EVF_MODE) : @"EVF Mode",
			@(PTP_PROP_CANON_EVF_WHITEBALANCE) : @"EVF Whitebalance",
		}];
		_ptpPropertyNames = propertyNames;
		
		NSDictionary* propertyValueNames = @{
			@(PTP_PROP_CANON_EVF_OUTPUTDEVICE) : @{
				@(0x00000000) : @"Off",
				@(0x00000001) : @"TFT",
				@(0x00000002) : @"PC",
				@(0x00000003) : @"TFT+PC",
			},
			@(PTP_PROP_CANON_EVF_MODE) : @{
				@(0x00000000) : @"Off",
				@(0x00000001) : @"On",
			},
			@(PTP_PROP_CANON_EVF_WHITEBALANCE) : @{
				@(0) : @"Auto",
				@(1) : @"Daylight",
				@(2) : @"Cloudy",
				@(3) : @"Tungsten",
				@(4) : @"Flourescent",
				@(5) : @"Flash",
				@(6) : @"Manual",
				@(8) : @"Shade",
				@(9) : @"Color Temp",
				@(10) : @"Custom 1",
				@(11) : @"Custom 2",
				@(12) : @"Custom 3",
				@(15) : @"Manual 2",
				@(16) : @"Manual 3",
				@(18) : @"Manual 4",
				@(19) : @"Manual 5",
				@(20) : @"Custom 4",
				@(21) : @"Custom 5",
				@(-1) : @"From Coordinates",
				@(-2) : @"From Image",
			},
		};
		
		_ptpPropertyValueNames = [PtpCamera mergePropertyValueDictionary: [PtpCamera ptpStandardPropertyValueNames] withDictionary: propertyValueNames];
	}
}

@end

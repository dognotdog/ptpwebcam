//
//  PtpCameraNikon.m
//  PTPWebcamDALPlugin
//
//  Created by Dömötör Gulyás on 28.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpCameraNikon.h"
#import "PtpWebcamPtp.h"
#import "PtpWebcamAlerts.h"

typedef enum {
	LV_STATUS_OFF,
	LV_STATUS_WAITING,
	LV_STATUS_ON,
	LV_STATUS_ERROR
} liveViewStatus_t;

@implementation PtpCameraNikon
{
	NSMutableSet* requiredPropertiesForReadiness; // properties required have been queried to declare the camera to the DAL plugin
	liveViewStatus_t liveViewStatus;
}

static NSDictionary* _ptpOperationNames = nil;
static NSDictionary* _ptpPropertyNames = nil;
static NSDictionary* _ptpPropertyValueNames = nil;


+ (void) initialize
{
	
	if (self == [PtpCameraNikon self])
	{
		NSDictionary* supportedCameras = @{
			// Nikon
			@(0x04B0) : @{
//				@(0x0410) : @[@"Nikon", @"D200"],
				@(0x041A) : @[@"Nikon", @"D300"],
				@(0x041C) : @[@"Nikon", @"D3"],
				@(0x0420) : @[@"Nikon", @"D3X"],
				@(0x0421) : @[@"Nikon", @"D90"],
				@(0x0422) : @[@"Nikon", @"D700"],
				@(0x0423) : @[@"Nikon", @"D5000"],
//				@(0x0424) : @[@"Nikon", @"D3000"],
				@(0x0425) : @[@"Nikon", @"D300S"],
				@(0x0426) : @[@"Nikon", @"D3S"],
				@(0x0428) : @[@"Nikon", @"D7000"],
				@(0x0429) : @[@"Nikon", @"D5100"],
				@(0x042A) : @[@"Nikon", @"D800"],
				@(0x042B) : @[@"Nikon", @"D4"],
				@(0x042C) : @[@"Nikon", @"D3200"],
				@(0x042D) : @[@"Nikon", @"D600"],
				@(0x042E) : @[@"Nikon", @"D800E"],
				@(0x042F) : @[@"Nikon", @"D5200"],
				@(0x0430) : @[@"Nikon", @"D7100"],
				@(0x0431) : @[@"Nikon", @"D5300"],
				@(0x0432) : @[@"Nikon", @"Df"],
				@(0x0433) : @[@"Nikon", @"D3300"],
				@(0x0434) : @[@"Nikon", @"D610"],
				@(0x0435) : @[@"Nikon", @"D4S"],
				@(0x0436) : @[@"Nikon", @"D810"],
				@(0x0437) : @[@"Nikon", @"D750"],
				@(0x0438) : @[@"Nikon", @"D5500"],
				@(0x0439) : @[@"Nikon", @"D7200"],
				@(0x043A) : @[@"Nikon", @"D5"],
				@(0x043B) : @[@"Nikon", @"D810A"],
				@(0x043C) : @[@"Nikon", @"D500"],
				@(0x043D) : @[@"Nikon", @"D3400"],
				@(0x043F) : @[@"Nikon", @"D5600"],
				@(0x0440) : @[@"Nikon", @"D7500"],
				@(0x0441) : @[@"Nikon", @"D850"],
				@(0x0442) : @[@"Nikon", @"Z7"],
				@(0x0443) : @[@"Nikon", @"Z6"],
				@(0x0444) : @[@"Nikon", @"Z50"],
				@(0x0445) : @[@"Nikon", @"D3500"],
				@(0x0446) : @[@"Nikon", @"D780"],
				@(0x0447) : @[@"Nikon", @"D6"],
			},
		};
		
		[PtpCamera registerSupportedCameras: supportedCameras byClass: [PtpCameraNikon class]];

		NSMutableDictionary* operationNames = [super ptpStandardOperationNames].mutableCopy;
		[operationNames addEntriesFromDictionary: @{
			@(PTP_CMD_NIKON_STARTLIVEVIEW) : @"Nikon Start LiveView",
			@(PTP_CMD_NIKON_STOPLIVEVIEW) : @"Nikon Stop LiveView",
			@(PTP_CMD_NIKON_GETLIVEVIEWIMG) : @"Nikon Get LiveView Image",
			@(PTP_CMD_NIKON_AFDRIVE) : @"Nikon Autofocus",
			@(PTP_CMD_NIKON_DEVICEREADY) : @"Nikon Get DeviceReady",
			@(PTP_CMD_NIKON_GETVENDORPROPS) : @"Nikon Get Vendor Properties",
			@(PTP_CMD_NIKON_MFDRIVE) : @"Nikon Manual Focus",
		}];
		_ptpOperationNames = operationNames;
				
		NSMutableDictionary* propertyNames = [super ptpStandardPropertyNames].mutableCopy;
		[propertyNames addEntriesFromDictionary: @{
			@(PTP_PROP_NIKON_WBTUNE_AUTO) : @"WB Auto Tune",
			@(PTP_PROP_NIKON_WBTUNE_INCADESCENT) : @"WB Incadescent Tune",
			@(PTP_PROP_NIKON_WBTUNE_FLOURESCENT) : @"WB Flourescent Tune",
			@(PTP_PROP_NIKON_WBTUNE_SUNNY) : @"WB Sunny Tune",
			@(PTP_PROP_NIKON_WBTUNE_FLASH) : @"WB Flash Tune",
			@(PTP_PROP_NIKON_WBTUNE_CLOUDY) : @"WB Cloudy Tune",
			@(PTP_PROP_NIKON_WBTUNE_SHADE) : @"WB Shade Tune",
			@(PTP_PROP_NIKON_WB_COLORTEMP) : @"Color Temperature",
			@(PTP_PROP_NIKON_LV_AFMODE) : @"AF Mode",
			@(PTP_PROP_NIKON_LV_AF) : @"AF Area Mode",
			@(PTP_PROP_NIKON_SHUTTERSPEED) : @"Shutter Speed",
			@(PTP_PROP_NIKON_WBTUNE_AUTOTYPE) : @"WB Auto Type",
			@(PTP_PROP_NIKON_WBTUNE_FLTYPE) : @"WB Flourescent Type",
			@(PTP_PROP_NIKON_WBTUNE_COLORTEMP) : @"Color Temp Tune",
			@(PTP_PROP_NIKON_ISOAUTOCONTROL) : @"Auto ISO",
			@(PTP_PROP_NIKON_LV_STATUS) : @"LiveView Status",
			@(PTP_PROP_NIKON_LV_ZOOM) : @"LiveView Zoom",
			@(PTP_PROP_NIKON_LV_PROHIBIT) : @"LiveView Prohibit Condition",
			@(PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW) : @"Exposure Preview",
			@(PTP_PROP_NIKON_LV_IMAGESIZE) : @"Live Image Size",
		}];
		_ptpPropertyNames = propertyNames;
		
		NSDictionary* propertyValueNames = @{
			@(PTP_PROP_EXPOSUREPM) : @{
				@(0x8010) : @"Auto",
				@(0x8011) : @"Portrait",
				@(0x8012) : @"Landscape",
				@(0x8013) : @"Close-up",
				@(0x8014) : @"Sports",
				@(0x8015) : @"Night Portrait",
				@(0x8016) : @"Flash Off Auto",
				@(0x8018) : @"SCENE",
				@(0x8019) : @"EFFECTS",
				@(0x8050) : @"U1",
				@(0x8051) : @"U2",
				@(0x8052) : @"U3",
			},
			@(PTP_PROP_WHITEBALANCE) : @{
				@(0x8010) : @"Cloudy",
				@(0x8011) : @"Shade",
				@(0x8012) : @"Color Temperature",
				@(0x8013) : @"Preset",
				@(0x8014) : @"Off",
				@(0x8016) : @"Natural Light Auto",
			},
			@(PTP_PROP_FOCUSMODE) : @{
				@(0x8010) : @"[S] Single",
				@(0x8011) : @"[C] Continuous",
				@(0x8012) : @"[A] Automatic",
				@(0x8013) : @"[F] Constant",
			},
			@(PTP_PROP_FOCUSMETERING) : @{
				@(0x8010) : @"Single Point",
				@(0x8011) : @"Auto Area",
				@(0x8012) : @"3D Tracking",
			},
			@(PTP_PROP_NIKON_ISOAUTOCONTROL) : @{
				@(0) : @"Off",
				@(1) : @"On",
			},
			@(PTP_PROP_NIKON_LV_AF) : @{
				@(0x0000) : @"Face Detect",
				@(0x0001) : @"Wide Area",
				@(0x0002) : @"Normal Area",
				@(0x0003) : @"Target Tracking",
			},
			@(PTP_PROP_NIKON_LV_AFMODE) : @{
				@(0x0000) : @"[S] Single",
				@(0x0001) : @"[F] Constant",
				@(0x0002) : @"[C] Continuous",
				@(0x0003) : @"Manual Lens",
				@(0x0004) : @"Manual",
			},
			@(PTP_PROP_NIKON_WBTUNE_AUTOTYPE) : @{
				@(0x0000) : @"Standard",
				@(0x0001) : @"Incadescent",
			},
			@(PTP_PROP_NIKON_WBTUNE_FLTYPE) : @{
				@(0x0000) : @"Sodium Mixed",
				@(0x0001) : @"Cool White FL",
				@(0x0002) : @"Warm White FL",
				@(0x0003) : @"White FL",
				@(0x0004) : @"Day White FL",
				@(0x0005) : @"Daylight FL",
				@(0x0006) : @"High Color Temp Mercury",
			},
			@(PTP_PROP_NIKON_LV_IMAGESIZE) : @{
				@(0x0000) : @"Undefined",
				@(0x0001) : @"QVGA 320x240",	// 320x240
				@(0x0002) : @"VGA 640x480",		// 640x480
				@(0x0003) : @"XGA 1024x768",	// 1024x768
			},
		};
		
		_ptpPropertyValueNames = [PtpCamera mergePropertyValueDictionary: [PtpCamera ptpStandardPropertyValueNames] withDictionary: propertyValueNames];
	}
}

- (instancetype) initWithIcCamera: (ICCameraDevice*) camera delegate: (id <PtpCameraDelegate>) delegate cameraInfo: (NSDictionary*) cameraInfo
{
	if (!(self = [super initWithIcCamera: camera delegate: delegate cameraInfo: cameraInfo]))
		return nil;
	
	self.uiPtpProperties = @[
		@(PTP_PROP_BATTERYLEVEL),
		@(PTP_PROP_FOCUSDISTANCE),
		@(PTP_PROP_FLEN),
		@(PTP_PROP_NIKON_LV_STATUS),
		@"-",
		@(PTP_PROP_EXPOSUREPM),
		@(PTP_PROP_FNUM),
		@(PTP_PROP_EXPOSUREISO),
		@(PTP_PROP_NIKON_ISOAUTOCONTROL),
		@(PTP_PROP_NIKON_SHUTTERSPEED), // show shutter speed instead of exposure time (more accurate)
		@(PTP_PROP_WHITEBALANCE),
		@(PTP_PROP_EXPOSUREBIAS),
		@(PTP_PROP_NIKON_LV_AFMODE),
		@(PTP_PROP_NIKON_LV_AF),
		@(PTP_PROP_NIKON_LV_ZOOM),
		@(PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW),
		@(PTP_PROP_NIKON_LV_IMAGESIZE),
	];
	
	self.uiPtpSubProperties = @{
		@(PTP_PROP_WHITEBALANCE) : @{
			@(0x0002) : @[@(PTP_PROP_NIKON_WBTUNE_AUTO), @(PTP_PROP_NIKON_WBTUNE_AUTOTYPE)],
			@(0x0004) : @[@(PTP_PROP_NIKON_WBTUNE_SUNNY)],
			@(0x0005) : @[@(PTP_PROP_NIKON_WBTUNE_FLOURESCENT), @(PTP_PROP_NIKON_WBTUNE_FLTYPE)],
			@(0x0006) : @[@(PTP_PROP_NIKON_WBTUNE_INCADESCENT)],
			@(0x0007) : @[@(PTP_PROP_NIKON_WBTUNE_FLASH)],
			@(0x8010) : @[@(PTP_PROP_NIKON_WBTUNE_CLOUDY)],
			@(0x8011) : @[@(PTP_PROP_NIKON_WBTUNE_SHADE)],
			@(0x8012) : @[@(PTP_PROP_NIKON_WB_COLORTEMP), @(PTP_PROP_NIKON_WBTUNE_COLORTEMP)],
		},
	};

	return self;
}

- (NSDictionary*) ptpOperationNames
{
	return _ptpOperationNames;
}

- (NSDictionary*) ptpPropertyNames
{
	return _ptpPropertyNames;
}

- (NSDictionary*) ptpPropertyValueNames
{
	return _ptpPropertyValueNames;
}

- (NSString*) formatPtpPropertyValue: (id) value ofProperty: (int) propertyId withDefaultValue: (id) defaultValue
{
	switch (propertyId)
	{
		case PTP_PROP_NIKON_WB_COLORTEMP:
			return [NSString stringWithFormat: @"%.0f K", [value doubleValue]];
		case PTP_PROP_NIKON_SHUTTERSPEED:
		{
			uint32_t val = [value unsignedIntValue];
			uint16_t nom = val >> 16;
			uint16_t den = val & 0x0000FFFF;
			if (val == 0xFFFFFFFF)
			{
				return @"Bulb";
			}
			else if (val == 0xFFFFFFFE)
			{
				return @"Flash";
			}
			else if ((den == 10) && (nom != 1))
			{
				return [NSString stringWithFormat:@"%.1f s", 0.1*nom];
			}
			else if ((nom == 10) && (den != 1))
			{
				return [NSString stringWithFormat:@"1/%.1f s", 0.1*den];
			}
			else if (den > 1)
			{
				return [NSString stringWithFormat:@"%u/%u s", nom, den];
			}
			else
			{
				return [NSString stringWithFormat:@"%u s", nom];
			}
		}
		case PTP_PROP_NIKON_WBTUNE_AUTO:
		case PTP_PROP_NIKON_WBTUNE_INCADESCENT:
		case PTP_PROP_NIKON_WBTUNE_FLOURESCENT:
		case PTP_PROP_NIKON_WBTUNE_SUNNY:
		case PTP_PROP_NIKON_WBTUNE_FLASH:
		case PTP_PROP_NIKON_WBTUNE_CLOUDY:
		case PTP_PROP_NIKON_WBTUNE_SHADE:
		case PTP_PROP_NIKON_WBTUNE_COLORTEMP:
			return [NSString stringWithFormat: @"%.0f", [value doubleValue] - [defaultValue doubleValue]];
		case PTP_PROP_NIKON_LV_STATUS:
		case PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW:
		{
			return [value boolValue] ? @"On" : @"Off";
		}
		default:
		{
			return [super formatPtpPropertyValue: value ofProperty: propertyId withDefaultValue: defaultValue];
		}
	}
}

- (void) queryDeviceBusy
{
	[self requestSendPtpCommandWithCode:PTP_CMD_NIKON_DEVICEREADY];
}

- (void) parsePtpLiveViewImageResponse: (NSData*) response data: (NSData*) data
{
	// response structure
	// 32bit length
	// 16bit 0x0003 type = response
	// 16bit response code
	// 32bit transaction id
	// 32bit response parameter
		
	uint32_t len = 0;
	[response getBytes: &len range: NSMakeRange(0, 4)];
	uint16_t type = 0;
	[response getBytes: &type range: NSMakeRange(4, 2)];
	uint16_t code = 0;
	[response getBytes: &code range: NSMakeRange(6, 2)];
	uint32_t transId = 0;
	[response getBytes: &transId range: NSMakeRange(8, 4)];

	bool isDeviceBusy = code == PTP_RSP_DEVICEBUSY;
	
	if (!data) // no data means no image to present
	{
		NSLog(@"parsePtpLiveViewImageResponse: no data!");
		
		// restart live view if it got turned off after timeout or error
		// device busy does not restart, as it does not indicate a permanent error condition that necessitates cycling.
		if (!isDeviceBusy)
		{
			PtpLog(@"error code 0x%04X", code);
			[self stopLiveView];
			[self startLiveView];
		}
		
		return;
	}
	
	
	switch (code)
	{
		case PTP_RSP_NIKON_NOTLIVEVIEW:
		{
			NSLog(@"camera not in liveview, no image.");
			//			[self asyncGetLiveViewImage];
			return;
		}
		case PTP_RSP_OK:
		{
			// OK means proceed with image
			break;
		}
		default:
		{
			NSLog(@"len = %u type = 0x%X, code = 0x%X, transId = %u", len, type, code, transId);
			break;
		}
			
	}
	
	
	// D800 LiveView image has a heaer of length 384 with metadata, with the rest being the JPEG image.
	size_t headerLen = self.liveViewHeaderLength;
	NSData* jpegData = [data subdataWithRange:NSMakeRange( headerLen, data.length - headerLen)];
	
	// TODO: JPEG SOI marker might appear in other data, so just using that is not enough to reliably extract JPEG without knowing more
//	NSData* jpegData = [self extractNikonLiveViewJpegData: data];
	
	[self.delegate receivedLiveViewJpegImage: jpegData withInfo: @{} fromCamera: self];
	
}

- (void) parseNikonPropertiesResponse: (NSData*) data
{
	uint32_t len = 0;
	[data getBytes: &len range: NSMakeRange(0, sizeof(len))];
	// some cameras, return a longer data buffer than necessary (eg. D7000 with 386 vs. 380 bytes), why is that?
	// TODO: investigate if the length header is wrong, eg. there are really 3 more entries than there should be, or if it the last 6 bytes are just garbage
	if (len*2+4 > data.length) // length is how many items we have following the header
	{
		PtpWebcamShowCatastrophicAlert(@"-parseNikonPropertiesResponse: expected response data length (%u) exceeds buffer size (%zu).", len*2+4, data.length);
		return;
	}
	
	
	NSMutableArray* properties = [NSMutableArray arrayWithCapacity: len];
	for (size_t i = 0; i < len; ++i)
	{
		uint16_t propertyId = 0;
		[data getBytes: &propertyId range: NSMakeRange(4+2*i, sizeof(propertyId))];
		[properties addObject: @(propertyId)];
	}
	
//	NSLog(@"Nikon Vendor Properties: %@", properties);
	
	for (NSNumber* prop in properties)
	{
		[self ptpGetPropertyDescription: [prop unsignedIntValue]];
	}

	@synchronized (self) {
		NSMutableDictionary* ptpDeviceInfo = self.ptpDeviceInfo.mutableCopy;
		NSArray* deviceProperties = [ptpDeviceInfo[@"properties"] arrayByAddingObjectsFromArray: properties];
		
		ptpDeviceInfo[@"properties"] = deviceProperties;
		self.ptpDeviceInfo = ptpDeviceInfo;

	}
	
	// after receiving the vendor specific property list, we need to query some properties
	requiredPropertiesForReadiness = [NSMutableSet set];
	
	if ([self isPtpPropertySupported: PTP_PROP_NIKON_LV_IMAGESIZE])
		[requiredPropertiesForReadiness addObject: @(PTP_PROP_NIKON_LV_IMAGESIZE)];
	if ([self isPtpPropertySupported: PTP_PROP_NIKON_LV_PROHIBIT])
		[requiredPropertiesForReadiness addObject: @(PTP_PROP_NIKON_LV_PROHIBIT)];

	// if there are no properties we need to check, we're ready
	if (!requiredPropertiesForReadiness.count)
	{
		[self initialPtpPropertiesDiscoveryComplete];
	}
	else
	{
		for (NSNumber* propertyId in requiredPropertiesForReadiness.copy)
		{
			[self ptpGetPropertyDescription: propertyId.unsignedIntValue];
		}
	}
}

- (void) initialPtpPropertiesDiscoveryComplete
{
	[self cameraDidBecomeReadyForUse];
}

- (void)didSendPTPCommand:(NSData*)command inData:(NSData*)data response:(NSData*)response error:(NSError*)error contextInfo:(void*)contextInfo
{
	uint16_t cmd = 0;
	[command getBytes: &cmd range: NSMakeRange(6, 2)];

	switch (cmd)
	{
		case PTP_CMD_NIKON_GETVENDORPROPS:
			[self parseNikonPropertiesResponse: data];
			break;
		case PTP_CMD_NIKON_GETLIVEVIEWIMG:
		{
			[self parsePtpLiveViewImageResponse: response data: data];
//			if (inLiveView)
//				[self requestLiveViewImage];
			
			break;
		}
		case PTP_CMD_NIKON_DEVICEREADY:
		{
			uint16_t code = 0;
			[response getBytes: &code range: NSMakeRange(6, 2)];
			
			switch (code)
			{
				case PTP_RSP_DEVICEBUSY:
					[self queryDeviceBusy];
					break;
				case PTP_RSP_OK:
				{
					// activate frame timer when device is ready after starting live view to start getting images
					if ([self isPtpPropertySupported:PTP_PROP_NIKON_LV_STATUS])
						[self ptpGetPropertyDescription: PTP_PROP_NIKON_LV_STATUS];
					else
						[self cameraDidBecomeReadyForLiveViewStreaming];
					// update exposure preview property for UI, as it is not automatically queried otherwise
					if ([self isPtpPropertySupported:PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW])
						[self ptpGetPropertyDescription: PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW];
					break;
				}
				default:
				{
					// some error occured
					NSLog(@"didSendPTPCommand  DeviceReady returned error 0x%04X", code);
					[self stopLiveView];
					break;
				}
			}

			break;
		}
		default:
			[super didSendPTPCommand: command inData: data response: response error: error contextInfo: contextInfo];
			
			break;
	}

}

- (NSArray*) prohibitErrorNames: (NSNumber*) prohibitValue
{
//	NSDictionary* lvProhibitInfo = self.ptpPropertyInfos[@(PTP_PROP_NIKON_LV_PROHIBIT)];
//
//	NSNumber* prohibitValue = lvProhibitInfo[@"value"];
	
	uint32_t prohibitCondition = prohibitValue.unsignedIntValue;
	
	if (prohibitCondition != 0)
	{
		NSMutableArray* prohibitConditions = [NSMutableArray array];
		for (size_t i = 0; i < 32; ++i)
		{
			bool bitSet = 0 != (prohibitCondition & (1 << i));
			if (!bitSet)
				continue;
			NSString* errorName = nil;
			switch(i)
			{
				case 2:
					errorName =  @"Sequence error";
					break;
				case 4:
					errorName =  @"Fully depressed shutter button";
					break;
				case 5:
					errorName =  @"Aperture value set by lens aperture ring";
					break;
				case 6:
					errorName =  @"Bulb warning";
					break;
				case 7:
					errorName =  @"Mirror-up in progress";
					break;
				case 8:
					errorName =  @"Battery low";
					break;
				case 9:
					errorName =  @"TTL error";
					break;
				case 11:
					errorName =  @"CPU lens not mounted and mode is not M";
					break;
				case 12:
					errorName =  @"Image in SDRAM";
					break;
				case 14:
					errorName =  @"Recording destination error";
					break;
				case 15:
					errorName =  @"Capture in progress";
					break;
				case 16:
					errorName =  @"Shooting mode is EFFECTS";
					break;
				case 17:
					errorName =  @"Temperature too high";
					break;
				case 18:
					errorName =  @"Card protected";
					break;
				case 19:
					errorName =  @"Card error";
					break;
				case 20:
					errorName =  @"Card unformatted";
					break;
				case 21:
					errorName =  @"Bulb warning";
					break;
				case 22:
					errorName =  @"Mirror-up in progress";
					break;
				case 24:
					errorName =  @"Lens retraction in progress";
					break;
				case 31:
					errorName =  @"Exposure Progam Mode not one of PSAM";
					break;
			}
			if (!errorName)
				[prohibitConditions addObject: [NSString stringWithFormat: @"Error Bit %zu", i]];
			else
				[prohibitConditions addObject: [NSString stringWithFormat: @"%@ (bit %zu)", errorName, i]];
		}
		return prohibitConditions;
	}
	else
		return nil;
		
}

- (void) receivedProperty: (NSDictionary*) propertyInfo oldProperty: (NSDictionary*) oldInfo withId: (NSNumber*) propertyId
{
	if (requiredPropertiesForReadiness.count)
	{
		if ([requiredPropertiesForReadiness containsObject: propertyId])
		{
			[requiredPropertiesForReadiness removeObject: propertyId];
			if (requiredPropertiesForReadiness.count == 0)
			{
				[self initialPtpPropertiesDiscoveryComplete];
			}
		}
	}
	
	switch(propertyId.intValue)
	{
		case PTP_PROP_NIKON_LV_STATUS:
		{
			bool isLiveViewOn = [propertyInfo[@"value"] intValue] > 0;
			if ((liveViewStatus == LV_STATUS_WAITING) && isLiveViewOn)
			{
				[self cameraDidBecomeReadyForLiveViewStreaming];
			}
			else if (!isLiveViewOn)
			{
				if ([self isPtpPropertySupported:PTP_PROP_NIKON_LV_PROHIBIT])
					[self ptpGetPropertyDescription: PTP_PROP_NIKON_LV_PROHIBIT];
			}
			break;
		}
		case PTP_PROP_NIKON_LV_PROHIBIT:
		{
			NSArray* prohibitConditions = [self prohibitErrorNames: propertyInfo[@"value"]];
			if (prohibitConditions.count)
				PtpWebcamShowDeviceAlert(@"LiveView cannot be started because of the following error conditions: %@", [prohibitConditions componentsJoinedByString: @", "]);

			break;
		}
	}
	
	[super receivedProperty: propertyInfo oldProperty: oldInfo withId: propertyId];
}

- (void) cameraDidBecomeReadyForLiveViewStreaming
{
	liveViewStatus = LV_STATUS_ON;
	[super cameraDidBecomeReadyForLiveViewStreaming];
}

- (BOOL) startLiveView
{
	PtpLog(@"");
	
	// do not do prohibit check here as info might be stale
//	NSDictionary* lvProhibitInfo = self.ptpPropertyInfos[@(PTP_PROP_NIKON_LV_PROHIBIT)];
//
//	NSNumber* prohibitValue = lvProhibitInfo[@"value"];
//
//	NSArray* prohibitConditions = [self prohibitErrorNames: prohibitValue];
//
//	if (prohibitConditions.count)
//	{
//		PtpWebcamShowDeviceAlert(@"LiveView cannot be started because of the following error conditions: %@", [prohibitConditions componentsJoinedByString: @", "]);
//		liveViewStatus = LV_STATUS_ERROR;
//		return NO;
//	}
	
	liveViewStatus = LV_STATUS_WAITING;
	
	[self requestSendPtpCommandWithCode: PTP_CMD_NIKON_STARTLIVEVIEW];
	
	BOOL isDeviceReadySupported = [self isPtpOperationSupported: PTP_CMD_NIKON_DEVICEREADY];
	
	if (isDeviceReadySupported)
	{
		// query deviceReady with a little delay
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(33 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
			[self queryDeviceBusy];
		});
	}
	else
	{
		// refresh device properties after live view is on, having given the camera little time to switch
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
			[self cameraDidBecomeReadyForLiveViewStreaming];
		});
	}
	return YES;
}

- (void) stopLiveView
{
	[self requestSendPtpCommandWithCode: PTP_CMD_NIKON_STOPLIVEVIEW];
	liveViewStatus = LV_STATUS_OFF;
	[super stopLiveView];
}

- (void) requestLiveViewImage
{
	[self requestSendPtpCommandWithCode: PTP_CMD_NIKON_GETLIVEVIEWIMG];
}
- (NSSize) currenLiveViewImageSize
{
	NSDictionary* liveViewSizeInfo = self.ptpPropertyInfos[@(PTP_PROP_NIKON_LV_IMAGESIZE)];
	NSNumber* liveViewImageSize = liveViewSizeInfo[@"value"];
	if (!liveViewSizeInfo || !liveViewImageSize)
		return NSMakeSize(640, 480);
	
	switch(liveViewImageSize.intValue)
	{
		case 1:
			return NSMakeSize(320, 240);
		case 2:
			return NSMakeSize(640, 480);
		case 3:
			return NSMakeSize(1024, 768);
		default:
			return NSZeroSize;
	}
}

- (NSArray*) liveViewImageSizes
{
	NSDictionary* liveViewSizeInfo = self.ptpPropertyInfos[@(PTP_PROP_NIKON_LV_IMAGESIZE)];
	if (!liveViewSizeInfo)
		return @[[NSValue valueWithSize: NSMakeSize(640, 480)]];
	NSArray* range = liveViewSizeInfo[@"range"];
	NSMutableArray* sizes = [NSMutableArray arrayWithCapacity: range.count];
	for (NSNumber* sizeNum in range)
	{
		NSSize size = NSZeroSize;
		switch(sizeNum.intValue)
		{
			case 1:
				size = NSMakeSize(320, 240);
				break;
			case 2:
				size = NSMakeSize(640, 480);
				break;
			case 3:
				size = NSMakeSize(1024, 768);
				break;
		}
		[sizes addObject: [NSValue valueWithSize: size]];
	}

	return sizes;
}

@end

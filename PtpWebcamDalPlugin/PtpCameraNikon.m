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

@implementation PtpCameraNikon

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
			@(PTP_PROP_NIKON_LV_STATUS) : @"LiveView Status",
			@(PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW) : @"Exposure Preview",
//			@(PTP_PROP_NIKON_LV_IMAGESIZE) : @"Live Image Size",
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
	
	// after receiving the vendor specific properties, we are ready to roll
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

- (void) startLiveView
{
	PtpLog(@"");
	[self requestSendPtpCommandWithCode: PTP_CMD_NIKON_STARTLIVEVIEW];
	
	BOOL isDeviceReadySupported = [self isPtpOperationSupported: PTP_CMD_NIKON_DEVICEREADY];
	
	if (isDeviceReadySupported)
	{
		// if the deviceReady command is supported, issue it to find out when live view is ready instead of simply waiting
		[self queryDeviceBusy];
	}
	else
	{
		// refresh device properties after live view is on, having given the camera little time to switch
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
			[self cameraDidBecomeReadyForLiveViewStreaming];
		});
	}
}

- (void) stopLiveView
{
	[self requestSendPtpCommandWithCode: PTP_CMD_NIKON_STOPLIVEVIEW];
	[super stopLiveView];
}

- (void) requestLiveViewImage
{
	[self requestSendPtpCommandWithCode: PTP_CMD_NIKON_GETLIVEVIEWIMG];
}

@end

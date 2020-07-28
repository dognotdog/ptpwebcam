//
//  PtpCamera.m
//  PtpWebcamAssistantService
//
//  Created by Dömötör Gulyás on 25.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpCamera.h"

#import <ImageCaptureCore/ImageCaptureCore.h>

#import "PtpWebcamAssistantService.h"
#import "PtpWebcamAlerts.h"
#import "../PtpWebcamDalPlugin/PtpWebcamPtp.h"
#import "../PtpWebcamDalPlugin/PtpWebcamStream.h"


typedef enum {
	PTP_CAMERA_MECHANISM_NIKON,
	PTP_CAMERA_MECHANISM_CANON,
} ptpWebcamCameraMechanism_t;


@implementation PtpCamera
{
	uint32_t transactionId;
	
	ptpWebcamCameraMechanism_t mechanism;
	

	dispatch_queue_t frameQueue;
	dispatch_source_t frameTimerSource;
	id videoActivityToken;
	BOOL inLiveView;
}

static NSDictionary* _supportedCameras = nil;
static NSDictionary* _confirmedCameras = nil;

static NSDictionary* _ptpPropertyNames = nil;
static NSDictionary* _ptpProgramModeNames = nil;
static NSDictionary* _ptpWhiteBalanceModeNames = nil;
static NSDictionary* _ptpLiveViewImageSizeNames = nil;
static NSDictionary* _ptpNonAdvertisedOperations = nil;

static NSDictionary* _liveViewJpegDataOffsets = nil;

+ (void)initialize
{
	if (self == [PtpCamera self])
	{
		_supportedCameras = @{
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
			// Canon
			@(0x049A) : @{
//				@(0x3294) : @[@"Canon", @"80D"],
			},
		};
		_confirmedCameras = @{
			// Nikon
			@(0x04B0) : @{
//				@(0x0410) : @[@"Nikon", @"D200"],
//				@(0x041A) : @[@"Nikon", @"D300"],
//				@(0x041C) : @[@"Nikon", @"D3"],
//				@(0x0420) : @[@"Nikon", @"D3X"],
//				@(0x0421) : @[@"Nikon", @"D90"],
//				@(0x0422) : @[@"Nikon", @"D700"],
//				@(0x0423) : @[@"Nikon", @"D5000"],
//				@(0x0424) : @[@"Nikon", @"D3000"],
//				@(0x0425) : @[@"Nikon", @"D300S"],
//				@(0x0426) : @[@"Nikon", @"D3S"],
//				@(0x0428) : @[@"Nikon", @"D7000"],
//				@(0x0429) : @[@"Nikon", @"D5100"],
				@(0x042A) : @(YES), // D800
//				@(0x042B) : @[@"Nikon", @"D4"],
//				@(0x042C) : @[@"Nikon", @"D3200"],
//				@(0x042D) : @[@"Nikon", @"D600"],
//				@(0x042E) : @[@"Nikon", @"D800E"],
				@(0x042F) : @(YES), // D5200
//				@(0x0430) : @[@"Nikon", @"D7100"],
//				@(0x0431) : @[@"Nikon", @"D5300"],
//				@(0x0432) : @[@"Nikon", @"Df"],
//				@(0x0433) : @[@"Nikon", @"D3300"],
//				@(0x0434) : @[@"Nikon", @"D610"],
//				@(0x0435) : @[@"Nikon", @"D4S"],
//				@(0x0436) : @[@"Nikon", @"D810"],
				@(0x0437) : @(YES), // D750
//				@(0x0438) : @[@"Nikon", @"D5500"],
//				@(0x0439) : @[@"Nikon", @"D7200"],
//				@(0x043A) : @[@"Nikon", @"D5"],
//				@(0x043B) : @[@"Nikon", @"D810A"],
//				@(0x043C) : @[@"Nikon", @"D500"],
				@(0x043D) : @(YES), // D3400
//				@(0x043F) : @[@"Nikon", @"D5600"],
//				@(0x0440) : @[@"Nikon", @"D7500"],
//				@(0x0441) : @[@"Nikon", @"D850"],
				@(0x0442) : @(YES), // Z7
				@(0x0443) : @(YES), // Z6
//				@(0x0444) : @[@"Nikon", @"Z50"],
//				@(0x0445) : @[@"Nikon", @"D3500"],
//				@(0x0446) : @[@"Nikon", @"D780"],
//				@(0x0447) : @[@"Nikon", @"D6"],
			},
		};

		_ptpPropertyNames = @{
			@(PTP_PROP_BATTERYLEVEL) : @"Battery Level",
			@(PTP_PROP_WHITEBALANCE) : @"White Balance",
			@(PTP_PROP_FNUM) : @"Aperture",
			@(PTP_PROP_FOCUSDISTANCE) : @"Focus Distance",
			@(PTP_PROP_EXPOSUREPM) : @"Exposure Program Mode",
			@(PTP_PROP_EXPOSUREISO) : @"ISO",
			@(PTP_PROP_EXPOSUREBIAS) : @"Exposure Correction",
			@(PTP_PROP_FLEN) : @"Focal Length",
			@(PTP_PROP_EXPOSURETIME) : @"Exposure Time",
			@(PTP_PROP_NIKON_LV_STATUS) : @"LiveView Status",
			@(PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW) : @"Exposure Preview",
		};
		_ptpProgramModeNames = @{
			@(0x0000) : @"Undefined",
			@(0x0001) : @"Manual",
			@(0x0002) : @"Automatic",
			@(0x0003) : @"Aperture Priority",
			@(0x0004) : @"Shutter Priority",
			@(0x0005) : @"Creative",
			@(0x0006) : @"Action",
			@(0x0007) : @"Portrait",
			// Nikon specific
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
		};
		_ptpWhiteBalanceModeNames = @{
			@(0x0000) : @"Undefined",
			@(0x0001) : @"Manual",
			@(0x0002) : @"Automatic",
			@(0x0003) : @"One-Push Automatic",
			@(0x0004) : @"Daylight",
			@(0x0005) : @"Flourescent",
			@(0x0006) : @"Tungsten",
			@(0x0007) : @"Flash",
			// Nikon specific
			@(0x8010) : @"Cloudy",
			@(0x8011) : @"Shade",
			@(0x8012) : @"Color Temperature",
			@(0x8013) : @"Preset",
			@(0x8014) : @"Off",
			@(0x8016) : @"Natural Light Auto",
		};

		_ptpLiveViewImageSizeNames = @{
			@(0x0000) : @"Undefined",
			@(0x0001) : @"QVGA",	// 320x240
			@(0x0002) : @"VGA",		// 640x480
			@(0x0003) : @"XGA",		// 1024x768
		};

		_ptpNonAdvertisedOperations = @{
			@(0x04B0) : @{
				// TODO: it looks as though the D3200 and newer in the series not advertise everything they can do, confirm that this is actually the case
				@(0x042C) : @[@(PTP_CMD_STARTLIVEVIEW), @(PTP_CMD_STOPLIVEVIEW), @(PTP_CMD_GETLIVEVIEWIMG)], // D3200
				@(0x0433) : @[@(PTP_CMD_NIKON_GETVENDORPROPS), @(PTP_CMD_STARTLIVEVIEW), @(PTP_CMD_STOPLIVEVIEW), @(PTP_CMD_GETLIVEVIEWIMG)], // D3300
				@(0x043D) : @[@(PTP_CMD_NIKON_GETVENDORPROPS), @(PTP_CMD_STARTLIVEVIEW), @(PTP_CMD_STOPLIVEVIEW), @(PTP_CMD_GETLIVEVIEWIMG)], // D3400
				@(0x0445) : @[@(PTP_CMD_NIKON_GETVENDORPROPS), @(PTP_CMD_STARTLIVEVIEW), @(PTP_CMD_STOPLIVEVIEW), @(PTP_CMD_GETLIVEVIEWIMG)], // D3500
			},
		};

		_liveViewJpegDataOffsets = @{
			@(0x04B0) : @{
				// JPEG data offset
				@(0x041A) : @(64), // D300
				@(0x041C) : @(64), // D3
				@(0x0420) : @(64), // D3X
				@(0x0421) : @(128), // D90
				@(0x0422) : @(64), // D700
				@(0x0423) : @(128), // D5000
				@(0x0425) : @(64), // D300S
				@(0x0426) : @(128), // D3S
				@(0x0428) : @(384), // D7000
				@(0x0429) : @(384), // D5100
				@(0x042A) : @(384), // D800
				@(0x042B) : @(384), // D4
				@(0x042C) : @(384), // D3200
				@(0x042D) : @(384), // D600
				@(0x042E) : @(384), // D800E
				@(0x042F) : @(384), // D5200
				@(0x0430) : @(384), // D7100
				@(0x0431) : @(384), // D5300
				@(0x0432) : @(384), // Df
				@(0x0433) : @(384), // D3300
				@(0x0434) : @(384), // D610
				@(0x0435) : @(384), // D4S
				@(0x0436) : @(384), // D810
				@(0x0437) : @(384), // D750
				@(0x0438) : @(384), // D5500
				@(0x0439) : @(384), // D7200
				@(0x043A) : @(384), // D5
				@(0x043B) : @(384), // D810A
				@(0x043C) : @(384), // D500
				@(0x043D) : @(384), // D3400
				@(0x043F) : @(384), // D5600
				@(0x0440) : @(384), // D7500
				@(0x0441) : @(384), // D850
				@(0x0442) : @(384), // Z7
				@(0x0443) : @(384), // Z6
				@(0x0444) : @(384), // Z50
				@(0x0445) : @(384), // D3500
				@(0x0446) : @(384), // D780
				@(0x0447) : @(384), // D6
			},
		};

	}
}


+ (nullable NSDictionary*) isDeviceSupported: (ICDevice*) device
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
	});
	
	uint16_t vendorId = device.usbVendorID;
	uint16_t productId = device.usbProductID;

	NSDictionary* modelDict = _supportedCameras[@(vendorId)];
	if (!modelDict)
		return nil;
	NSArray* cameraInfo = modelDict[@(productId)];
	if (!cameraInfo)
		return nil;
	
	NSDictionary* confirmedModelDict = _confirmedCameras[@(vendorId)];
	NSNumber* confirmedCameraInfo = confirmedModelDict[@(productId)];

	return @{
		@"make" : cameraInfo[0],
		@"model" : cameraInfo[1],
		@"confirmed" : @([confirmedCameraInfo boolValue]),
	};
}

- (instancetype) initWithIcCamera: (ICCameraDevice*) camera delegate: (id <PtpCameraDelegate>) delegate
{
	if (!(self = [super init]))
		return nil;
	
	NSDictionary* cameraInfo = [[self class] isDeviceSupported: camera];
	
	if (!cameraInfo)
		return nil;
	

//	dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
//
//	frameQueue = dispatch_queue_create("PtpWebcamStreamFrameQueue", queueAttributes);
//
//	frameTimerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, frameQueue);
//	dispatch_source_set_timer(frameTimerSource, DISPATCH_TIME_NOW, 1.0/WEBCAM_STREAM_FPS*NSEC_PER_SEC, 1000u*NSEC_PER_SEC);
//
//	__weak id weakSelf = self;
//	dispatch_source_set_event_handler(frameTimerSource, ^{
//		[weakSelf requestLiveViewImage];
//	});

	
	NSDictionary* liveViewJpegOffsetsMake = _liveViewJpegDataOffsets[@(camera.usbVendorID)];
	self.liveViewHeaderLength = [liveViewJpegOffsetsMake[@(camera.usbProductID)] unsignedIntegerValue];

	self.delegate = delegate;
	self.icCamera = camera;
	self.make = cameraInfo[@"make"];
	self.model = cameraInfo[@"model"];
	self.cameraId = [NSString stringWithFormat: @"ptpwebcam-%@-%@-%@", self.make, self.model, camera.serialNumberString];
	
	camera.delegate = self;
	
	[camera requestEnableTethering];
	
	[self requestSendPtpCommandWithCode:PTP_CMD_GETDEVICEINFO];
	
	return self;

}

- (void) dealloc
{
	if (frameTimerSource)
		dispatch_suspend(frameTimerSource);
}

- (void) deviceDidBecomeReadyWithCompleteContentCatalog:(ICCameraDevice *)device
{
	NSLog(@"deviceDidBecomeReadyWithCompleteContentCatalog %@", device);
}

- (void)cameraDevice:(nonnull ICCameraDevice *)camera didAddItems:(nonnull NSArray<ICCameraItem *> *)items
{
}


- (void)cameraDevice:(nonnull ICCameraDevice *)camera didReceivePTPEvent:(nonnull NSData *)eventData
{
	uint32_t len = 0;
	[eventData getBytes: &len range: NSMakeRange(0, sizeof(len))];
	uint16_t type = 0;
	[eventData getBytes: &type range: NSMakeRange(4, sizeof(type))];
	uint16_t code = 0;
	[eventData getBytes: &code range: NSMakeRange(6, sizeof(code))];
	uint32_t transactionId = 0;
	[eventData getBytes: &transactionId range: NSMakeRange(8, sizeof(transactionId))];
	uint32_t eventParam = 0;
	[eventData getBytes: &eventParam range: NSMakeRange(12, sizeof(eventParam))];
	
	switch (code)
	{
		case PTP_EVENT_DEVICEPROPCHANGED:
		{
			// if a device property changed that's shown in the UI, update its value
			if (_ptpPropertyNames[@(eventParam)])
				[self ptpGetPropertyDescription: eventParam];

			break;
		}
	}
}


- (void)cameraDevice:(nonnull ICCameraDevice *)camera didRemoveItems:(nonnull NSArray<ICCameraItem *> *)items
{
}


- (void)cameraDevice:(nonnull ICCameraDevice *)camera didRenameItems:(nonnull NSArray<ICCameraItem *> *)items
{
}


- (void)cameraDeviceDidChangeCapability:(nonnull ICCameraDevice *)camera
{
}


- (void)cameraDeviceDidEnableAccessRestriction:(nonnull ICDevice *)device
{
}


- (void)cameraDeviceDidRemoveAccessRestriction:(nonnull ICDevice *)device
{
}

- (void) cameraDevice:(ICCameraDevice *)camera didReceiveThumbnailForItem:(ICCameraItem *)item
{
	
}
- (void) cameraDevice:(ICCameraDevice *)camera didReceiveMetadataForItem:(ICCameraItem *)item
{
	
}

- (void) device:(ICDevice *)device didOpenSessionWithError:(NSError *)error
{
	NSLog(@"-device:didOpenSessionWithError");
	if (error)
		NSLog(@"PTP Webcam could not open ddevice session because %@", error);
	
}

- (void)device:(nonnull ICDevice *)device didCloseSessionWithError:(nonnull NSError *)error
{
}

- (void) didRemoveDevice:(nonnull ICDevice *)device
{
	NSLog(@"%@", NSStringFromSelector(_cmd));
	[self.delegate cameraWasRemoved: self];
}

- (NSData*) ptpCommandWithType: (uint16_t) type code: (uint16_t) code transactionId: (uint32_t) transId parameters: (NSData*) paramData
{
	uint32_t length = 12 + (uint32_t)paramData.length;
	NSMutableData* data = [NSMutableData data];
	[data appendBytes: &length length: 4];
	[data appendBytes: &type length: 2];
	[data appendBytes: &code length: 2];
	[data appendBytes: &transId length: 4];
	[data appendData: paramData];
	
	return data;
}

- (NSData*) ptpCommandWithType: (uint16_t) type code: (uint16_t) code transactionId: (uint32_t) transId
{
	return [self ptpCommandWithType: type code: code transactionId: transId parameters: nil];
}

- (void) ptpGetPropertyDescription: (uint32_t) property
{
	NSMutableData* data = [NSMutableData data];
	[data appendBytes: &property length: 4];

	NSData* command = [self ptpCommandWithType: PTP_TYPE_COMMAND code: PTP_CMD_GETPROPDESC transactionId: [self nextTransactionId] parameters: data];
	
	[self sendPtpCommand: command];
}

- (void) ptpGetPropertyValue: (uint32_t) property
{
	NSMutableData* data = [NSMutableData data];
	[data appendBytes: &property length: 4];

	NSData* command = [self ptpCommandWithType: PTP_TYPE_COMMAND code: PTP_CMD_GETPROPVAL transactionId: [self nextTransactionId] parameters: data];
	
	[self sendPtpCommand: command];
}

- (void) ptpSetProperty: (uint32_t) property toValue: (id) value
{
	NSMutableData* paramData = [NSMutableData data];
	[paramData appendBytes: &property length: sizeof(property)];

	NSMutableData* data = [NSMutableData data];
	int dataType = [self getPtpPropertyType: property];
	switch(dataType)
	{
		case PTP_DATATYPE_UINT8_RAW:
		{
			uint8_t val = [value unsignedCharValue];
			[data appendBytes: &val length: sizeof(val)];
			break;
		}
		case PTP_DATATYPE_UINT16_RAW:
		{
			uint16_t val = [value unsignedShortValue];
			[data appendBytes: &val length: sizeof(val)];
			break;
		}
		case PTP_DATATYPE_SINT16_RAW:
		{
			int16_t val = [value shortValue];
			[data appendBytes: &val length: sizeof(val)];
			break;
		}
		case PTP_DATATYPE_UINT32_RAW:
		{
			uint32_t val = [value unsignedIntValue];
			[data appendBytes: &val length: sizeof(val)];
			break;
		}

	}

	
	NSData* command = [self ptpCommandWithType: PTP_TYPE_COMMAND code: PTP_CMD_SETPROPVAL transactionId: [self nextTransactionId] parameters: paramData];
	
	[self sendPtpCommand: command withData: data];
}

- (void) sendPtpCommand: (NSData*) command
{
	[self.icCamera requestSendPTPCommand: command
									 outData: nil
						 sendCommandDelegate: self
					  didSendCommandSelector: @selector(didSendPTPCommand:inData:response:error:contextInfo:)
								 contextInfo: NULL];

}

- (void) sendPtpCommand: (NSData*) command withData: (NSData*) data
{
	[self.icCamera requestSendPTPCommand: command
									 outData: data
						 sendCommandDelegate: self
					  didSendCommandSelector: @selector(didSendPTPCommand:inData:response:error:contextInfo:)
								 contextInfo: NULL];

}


- (void)didSendPTPCommand:(NSData*)command inData:(NSData*)data response:(NSData*)response error:(NSError*)error contextInfo:(void*)contextInfo
{
	if (error)
		NSLog(@"didSendPTPCommand error=%@", error);
	
	uint16_t cmd = 0;
	[command getBytes: &cmd range: NSMakeRange(6, 2)];
	
	// response is
	// length (32bit)
	// type (16bit)
	// response code (16bit) 0x0003
	// transaction id (32bit)
	
	switch (cmd)
	{
		case PTP_CMD_GETDEVICEINFO:
			[self parsePtpDeviceInfoResponse: data];
			break;
		case PTP_CMD_SETPROPVAL:
			break;
		case PTP_CMD_GETPROPDESC:
			if (!data)
				NSLog(@"ooops no data received for property description");
			[self parsePtpPropertyDescription: data];
			break;
		case PTP_CMD_GETPROPVAL:
			[self parsePtpPropertyValue: data];
			break;
		case PTP_CMD_NIKON_GETVENDORPROPS:
			[self parseNikonPropertiesResponse: data];
			break;
		case PTP_CMD_GETLIVEVIEWIMG:
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
			NSLog(@"didSendPTPCommand  cmd=%@", command);
			NSLog(@"didSendPTPCommand data=%@", data);
			break;
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

- (id) dataToValue: (NSData*) data ofType: (int) dataType
{
	id value = nil;
	
	switch(dataType)
	{
		case PTP_DATATYPE_UINT8_RAW:
		{
			uint8_t val = 0;
			[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
			value = @(val);
			break;
		}
		case PTP_DATATYPE_UINT16_RAW:
		{
			uint16_t val = 0;
			[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
			value = @(val);
			break;
		}
		case PTP_DATATYPE_SINT16_RAW:
		{
			int16_t val = 0;
			[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
			value = @(val);
			break;
		}
		case PTP_DATATYPE_UINT32_RAW:
		{
			uint32_t val = 0;
			[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
			value = @(val);
			break;
		}
	}
	return value;
}

- (int) getPtpPropertyType: (uint32_t) property
{
	switch(property)
	{
		case PTP_PROP_BATTERYLEVEL:
		case PTP_PROP_NIKON_LV_STATUS:
		case PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW:
			return PTP_DATATYPE_UINT8_RAW;
		case PTP_PROP_WHITEBALANCE:
		case PTP_PROP_FNUM:
		case PTP_PROP_FOCUSDISTANCE:
		case PTP_PROP_EXPOSUREPM:
		case PTP_PROP_EXPOSUREISO:
			return PTP_DATATYPE_UINT16_RAW;
		case PTP_PROP_EXPOSUREBIAS:
			return PTP_DATATYPE_SINT16_RAW;
		case PTP_PROP_FLEN:
		case PTP_PROP_EXPOSURETIME:
			return PTP_DATATYPE_UINT32_RAW;
//		case PTP_PROP_NIKON_LV_WHITEBALANCE:
//			assert(0);
//			return 0;
		default:
//			NSLog(@"Unknown Property 0x%04X, cannot determine type.", property);
			return 0;
	}

}

- (size_t) getPtpPropertyDataTypeSize: (int) dataType
{
	switch (dataType)
	{
		case PTP_DATATYPE_UINT8_RAW:
			return 1;
		case PTP_DATATYPE_UINT16_RAW:
		case PTP_DATATYPE_SINT16_RAW:
			return 2;
		case PTP_DATATYPE_UINT32_RAW:
			return 4;
		default:
			return 0;
	}
}

- (void) parsePtpPropertyDescription: (NSData*) data
{
	// 16b property id
	// 16b 0x0002 -> container of type data
	// 8b get/set (0 ro, 1 rw)
	// default value
	// current value
	// form flag (0 none, 1 range, 2 enum)
	// for range:
		// min
		// max
		// stepsize
	// for enum:
		// 16b count
		// values
	
	uint16_t property = 0;
	[data getBytes: &property range: NSMakeRange(0, sizeof(property))];
	uint8_t rw = 0;
	[data getBytes: &rw range: NSMakeRange(4, sizeof(rw))];

	int dataType = [self getPtpPropertyType: property];
	
	if (PTP_DATATYPE_INVALID == dataType)
		return;
	
	size_t valueLength = [self getPtpPropertyDataTypeSize: dataType];

	id value = [self dataToValue: [data subdataWithRange: NSMakeRange(5+valueLength, valueLength)] ofType: dataType];
		
	uint8_t formType = 0;
	[data getBytes: &formType range: NSMakeRange(5+2*valueLength, sizeof(formType))];
	
	id form = @[];
	
	switch(formType)
	{
		case 0x01: // range
		{
			id rmin = [self dataToValue: [data subdataWithRange: NSMakeRange(5+2*valueLength+1, valueLength)] ofType: dataType];
			id rmax = [self dataToValue: [data subdataWithRange: NSMakeRange(5+3*valueLength+1, valueLength)] ofType: dataType];
			id rstep = [self dataToValue: [data subdataWithRange: NSMakeRange(5+4*valueLength+1, valueLength)] ofType: dataType];
			
			form = @{@"min" : rmin, @"max" : rmax, @"step" : rstep};
			break;
		}
		case 0x02: // enum
		{
			uint16_t enumCount = 0;
			[data getBytes: &enumCount range: NSMakeRange(5+2*valueLength+1, sizeof(enumCount))];

			NSMutableArray* enumValues = [NSMutableArray arrayWithCapacity: enumCount];
			for (size_t i = 0; i < enumCount; ++i)
			{
				[enumValues addObject: [self dataToValue: [data subdataWithRange: NSMakeRange(5+2*valueLength+3+i*valueLength, valueLength)] ofType: dataType]];
			}
			form = enumValues;
			break;
		}
	}
	
//	NSLog(@"0x%04X is %@ in %@", property, value, form);
	
	NSDictionary* info = @{@"value" : value, @"range" : form, @"rw": @(rw)};
	
	@synchronized (self) {
		NSMutableDictionary* dict = self.ptpPropertyInfos.mutableCopy;
		dict[@(property)] = info;
		self.ptpPropertyInfos = dict;
	}
	
	[self.delegate receivedCameraProperty: info withId: @(property) fromCamera: self];

	
}

- (void) parsePtpPropertyValue: (NSData*) data
{
	// returns raw property value
}


- (NSString*) parsePtpString: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	if (data.length < 2)
		return @"";
	
	uint8_t len = 0;
	[data getBytes: &len range: NSMakeRange(0, 1)];
		
	if (1+len*2 > data.length) // length header encodes number of 2byte chars
	{
		PtpWebcamShowCatastrophicAlert(@"-parsePtpString:remainingData: expected data length (%u) exceeds actual remaining data length (%zu).", 1+len*2, data.length);
		return nil;
	}

	
	
	NSData* charData = [data subdataWithRange: NSMakeRange(1, 2*len)];
	
	// UCS-2 == UTF16?
	NSString* string = [NSString stringWithCharacters: charData.bytes length: len];
	
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( 1 + 2*len, data.length - 1 - 2*len)];
	}
	
	return string;
}

- (NSArray*) parsePtpUint16Array: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	if (data.length < 4)
		return @[];
	
	uint32_t len = 0;
	[data getBytes: &len range: NSMakeRange(0, 4)];
	
	NSMutableArray* array = [NSMutableArray arrayWithCapacity: len];
	
	for (size_t i = 0; i < len; ++i)
	{
		uint16_t val = 0;
		[data getBytes: &val range: NSMakeRange(4+2*i, 2)];
		
		[array addObject: @(val)];
	}
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( 4 + 2*len, data.length - 4 - 2*len)];
	}
	
	return array;
}

- (void) parsePtpDeviceInfoResponse: (NSData*) eventData
{
	NSMutableDictionary* ptpDeviceInfo = [NSMutableDictionary dictionary];
	
	// everything little endian
	uint16_t standardVersion = 0;
	[eventData getBytes: &standardVersion range: NSMakeRange(0, 2)];
	uint16_t vendorExtensionId = 0;
	[eventData getBytes: &vendorExtensionId range: NSMakeRange(2, 4)];
	uint16_t vendorExtensionVersion = 0;
	[eventData getBytes: &vendorExtensionVersion range: NSMakeRange(6, 2)];
	
	ptpDeviceInfo[@"standardVersion"] = @(standardVersion);
	ptpDeviceInfo[@"vendorExtensionId"] = @(vendorExtensionId);
	ptpDeviceInfo[@"vendorExtensionVersion"] = @(vendorExtensionVersion);
	
	NSData* stringData = [eventData subdataWithRange: NSMakeRange( 8, eventData.length - 8)];
	NSData* moreData = nil;
	NSString* vendorDesc = [self parsePtpString: stringData remainingData: &moreData];
	
	ptpDeviceInfo[@"vendorDescription"] = vendorDesc;
	
	//	NSLog(@"  vers = 0x%04X ex = 0x%08X, exver = 0x%04X, len = %lu", standardVersion, vendorExtensionId, vendorExtensionVersion, eventData.length);
	//
	//	NSLog(@"  desc = %@", vendorDesc);
	
	uint16_t functionalMode = 0;
	[moreData getBytes: &functionalMode range: NSMakeRange(0, 2)];
	//	NSLog(@"  functionalMode = %u", functionalMode);
	
	ptpDeviceInfo[@"functionalMode"] = @(functionalMode);
	
	NSArray* opsSupported = [self parsePtpUint16Array: [moreData subdataWithRange: NSMakeRange( 2, moreData.length - 2)] remainingData: &moreData];
	//	NSLog(@"  ops = %@", opsSupported);
	
	// check for hard-coded operations and add them to property list
	if (_ptpNonAdvertisedOperations[@(self.icCamera.usbVendorID)])
	{
		NSDictionary* vendorOpsTable = _ptpNonAdvertisedOperations[@(self.icCamera.usbVendorID)];
		if (vendorOpsTable[@(self.icCamera.usbProductID)])
		{
			opsSupported = [opsSupported arrayByAddingObjectsFromArray: vendorOpsTable[@(self.icCamera.usbProductID)]];
		}
	}
	
	ptpDeviceInfo[@"operations"] = opsSupported;
	
//	for (id prop in opsSupported)
//		NSLog(@"supports operation  0x%04X", [prop intValue]);

	NSArray* eventsSupported = [self parsePtpUint16Array: moreData remainingData: &moreData];
	//	NSLog(@"  events = %@", eventsSupported);
	
	ptpDeviceInfo[@"events"] = eventsSupported;
	
	
	NSArray* propsSupported = [self parsePtpUint16Array: moreData remainingData: &moreData];
	//	NSLog(@"  props = %@", propsSupported);
	
	ptpDeviceInfo[@"properties"] = propsSupported;
	
//	for (id prop in propsSupported)
//		NSLog(@"supports property  0x%04X", [prop intValue]);
	
	NSArray* captureFormats = [self parsePtpUint16Array: moreData remainingData: &moreData];
	//	NSLog(@"  capture = %@", captureFormats);
	
	ptpDeviceInfo[@"captureFormats"] = captureFormats;
	
	NSArray* imageFormats = [self parsePtpUint16Array: moreData remainingData: &moreData];
	//	NSLog(@"  img = %@", imageFormats);
	
	ptpDeviceInfo[@"imageFormats"] = imageFormats;
	
	NSString* mfg = [self parsePtpString: moreData remainingData: &moreData];
	
	ptpDeviceInfo[@"manufacturer"] = mfg;
	
	//	NSLog(@"  mfg = %@", mfg);
	
	// optional properties
	if (moreData.length)
	{
		NSString* model = [self parsePtpString: moreData remainingData: &moreData];
		ptpDeviceInfo[@"model"] = model;
		
		//		NSLog(@"  model = %@", model);
	}
	
	if (moreData.length)
	{
		NSString* deviceVersion = [self parsePtpString: moreData remainingData: &moreData];
		ptpDeviceInfo[@"deviceVersion"] = deviceVersion;
		
		//		NSLog(@"  deviceVers = %@", deviceVersion);
	}
	
	if (moreData.length)
	{
		NSString* serno = [self parsePtpString: moreData remainingData: &moreData];
		ptpDeviceInfo[@"serialNumber"] = serno;
		
		//		NSLog(@"  serno = %@", serno);
	}
	
	//	NSLog(@"  more = %@", moreData);
	
	self.ptpDeviceInfo = ptpDeviceInfo;
	
	// get device properties
	for (NSNumber* prop in ptpDeviceInfo[@"properties"])
	{
		[self ptpGetPropertyDescription: [prop unsignedIntValue]];
	}
	// The Nikon LiveView properties are not returned as device properties, but are still there
	if ([self isPtpOperationSupported: PTP_CMD_NIKON_GETVENDORPROPS])
	{
		[self requestSendPtpCommandWithCode: PTP_CMD_NIKON_GETVENDORPROPS];
	}
	else
	{
		// if no further information has to be determined, we're ready to talk to the DAL plugin
		[self cameraDidBecomeReadyForUse];
	}

//	[self ptpGetPropertyDescription: PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW];
//	[self ptpGetPropertyDescription: PTP_PROP_NIKON_LV_STATUS];

	// MTP GetObjectPropsSupported requires a format code to be specified
//	if ([self isPtpOperationSupported: MTP_CMD_GETOBJECTPROPSSUPPORTED])
//		[self requestSendPtpCommandWithCode: MTP_CMD_GETOBJECTPROPSSUPPORTED];

//	if ([ptpDeviceInfo[@"operations"] containsObject: @(MTP_CMD_GETOBJECTPROPSSUPPORTED)])
//	{
//		[self querySupportedMtpProperties];
//	}
	
}

- (void) requestSendPtpCommandWithCode: (int) code
{
	NSData* command = [self ptpCommandWithType: PTP_TYPE_COMMAND code: code transactionId: [self nextTransactionId]];
	
	[self.icCamera requestSendPTPCommand: command
									 outData: nil
						 sendCommandDelegate: self
					  didSendCommandSelector: @selector(didSendPTPCommand:inData:response:error:contextInfo:)
								 contextInfo: NULL];
}

- (void) ptpQueryKnownDeviceProperties
{
	for (NSNumber* prop in self.ptpPropertyInfos.allKeys)
	{
		[self ptpGetPropertyDescription: [prop unsignedIntValue]];
	}

}

- (BOOL) isPtpOperationSupported: (uint16_t) opId
{
	return [self.ptpDeviceInfo[@"operations"] containsObject: @(opId)];
}

- (BOOL) isPtpPropertySupported: (uint16_t) opId
{
	return [self.ptpDeviceInfo[@"properties"] containsObject: @(opId)];
}


- (uint32_t) nextTransactionId
{
	@synchronized (self) {
		return ++transactionId;
	}
}

- (void) startLiveView
{
	PtpLog(@"");
	[self requestSendPtpCommandWithCode: PTP_CMD_STARTLIVEVIEW];
	
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

- (void) cameraDidBecomeReadyForLiveViewStreaming
{
	videoActivityToken = [[NSProcessInfo processInfo] beginActivityWithOptions: (NSActivityLatencyCritical | NSActivityUserInitiated) reason: @"Live Video"];
	
	inLiveView = YES;
	
	[self.delegate cameraDidBecomeReadyForLiveViewStreaming: self];
	[self ptpQueryKnownDeviceProperties];
	
	[self requestLiveViewImage];
	
	if (frameTimerSource)
		dispatch_resume(frameTimerSource);

}

- (void) cameraDidBecomeReadyForUse
{
	[self.delegate cameraDidBecomeReadyForUse: self];

}


- (void) stopLiveView
{
	PtpLog(@"");
	[self requestSendPtpCommandWithCode: PTP_CMD_STOPLIVEVIEW];
	if (frameTimerSource)
		dispatch_suspend(frameTimerSource);
	inLiveView = NO;
	
	[[NSProcessInfo processInfo] endActivity: videoActivityToken];
	videoActivityToken = nil;
}

- (void) requestLiveViewImage
{
	[self requestSendPtpCommandWithCode: PTP_CMD_GETLIVEVIEWIMG];
}
@end

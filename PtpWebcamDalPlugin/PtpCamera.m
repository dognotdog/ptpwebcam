//
//  PtpCamera.m
//  PtpWebcamAssistantService
//
//  Created by Dömötör Gulyás on 25.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpCamera.h"
#import "PtpCameraNikon.h"
#import "PtpCameraCanon.h"
#import "PtpCameraSony.h"
#import "FoundationExtensions.h"

#import <ImageCaptureCore/ImageCaptureCore.h>

#import "../PtpWebcamAssistantService/PtpWebcamAssistantService.h"
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
}

static NSDictionary* _supportedCameras = nil;
static NSDictionary* _confirmedCameras = nil;

static NSDictionary* _ptpOperationNames = nil;
static NSDictionary* _ptpPropertyNames = nil;
static NSDictionary* _ptpPropertyValueNames = nil;

static NSDictionary* _ptpNonAdvertisedOperations = nil;

static NSDictionary* _liveViewJpegDataOffsets = nil;

+ (void)initialize
{
	if (self == [PtpCamera self])
	{
		// just send a message to the class to trigger its initialization, and with it registering its supported vendorId/productId combos
		[PtpCameraNikon class];
		[PtpCameraCanon class];
		[PtpCameraSony class];

		_confirmedCameras = @{
			// Canon
			@(0x04A9) : @{
				@(0x3250) : @(YES), // 6D
			},
			// Nikon
			@(0x04B0) : @{
//				@(0x0410) : @[@"Nikon", @"D200"],
//				@(0x041A) : @[@"Nikon", @"D300"],
				@(0x041C) : @(YES), // D3
//				@(0x0420) : @[@"Nikon", @"D3X"],
				@(0x0421) : @(YES), // D90
//				@(0x0422) : @[@"Nikon", @"D700"],
//				@(0x0423) : @[@"Nikon", @"D5000"],
//				@(0x0424) : @[@"Nikon", @"D3000"],
//				@(0x0425) : @[@"Nikon", @"D300S"],
//				@(0x0426) : @[@"Nikon", @"D3S"],
				@(0x0428) : @(YES), // D7000
				@(0x0429) : @(YES), // D5100
				@(0x042A) : @(YES), // D800
//				@(0x042B) : @[@"Nikon", @"D4"],
				@(0x042C) : @(YES), // D3200
				@(0x042D) : @(YES), // D600
//				@(0x042E) : @[@"Nikon", @"D800E"],
				@(0x042F) : @(YES), // D5200
				@(0x0430) : @(YES), // D7100
//				@(0x0431) : @[@"Nikon", @"D5300"],
//				@(0x0432) : @[@"Nikon", @"Df"],
				@(0x0433) : @(YES), // D3300
//				@(0x0434) : @[@"Nikon", @"D610"],
//				@(0x0435) : @[@"Nikon", @"D4S"],
//				@(0x0436) : @[@"Nikon", @"D810"],
				@(0x0437) : @(YES), // D750
				@(0x0438) : @(YES), // D5500
				@(0x0439) : @(YES), // D7200
//				@(0x043A) : @[@"Nikon", @"D5"],
//				@(0x043B) : @[@"Nikon", @"D810A"],
//				@(0x043C) : @[@"Nikon", @"D500"],
				@(0x043D) : @(YES), // D3400
				@(0x043F) : @(YES), // D5600
				@(0x0440) : @(YES), // D7500
//				@(0x0441) : @[@"Nikon", @"D850"],
				@(0x0442) : @(YES), // Z7
				@(0x0443) : @(YES), // Z6
				@(0x0444) : @(YES), // Z50
				@(0x0445) : @(YES), // D3500
//				@(0x0446) : @[@"Nikon", @"D780"],
//				@(0x0447) : @[@"Nikon", @"D6"],
//				@(0x0448) : @(YES), // Z5
//				@(0x044B) : @(YES), // Z7ii
//				@(0x044C) : @(YES), // Z6ii
//				@(0x044F) : @(YES), // Zfc?
//				@(0x0450) : @(YES), // Z9
				@(0x0451) : @(YES), // Z8
//				@(0x0452) : @(YES), // Z30
			},
			// Sony
			@(0x054C) : @{
				@(0x0954) : @(YES), // A7S
			},
		};

		_ptpNonAdvertisedOperations = @{
			@(0x04B0) : @{
				// TODO: it looks as though the D3200 and newer in the series not advertise everything they can do, confirm that this is actually the case
				@(0x042C) : @[@(PTP_CMD_NIKON_STARTLIVEVIEW), @(PTP_CMD_NIKON_STOPLIVEVIEW), @(PTP_CMD_NIKON_GETLIVEVIEWIMG)], // D3200
				@(0x0433) : @[@(PTP_CMD_NIKON_GETVENDORPROPS), @(PTP_CMD_NIKON_STARTLIVEVIEW), @(PTP_CMD_NIKON_STOPLIVEVIEW), @(PTP_CMD_NIKON_GETLIVEVIEWIMG)], // D3300
				// verified that this is not needed for the D3400, as its response to the operations supported contains these operations
//				@(0x043D) : @[@(PTP_CMD_NIKON_GETVENDORPROPS), @(PTP_CMD_NIKON_STARTLIVEVIEW), @(PTP_CMD_NIKON_STOPLIVEVIEW), @(PTP_CMD_NIKON_GETLIVEVIEWIMG)], // D3400
				@(0x0445) : @[@(PTP_CMD_NIKON_GETVENDORPROPS), @(PTP_CMD_NIKON_STARTLIVEVIEW), @(PTP_CMD_NIKON_STOPLIVEVIEW), @(PTP_CMD_NIKON_GETLIVEVIEWIMG)], // D3500
//				@(0x0451) : @[@(PTP_CMD_NIKON_GETVENDORPROPS)], // Z8
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
				@(0x0448) : @(384), // Z5
				@(0x044B) : @(384), // Z7ii
				@(0x044C) : @(384), // Z6ii
				@(0x044F) : @(384), // Zfc?
				@(0x0450) : @(384), // Z9
				@(0x0451) : @(384), // Z8
			},
		};

	}
}

+ (void) registerSupportedCameras: (NSDictionary*) supportedCamerasIn byClass: (Class) aClass
{
	NSMutableDictionary* supportedCameras = [NSMutableDictionary dictionaryWithCapacity: supportedCamerasIn.count];
	for (id vendorId in supportedCamerasIn)
	{
		NSDictionary* vendorDictIn = supportedCamerasIn[vendorId];
		NSMutableDictionary* vendorDict = [NSMutableDictionary dictionaryWithCapacity: vendorDictIn.count];
		
		for (id productId in vendorDictIn)
		{
			NSArray* productInfoIn = vendorDictIn[productId];
			NSDictionary* productInfo = @{
				@"make" : productInfoIn[0],
				@"model" : productInfoIn[1],
				@"Class" : aClass,
			};
			vendorDict[productId] = productInfo;
		}
		supportedCameras[vendorId] = vendorDict;
	}

	
	@synchronized (self)
	{
		if (!_supportedCameras)
			_supportedCameras = @{};
		
		_supportedCameras = [self mergePropertyValueDictionary: _supportedCameras withDictionary: supportedCameras];
	}
}

+ (nullable NSDictionary*) isDeviceSupported: (ICDevice*) device
{
	
	uint16_t vendorId = device.usbVendorID;
	uint16_t productId = device.usbProductID;

	NSDictionary* modelDict = _supportedCameras[@(vendorId)];
	if (!modelDict)
		return nil;
	NSMutableDictionary* cameraInfo = [modelDict[@(productId)] mutableCopy];
	if (!cameraInfo)
		return nil;
	
	NSDictionary* confirmedModelDict = _confirmedCameras[@(vendorId)];
	NSNumber* confirmedCameraInfo = confirmedModelDict[@(productId)];

	cameraInfo[@"confirmed"] = @([confirmedCameraInfo boolValue]);
	
	return cameraInfo;
}


+ (NSDictionary*) mergePropertyValueDictionary: (NSDictionary*) dict0 withDictionary: (NSDictionary*) dict1
{
	NSSet* keys0 = [NSSet setWithArray: dict0.allKeys];
	NSSet* keys1 = [NSSet setWithArray: dict1.allKeys];
	NSSet* keys = [keys0 setByAddingObjectsFromSet: keys1];
	NSMutableDictionary* dict = [NSMutableDictionary dictionaryWithCapacity: keys.count];
	for (id key in keys)
	{
		NSDictionary* prop0 = dict0[key];
		NSDictionary* prop1 = dict1[key];
		
		if (prop0 && prop1)
		{
			NSMutableDictionary* combinedProp = prop0.mutableCopy;
			[combinedProp addEntriesFromDictionary: prop1];
			dict[key] = combinedProp;
		}
		else if (prop0)
		{
			dict[key] = prop0;
		}
		else
		{
			dict[key] = prop1;
		}
	}
	return dict;
}


+ (NSDictionary*) ptpStandardPropertyValueNames
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_ptpPropertyValueNames = @{
			@(PTP_PROP_EXPOSUREPM) : @{
				@(0x0000) : @"Undefined",
				@(0x0001) : @"Manual",
				@(0x0002) : @"Automatic",
				@(0x0003) : @"Aperture Priority",
				@(0x0004) : @"Shutter Priority",
				@(0x0005) : @"Creative",
				@(0x0006) : @"Action",
				@(0x0007) : @"Portrait",
			},
			@(PTP_PROP_FOCUSMODE) : @{
				@(0x0000) : @"Undefined",
				@(0x0001) : @"Manual",
				@(0x0002) : @"Auto",
				@(0x0003) : @"Auto Macro",
			},
			@(PTP_PROP_EXPOSUREMETERING) : @{
				@(0x0000) : @"Undefined",
				@(0x0001) : @"Average",
				@(0x0002) : @"Center-weighted",
				@(0x0003) : @"Multi-spot",
				@(0x0004) : @"Center-spot",
			},
			@(PTP_PROP_WHITEBALANCE) :  @{
				@(0x0000) : @"Undefined",
				@(0x0001) : @"Manual",
				@(0x0002) : @"Automatic",
				@(0x0003) : @"One-Push Automatic",
				@(0x0004) : @"Sunny",
				@(0x0005) : @"Flourescent",
				@(0x0006) : @"Tungsten",
				@(0x0007) : @"Flash",
			},
		};
	});
	return _ptpPropertyValueNames;
}

+ (NSDictionary*) ptpStandardOperationNames
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_ptpOperationNames = @{
			@(PTP_CMD_GETDEVICEINFO) : @"PTP Get Device Info",
			@(0x1002) : @"PTP Open Session",
			@(0x1003) : @"PTP Close Session",
			@(0x1004) : @"PTP Get Storage IDs",
			@(0x1005) : @"PTP Get Storage Info",
			@(PTP_CMD_GETNUMOBJECTS) : @"PTP Get Number of Objects",
			@(PTP_CMD_GETOBJECTHANDLES) : @"PTP Get Object Handles",
			@(PTP_CMD_GETOBJECTINFO) : @"PTP Get Object Info",
			@(PTP_CMD_GETOBJECT) : @"PTP Get Object",
			@(0x100A) : @"PTP Get Thumb",
			@(0x100B) : @"PTP Delete Object",
			@(PTP_CMD_GETPROPDESC) : @"PTP Get Property Description",
			@(PTP_CMD_GETPROPVAL) : @"PTP Get Property Value",
			@(PTP_CMD_SETPROPVAL) : @"PTP Set Property Value",
			@(0x101B) : @"PTP Get Partial Object",
		};
	});
	return _ptpOperationNames;
}


+ (NSDictionary*) ptpStandardPropertyNames
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_ptpPropertyNames = @{
			@(PTP_PROP_BATTERYLEVEL) : @"Battery Level",
			@(PTP_PROP_IMAGEQUALITY) : @"Image Quality",
			@(PTP_PROP_WHITEBALANCE) : @"White Balance",
			@(PTP_PROP_FNUM) : @"Aperture",
			@(PTP_PROP_FLEN) : @"Focal Length",
			@(PTP_PROP_FOCUSDISTANCE) : @"Focus Distance",
			@(PTP_PROP_FOCUSMODE) : @"Focus Mode",
			@(PTP_PROP_EXPOSUREMETERING) : @"Exposure Metering",
			@(PTP_PROP_EXPOSUREISO) : @"ISO",
			@(PTP_PROP_EXPOSUREBIAS) : @"Exposure Correction",
			@(PTP_PROP_EXPOSURETIME) : @"Exposure Time",
			@(PTP_PROP_EXPOSUREPM) : @"Exposure Program Mode",
		};
	});
	return _ptpPropertyNames;
}

- (NSDictionary*) ptpOperationNames
{
	return [PtpCamera ptpStandardOperationNames];
}

- (NSDictionary*) ptpPropertyNames
{
	return [PtpCamera ptpStandardPropertyNames];
}

- (NSDictionary*) ptpPropertyValueNames
{
	return [PtpCamera ptpStandardPropertyValueNames];
}

+ (instancetype) cameraWithIcCamera: (ICCameraDevice*) camera delegate: (id <PtpCameraDelegate>) delegate
{
	NSDictionary* cameraInfo = [[self class] isDeviceSupported: camera];

	if (!cameraInfo)
	{
		NSLog(@"Camera is not supported: %@", camera);
		return nil;
	}
	
	Class cameraClass = cameraInfo[@"Class"];
	
	return [[cameraClass alloc] initWithIcCamera: camera delegate: delegate cameraInfo: cameraInfo];
	
}

- (instancetype) initWithIcCamera: (ICCameraDevice*) camera delegate: (id <PtpCameraDelegate>) delegate cameraInfo: (NSDictionary*) cameraInfo
{
	if (!(self = [super init]))
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

	self.uiPtpProperties = @[
		@(PTP_PROP_BATTERYLEVEL),
//		@(PTP_PROP_FOCUSDISTANCE),
		@(PTP_PROP_FLEN),
		@(PTP_PROP_EXPOSUREPM),
		@(PTP_PROP_FNUM),
		@(PTP_PROP_EXPOSUREISO),
		@(PTP_PROP_EXPOSURETIME),
		@(PTP_PROP_WHITEBALANCE),
		@(PTP_PROP_EXPOSUREBIAS),
	];
	
	NSDictionary* liveViewJpegOffsetsMake = _liveViewJpegDataOffsets[@(camera.usbVendorID)];
	self.liveViewHeaderLength = [liveViewJpegOffsetsMake[@(camera.usbProductID)] unsignedIntegerValue];

	self.delegate = delegate;
	self.icCamera = camera;
	self.make = cameraInfo[@"make"];
	self.model = cameraInfo[@"model"];
	self.cameraId = [NSString stringWithFormat: @"ptpwebcam-%@-%@-%@", self.make, self.model, camera.serialNumberString];
	self.ptpPropertyInfos = @{};
	
//	PtpLog(@"initialized camera with ID %@", self.cameraId);
	
	camera.delegate = self;
	
	[camera requestEnableTethering];
	
	[self requestSendPtpCommandWithCode: PTP_CMD_GETDEVICEINFO];
	
	return self;

}

- (NSArray*) currentUiPtpProperties
{
	return self.uiPtpProperties;
}

- (BOOL) isUiChangingProperty: (NSNumber*) propertyId {
	return NO;
}

- (void) dealloc
{
	if (frameTimerSource)
		dispatch_source_cancel(frameTimerSource);
}

- (void) startFrameTimer
{
	if (frameTimerSource)
		return;
	
	
	dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);

	frameQueue = dispatch_queue_create("PtpWebcamStreamFrameQueue", queueAttributes);

	frameTimerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, frameQueue);
	dispatch_source_set_timer(frameTimerSource, DISPATCH_TIME_NOW, 1.0/WEBCAM_STREAM_FPS*NSEC_PER_SEC, 1000u*NSEC_PER_SEC);

	__weak id weakSelf = self;
	dispatch_source_set_event_handler(frameTimerSource, ^{
		[weakSelf requestLiveViewImage];
	});
	
	dispatch_resume(frameTimerSource);

}

- (void) deviceDidBecomeReadyWithCompleteContentCatalog:(ICCameraDevice *)device
{
	NSLog(@"deviceDidBecomeReadyWithCompleteContentCatalog %@", device);
}

- (void)cameraDevice:(nonnull ICCameraDevice *)camera didAddItems:(nonnull NSArray<ICCameraItem *> *)items
{
}

- (NSDictionary*) decodePtpEvent: (nonnull NSData *)eventData
{
	NSMutableDictionary* info = [NSMutableDictionary dictionary];
	uint32_t len = 0;
	[eventData getBytes: &len range: NSMakeRange(0, sizeof(len))];
	info[@"length"] = @(len);
	
	uint16_t type = 0;
	[eventData getBytes: &type range: NSMakeRange(4, sizeof(type))];
	info[@"type"] = @(type);
	
	uint16_t code = 0;
	[eventData getBytes: &code range: NSMakeRange(6, sizeof(code))];
	info[@"eventId"] = @(code);
	
	uint32_t transactionId = 0;
	[eventData getBytes: &transactionId range: NSMakeRange(8, sizeof(transactionId))];
	info[@"transactionid"] = @(transactionId);
	
	NSData* eventPayload = [eventData subdataWithRange: NSMakeRange( 12, eventData.length-12)];
	info[@"data"] = eventPayload;
	
	return info;
	
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

- (void) cameraDevice:(ICCameraDevice *)camera didReceiveThumbnail:(CGImageRef _Nullable)thumbnail forItem:(nonnull ICCameraItem *)item error:(NSError * _Nullable)error
{
	
}
- (void) cameraDevice:(ICCameraDevice *)camera didReceiveMetadata:(NSDictionary * _Nullable)metadata forItem:(nonnull ICCameraItem *)item error:(NSError * _Nullable)error
{
	
}

- (void) device:(ICDevice *)device didOpenSessionWithError:(NSError *)error
{
	NSLog(@"-device:didOpenSessionWithError");
	if (error)
		NSLog(@"PTP Webcam could not open ddevice session because %@", error);
	
}

- (void)device:(ICDevice *)device didCloseSessionWithError:(NSError *)error
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
	if (paramData)
		[data appendData: paramData];
	
	return data;
}

- (NSData*) ptpCommandWithType: (uint16_t) type code: (uint16_t) code transactionId: (uint32_t) transId
{
	return [self ptpCommandWithType: type code: code transactionId: transId parameters: nil];
}

- (void) ptpGetPropertyDescription: (uint32_t) property
{
	[self requestSendPtpCommandWithCode: PTP_CMD_GETPROPDESC parameters:@[@(property)]];
}

- (void) ptpGetPropertyValue: (uint32_t) property
{
	NSMutableData* data = [NSMutableData data];
	[data appendBytes: &property length: 4];

	NSData* command = [self ptpCommandWithType: PTP_TYPE_COMMAND code: PTP_CMD_GETPROPVAL transactionId: [self nextTransactionId] parameters: data];
	
	[self sendPtpCommand: command];
}

- (NSData*) ptpDataFromArray: (NSArray*) values ofType: (int) dataType
{
	NSMutableData* data = [NSMutableData data];
	size_t count = values.count;
	if (count > UINT32_MAX)
	{
		PtpWebcamShowCatastrophicAlert(@"Attempted to set property to an array with length %lu, but max is %u.", count, UINT32_MAX);
		return nil;
	}
	uint32_t len = (uint32_t) count;
	[data appendBytes: &len length: sizeof(len)];

	switch(dataType)
	{
		case PTP_DATATYPE_SINT8_ARRAY:
		{
			for (NSNumber* num in values)
			{
				int8_t val = [num charValue];
				[data appendBytes: &val length: sizeof(val)];
			}
			break;
		}
		case PTP_DATATYPE_UINT8_ARRAY:
		{
			for (NSNumber* num in values)
			{
				uint8_t val = [num unsignedCharValue];
				[data appendBytes: &val length: sizeof(val)];
			}
			break;
		}
		case PTP_DATATYPE_SINT16_ARRAY:
		{
			for (NSNumber* num in values)
			{
				int16_t val = [num shortValue];
				[data appendBytes: &val length: sizeof(val)];
			}
			break;
		}
		case PTP_DATATYPE_UINT16_ARRAY:
		{
			for (NSNumber* num in values)
			{
				uint16_t val = [num unsignedShortValue];
				[data appendBytes: &val length: sizeof(val)];
			}
			break;
		}
		case PTP_DATATYPE_SINT32_ARRAY:
		{
			for (NSNumber* num in values)
			{
				int32_t val = [num intValue];
				[data appendBytes: &val length: sizeof(val)];
			}
			break;
		}
		case PTP_DATATYPE_UINT32_ARRAY:
		{
			for (NSNumber* num in values)
			{
				uint32_t val = [num unsignedIntValue];
				[data appendBytes: &val length: sizeof(val)];
			}
			break;
		}
		case PTP_DATATYPE_SINT64_ARRAY:
		{
			for (NSNumber* num in values)
			{
				int64_t val = [num longLongValue];
				[data appendBytes: &val length: sizeof(val)];
			}
			break;
		}
		case PTP_DATATYPE_UINT64_ARRAY:
		{
			for (NSNumber* num in values)
			{
				uint64_t val = [num unsignedLongLongValue];
				[data appendBytes: &val length: sizeof(val)];
			}
			break;
		}
	}
	
	return data;
}

- (NSData*) encodePtpDataOfType: (uint32_t) dataType fromValue: (id) value
{
	NSMutableData* data = [NSMutableData data];
	
	switch(dataType)
	{
		case PTP_DATATYPE_INVALID:
		{
			PtpWebcamShowCatastrophicAlert(@"Attempted to encode property, but data type is invalid.");
			return nil;
		}
		case PTP_DATATYPE_SINT8_RAW:
		{
			int8_t val = [value charValue];
			[data appendBytes: &val length: sizeof(val)];
			break;
		}
		case PTP_DATATYPE_UINT8_RAW:
		{
			uint8_t val = [value unsignedCharValue];
			[data appendBytes: &val length: sizeof(val)];
			break;
		}
		case PTP_DATATYPE_SINT16_RAW:
		{
			int16_t val = [value shortValue];
			[data appendBytes: &val length: sizeof(val)];
			break;
		}
		case PTP_DATATYPE_UINT16_RAW:
		{
			uint16_t val = [value unsignedShortValue];
			[data appendBytes: &val length: sizeof(val)];
			break;
		}
		case PTP_DATATYPE_SINT32_RAW:
		{
			int32_t val = [value intValue];
			[data appendBytes: &val length: sizeof(val)];
			break;
		}
		case PTP_DATATYPE_UINT32_RAW:
		{
			uint32_t val = [value unsignedIntValue];
			[data appendBytes: &val length: sizeof(val)];
			break;
		}
		case PTP_DATATYPE_SINT64_RAW:
		{
			int64_t val = [value longLongValue];
			[data appendBytes: &val length: sizeof(val)];
			break;
		}
		case PTP_DATATYPE_UINT64_RAW:
		{
			uint64_t val = [value unsignedLongLongValue];
			[data appendBytes: &val length: sizeof(val)];
			break;
		}
		case PTP_DATATYPE_SINT8_ARRAY:
		case PTP_DATATYPE_UINT8_ARRAY:
		case PTP_DATATYPE_SINT16_ARRAY:
		case PTP_DATATYPE_UINT16_ARRAY:
		case PTP_DATATYPE_SINT32_ARRAY:
		case PTP_DATATYPE_UINT32_ARRAY:
		case PTP_DATATYPE_SINT64_ARRAY:
		case PTP_DATATYPE_UINT64_ARRAY:
		{
			NSData* arrayData = [self ptpDataFromArray: value ofType: dataType];
			if (!data)
			{
				PtpWebcamShowCatastrophicAlert(@"Attempted to encode property to an array failed.");
				return nil;
			}
			
			[data appendData: arrayData];

			break;
		}
		case PTP_DATATYPE_STRING:
		{
			// 8bit length + 16bit characters
			NSString* str = value;
			NSData* stringData = [str dataUsingEncoding:NSUTF16StringEncoding];
			size_t numStringBytes = stringData.length;
			
			if (numStringBytes % 2 != 0)
			{
				PtpWebcamShowCatastrophicAlert(@"Attempted to encode property, but resulting encoded string data resulted in an uneven number of bytes, which for a UTF16 string should be impossible.");
				return nil;
			}
			if (numStringBytes/2 > 0xFF)
			{
				PtpWebcamShowCatastrophicAlert(@"Attempted to encode property to string with length %lu, but max is 255.", numStringBytes/2);
				return nil;
			}
			uint8_t len = (uint8_t)(numStringBytes/2);
			[data appendBytes: &len length: sizeof(len)];
			[data appendData: stringData];
			break;
		}
		case PTP_DATATYPE_EOS_SINT8:
		{
			int8_t val = [value charValue];
			uint8_t zeros[3] = {0,0,0};
			[data appendBytes: &val length: sizeof(val)];
			[data appendBytes: &zeros length: sizeof(zeros)];
			break;
		}
		case PTP_DATATYPE_EOS_UINT8:
		{
			uint8_t val = [value unsignedCharValue];
			uint8_t zeros[3] = {0,0,0};
			[data appendBytes: &val length: sizeof(val)];
			[data appendBytes: &zeros length: sizeof(zeros)];
			break;
		}
		case PTP_DATATYPE_EOS_SINT16:
		{
			int16_t val = [value shortValue];
			uint8_t zeros[2] = {0,0};
			[data appendBytes: &val length: sizeof(val)];
			[data appendBytes: &zeros length: sizeof(zeros)];
			break;
		}
		case PTP_DATATYPE_EOS_UINT16:
		{
			uint16_t val = [value unsignedShortValue];
			uint8_t zeros[2] = {0,0};
			[data appendBytes: &val length: sizeof(val)];
			[data appendBytes: &zeros length: sizeof(zeros)];
			break;
		}
		case PTP_DATATYPE_EOS_SINT32:
		{
			int32_t val = [value intValue];
			[data appendBytes: &val length: sizeof(val)];
			break;
		}
		case PTP_DATATYPE_EOS_UINT32:
		{
			uint32_t val = [value unsignedIntValue];
			[data appendBytes: &val length: sizeof(val)];
			break;
		}
		case PTP_DATATYPE_EOS_STRING:
		{
			// null-terminated UTF8
			NSString* str = value;
			NSMutableData* stringData = [str dataUsingEncoding:NSUTF8StringEncoding].mutableCopy;
			uint8_t terminator = 0;
			[stringData appendBytes: &terminator length: sizeof(terminator)];

			break;
		}
		default:
		{
			PtpWebcamShowCatastrophicAlert(@"Attempted to encode property, but data type (%d) unsupported", dataType);
			return nil;
		}
	}

	return data;
}

- (NSData*) encodePtpProperty: (uint32_t) propertyId fromValue: (id) value
{
	ptpDataType_t dataType = [self getPtpPropertyType: propertyId];
	NSData* encodedData = [self encodePtpDataOfType: dataType fromValue: value];
	if (!encodedData)
	{
		PtpLog(@"could not encode property 0x%04X (%@) from value %@", propertyId, self.ptpPropertyNames[@(propertyId)], value);
	}
	return encodedData;
}

- (void) ptpSetProperty: (uint32_t) property toValue: (id) value
{
	NSMutableData* paramData = [NSMutableData data];
	[paramData appendBytes: &property length: sizeof(property)];

	NSData* data = [self encodePtpProperty: property fromValue: value];

	
	NSData* command = [self ptpCommandWithType: PTP_TYPE_COMMAND code: PTP_CMD_SETPROPVAL transactionId: [self nextTransactionId] parameters: paramData];
	
	[self sendPtpCommand: command withData: data];
}

- (void) ptpIncrementProperty: (uint32_t) property by: (int) increment
{
	// override in subclasses if incremental settings are supported
	[self doesNotRecognizeSelector: _cmd];
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
		PtpLog(@"error=%@", error);
	
	uint16_t cmd = 0;
	[command getBytes: &cmd range: NSMakeRange(6, 2)];
	
	// response is
	// length (32bit)
	// type (16bit) 0x0003
	// response code (16bit)
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
				NSLog(@"ooops no data received for property description command: %@", command);
			else
				[self parsePtpPropertyDescription: data];
			break;
		case PTP_CMD_GETPROPVAL:
			[self parsePtpPropertyValue: data];
			break;
		default:
			PtpLog(@"cmd=%@, response=%@, data=%@", command, response, data);
			break;
	}
	
}

- (NSArray*) parsePtpDataArray: (NSData*) data ofType: (int) dataType remainingData: (NSData**) remainingData
{
	if (data.length < 4)
		return nil;
	
	uint32_t len = 0;
	[data getBytes: &len range: NSMakeRange(0, sizeof(len))];
	
	size_t bytesRequired = 0;
	
	size_t (^reader)(NSData* data, size_t i, id* value) = nil;

	switch (dataType)
	{
		case PTP_DATATYPE_SINT8_ARRAY:
		{
			bytesRequired = 4 + len*1;
			
			reader = ^size_t(NSData* data, size_t i, id* value){
				int8_t val = 0;
				[data getBytes: &val range: NSMakeRange(i, sizeof(val))];
				*value = @(val);
				return sizeof(val);
			};
			
			break;
		}
		case PTP_DATATYPE_UINT8_ARRAY:
		{
			bytesRequired = 4 + len*1;
			
			reader = ^size_t(NSData* data, size_t i, id* value){
				uint8_t val = 0;
				[data getBytes: &val range: NSMakeRange(i, sizeof(val))];
				*value = @(val);
				return sizeof(val);
			};
			
			break;
		}
		case PTP_DATATYPE_SINT16_ARRAY:
		{
			bytesRequired = 4 + len*2;
			
			reader = ^size_t(NSData* data, size_t i, id* value){
				int16_t val = 0;
				[data getBytes: &val range: NSMakeRange(i, sizeof(val))];
				*value = @(val);
				return sizeof(val);
			};
			
			break;
		}
		case PTP_DATATYPE_UINT16_ARRAY:
		{
			bytesRequired = 4 + len*2;
			
			reader = ^size_t(NSData* data, size_t i, id* value){
				uint16_t val = 0;
				[data getBytes: &val range: NSMakeRange(i, sizeof(val))];
				*value = @(val);
				return sizeof(val);
			};
			
			break;
		}
		case PTP_DATATYPE_SINT32_ARRAY:
		{
			bytesRequired = 4 + len*4;
			
			reader = ^size_t(NSData* data, size_t i, id* value){
				int32_t val = 0;
				[data getBytes: &val range: NSMakeRange(i, sizeof(val))];
				*value = @(val);
				return sizeof(val);
			};
			
			break;
		}
		case PTP_DATATYPE_UINT32_ARRAY:
		{
			bytesRequired = 4 + len*4;
			
			reader = ^size_t(NSData* data, size_t i, id* value){
				uint32_t val = 0;
				[data getBytes: &val range: NSMakeRange(i, sizeof(val))];
				*value = @(val);
				return sizeof(val);
			};
			
			break;
		}
		case PTP_DATATYPE_SINT64_ARRAY:
		{
			bytesRequired = 4 + len*8;
			
			reader = ^size_t(NSData* data, size_t i, id* value){
				int64_t val = 0;
				[data getBytes: &val range: NSMakeRange(i, sizeof(val))];
				*value = @(val);
				return sizeof(val);
			};
			
			break;
		}
		case PTP_DATATYPE_UINT64_ARRAY:
		{
			bytesRequired = 4 + len*8;
			
			reader = ^size_t(NSData* data, size_t i, id* value){
				uint64_t val = 0;
				[data getBytes: &val range: NSMakeRange(i, sizeof(val))];
				*value = @(val);
				return sizeof(val);
			};
			
			break;
		}
	}
	
	if (data.length < bytesRequired)
		return nil;

	if (!reader)
		return nil;

	NSMutableArray* values = [NSMutableArray arrayWithCapacity: len];
	size_t k = 4;
	for (size_t i = 0; i < len; ++i)
	{
		id value = nil;
		k += reader(data, k, &value);
		if (value)
			[values addObject: value];
	}

	if (remainingData)
		*remainingData = [data subdataWithRange: NSMakeRange(bytesRequired, data.length - bytesRequired)];

	return values;
}


- (ptpDataType_t) getPtpPropertyType:(uint32_t)propertyId
{
	NSDictionary* propertyInfo = self.ptpPropertyInfos[@(propertyId)];
	return [propertyInfo[@"dataType"] intValue];
}

- (NSArray*) parsePtpRangeEnumData: (NSData*) data ofType: (int) dataType remainingData: (NSData**) remData
{
	uint16_t enumCount = [self parsePtpUint16: data remainingData: &data].unsignedShortValue;
	
	NSMutableArray* enumValues = [NSMutableArray arrayWithCapacity: enumCount];
	for (size_t i = 0; i < enumCount; ++i)
	{
		id value = [self parsePtpItem: data ofType: dataType remainingData: &data];
		if (value)
			[enumValues addObject: value];
		else
		{
			PtpLog(@"could not parse enum value in property description with dataType: 0x%04X", dataType);
			return nil;
		}
	}
	if (remData)
		*remData = data;
	return enumValues;
}

- (void) parsePtpPropertyDescription: (NSData*) data
{
	// 16b property id
	// 16b data type code
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
	uint16_t dataType = 0;
	[data getBytes: &dataType range: NSMakeRange(2, sizeof(dataType))];
	uint8_t rw = 0;
	[data getBytes: &rw range: NSMakeRange(4, sizeof(rw))];

	// FIXME: old assertion, probably ok to remove now
//	assert((dataType < PTP_DATATYPE_ARRAY_MASK) || (dataType == PTP_DATATYPE_STRING));

	NSData* valuesData = [data subdataWithRange: NSMakeRange( 5, data.length - 5)];
	
	id defaultValue = [self parsePtpItem: valuesData ofType: dataType remainingData: &valuesData];
	if (!defaultValue)
	{
		PtpLog(@"could not parse default value in property description for property 0x%04X with dataType: 0x%04X, data: %@", property, dataType, data);
	}
	id value = [self parsePtpItem: valuesData ofType: dataType remainingData: &valuesData];
	if (!value)
	{
		PtpLog(@"could not parse current value in property description for property 0x%04X with dataType: 0x%04X, data: %@", property, dataType, data);
	}

	NSNumber* formFlag = [self parsePtpUint8: valuesData remainingData: &valuesData];

	// if we couldn't parse the values, don't continue
	if (!value || !defaultValue)
		return;
	
	
	id form = nil;
	
	switch(formFlag.unsignedIntValue)
	{
		case 0x01: // range
		{
			id rmin = [self parsePtpItem: valuesData ofType: dataType remainingData: &valuesData];
			id rmax = [self parsePtpItem: valuesData ofType: dataType remainingData: &valuesData];
			id rstep = [self parsePtpItem: valuesData ofType: dataType remainingData: &valuesData];
			
			if (!rmin)
			{
				PtpLog(@"could not parse range minimum in property description for property 0x%04X with dataType: 0x%04X, data: %@", property, dataType, data);
			}
			else if (!rmax)
			{
				PtpLog(@"could not parse range maximum in property description for property 0x%04X with dataType: 0x%04X, data: %@", property, dataType, data);
			}
			else if (!rstep)
			{
				PtpLog(@"could not parse range step in property description for property 0x%04X with dataType: 0x%04X, data: %@", property, dataType, data);
			}
			else // can only create dict without crashing if all values present
				form = @{@"min" : rmin, @"max" : rmax, @"step" : rstep};
			
			break;
		}
		case 0x02: // enum
		{
			form = [self parsePtpRangeEnumData: valuesData ofType: dataType remainingData: &valuesData];
			if (!form)
			{
				PtpLog(@"could not parse range enum in property description for property 0x%04X with dataType: 0x%04X, data: %@", property, dataType, data);

			}
			break;
		}
	}
	
//	NSLog(@"0x%04X is %@ in %@", property, value, form);
	
	NSDictionary* info = @{@"defaultValue" : defaultValue, @"value" : value, @"range" : (form ? form : @[]), @"rw": @(rw), @"dataType" : @(dataType)};
	
	NSDictionary* oldInfo = self.ptpPropertyInfos[@(property)];
	@synchronized (self) {
		self.ptpPropertyInfos = [self.ptpPropertyInfos dictionaryBySettingObject: info forKey: @(property)];
	}
	
	[self receivedProperty: info oldProperty: oldInfo withId: @(property)];

	
}

- (void) receivedProperty: (NSDictionary*) propertyInfo oldProperty: (NSDictionary*) oldInfo withId: (NSNumber*) propertyId
{
	[self.delegate receivedCameraProperty: propertyInfo oldProperty: oldInfo withId: propertyId fromCamera: self];
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

	
	
	// if string has termination, skip everything after first occurence of terminator
	uint16_t zero = 0;
	uint8_t* zeroPtr = memmem(data.bytes + 1, 2*len, &zero, sizeof(zero));
	// if zeroPtr is in the middle of a 2-byte word, we have to advance to the next character boundary
	while (zeroPtr && ((zeroPtr - (uint8_t*)(data.bytes + 1)) % 2))
	{
		size_t n = zeroPtr - (uint8_t*)(data.bytes + 1);
		zeroPtr = memmem(zeroPtr + 1, 2*len - n, &zero, sizeof(zero));
	}
	size_t numChars = zeroPtr ? (zeroPtr - (uint8_t*)(data.bytes + 1))/2 : len;
	
	NSData* charData = [data subdataWithRange: NSMakeRange(1, 2*numChars)];

	// UCS-2 == UTF16?
	NSString* string = [[NSString alloc] initWithData: charData encoding: NSUTF16LittleEndianStringEncoding];
	
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( 1 + 2*len, data.length - 1 - 2*len)];
	}
	
	return string;
}

- (NSNumber*) parsePtpUint8: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	if (data.length < 1)
		return nil;
	
	uint8_t val = 0;
	[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
		
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( sizeof(val), data.length - sizeof(val))];
	}
	
	return @(val);
}

- (NSNumber*) parsePtpSint8: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	if (data.length < 1)
		return nil;
	
	int8_t val = 0;
	[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
		
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( sizeof(val), data.length - sizeof(val))];
	}
	
	return @(val);
}

- (NSNumber*) parsePtpUint16: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	if (data.length < 1)
		return nil;
	
	uint16_t val = 0;
	[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
		
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( sizeof(val), data.length - sizeof(val))];
	}
	
	return @(val);
}

- (NSNumber*) parsePtpSint16: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	if (data.length < 1)
		return nil;
	
	int16_t val = 0;
	[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
		
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( sizeof(val), data.length - sizeof(val))];
	}
	
	return @(val);
}

- (NSNumber*) parsePtpUint32: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	if (data.length < 1)
		return nil;
	
	uint32_t val = 0;
	[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
		
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( sizeof(val), data.length - sizeof(val))];
	}
	
	return @(val);
}

- (NSNumber*) parsePtpSint32: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	if (data.length < 1)
		return nil;
	
	int32_t val = 0;
	[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
		
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( sizeof(val), data.length - sizeof(val))];
	}
	
	return @(val);
}

- (NSNumber*) parsePtpUint64: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	if (data.length < 1)
		return nil;
	
	uint64_t val = 0;
	[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
		
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( sizeof(val), data.length - sizeof(val))];
	}
	
	return @(val);
}

- (NSNumber*) parsePtpSint64: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	if (data.length < 1)
		return nil;
	
	int64_t val = 0;
	[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
		
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( sizeof(val), data.length - sizeof(val))];
	}
	
	return @(val);
}


//- (NSArray*) parsePtpUint16Array: (NSData*) data remainingData: (NSData** _Nullable) remData
//{
//	if (data.length < 4)
//		return @[];
//
//	uint32_t len = 0;
//	[data getBytes: &len range: NSMakeRange(0, 4)];
//
//	NSMutableArray* array = [NSMutableArray arrayWithCapacity: len];
//
//	for (size_t i = 0; i < len; ++i)
//	{
//		uint16_t val = 0;
//		[data getBytes: &val range: NSMakeRange(4+2*i, 2)];
//
//		[array addObject: @(val)];
//	}
//	if (remData)
//	{
//		*remData = [data subdataWithRange: NSMakeRange( 4 + 2*len, data.length - 4 - 2*len)];
//	}
//
//	return array;
//}

- (id) parsePtpItem: (NSData*) data ofType: (int) dataType remainingData: (NSData**) remData
{
	switch (dataType)
	{
		case PTP_DATATYPE_INVALID:
		{
			PtpWebcamShowCatastrophicAlertOnce(@"Could not parse PTP item because its datatype is invalid.");
			return nil;
		}
		case PTP_DATATYPE_SINT8_RAW:
		{
			return [self parsePtpSint8: data remainingData: remData];
		}
		case PTP_DATATYPE_UINT8_RAW:
		{
			return [self parsePtpUint8: data remainingData: remData];
		}
		case PTP_DATATYPE_SINT16_RAW:
		{
			return [self parsePtpSint16: data remainingData: remData];
		}
		case PTP_DATATYPE_UINT16_RAW:
		{
			return [self parsePtpUint16: data remainingData: remData];
		}
		case PTP_DATATYPE_SINT32_RAW:
		{
			return [self parsePtpSint32: data remainingData: remData];
		}
		case PTP_DATATYPE_UINT32_RAW:
		{
			return [self parsePtpUint32: data remainingData: remData];
		}
		case PTP_DATATYPE_SINT64_RAW:
		{
			return [self parsePtpSint64: data remainingData: remData];
		}
		case PTP_DATATYPE_UINT64_RAW:
		{
			return [self parsePtpUint64: data remainingData: remData];
		}
		case PTP_DATATYPE_SINT8_ARRAY:
		case PTP_DATATYPE_UINT8_ARRAY:
		case PTP_DATATYPE_SINT16_ARRAY:
		case PTP_DATATYPE_UINT16_ARRAY:
		case PTP_DATATYPE_SINT32_ARRAY:
		case PTP_DATATYPE_UINT32_ARRAY:
		case PTP_DATATYPE_SINT64_ARRAY:
		case PTP_DATATYPE_UINT64_ARRAY:
		case PTP_DATATYPE_SINT128_ARRAY:
		case PTP_DATATYPE_UINT128_ARRAY:
		{
			return [self parsePtpDataArray: data ofType: dataType remainingData: remData];
		}
		case PTP_DATATYPE_STRING:
		{
			return [self parsePtpString: data remainingData: remData];
		}
		default:
		{
			PtpWebcamShowCatastrophicAlertOnce(@"Could not parse PTP item because its datatype 0x%08X is unknown.", dataType);
			return nil;
		}
	}
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
	
	NSArray* opsSupported = [self parsePtpDataArray: [moreData subdataWithRange: NSMakeRange( 2, moreData.length - 2)] ofType: PTP_DATATYPE_UINT16_ARRAY remainingData: &moreData];

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

	NSArray* eventsSupported = [self parsePtpDataArray: moreData ofType: PTP_DATATYPE_UINT16_ARRAY remainingData: &moreData];
	//	NSLog(@"  events = %@", eventsSupported);
	
	ptpDeviceInfo[@"events"] = eventsSupported;
	
	
	NSArray* propsSupported = [self parsePtpDataArray: moreData ofType: PTP_DATATYPE_UINT16_ARRAY remainingData: &moreData];
	//	NSLog(@"  props = %@", propsSupported);
	
	ptpDeviceInfo[@"properties"] = propsSupported;
	
//	for (id prop in propsSupported)
//		NSLog(@"supports property  0x%04X", [prop intValue]);
	
	NSArray* captureFormats = [self parsePtpDataArray: moreData ofType: PTP_DATATYPE_UINT16_ARRAY remainingData: &moreData];
	//	NSLog(@"  capture = %@", captureFormats);
	
	ptpDeviceInfo[@"captureFormats"] = captureFormats;
	
	NSArray* imageFormats = [self parsePtpDataArray: moreData ofType: PTP_DATATYPE_UINT16_ARRAY remainingData: &moreData];
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
	

	// MTP GetObjectPropsSupported requires a format code to be specified
//	if ([self isPtpOperationSupported: MTP_CMD_GETOBJECTPROPSSUPPORTED])
//		[self requestSendPtpCommandWithCode: MTP_CMD_GETOBJECTPROPSSUPPORTED];

//	if ([ptpDeviceInfo[@"operations"] containsObject: @(MTP_CMD_GETOBJECTPROPSSUPPORTED)])
//	{
//		[self querySupportedMtpProperties];
//	}
	
}

- (uint32_t) requestSendPtpCommandWithCode: (int) code
{
	uint32_t transactionId = [self nextTransactionId];
	NSData* command = [self ptpCommandWithType: PTP_TYPE_COMMAND code: code transactionId: transactionId];
	
	[self.icCamera requestSendPTPCommand: command
									 outData: nil
						 sendCommandDelegate: self
					  didSendCommandSelector: @selector(didSendPTPCommand:inData:response:error:contextInfo:)
								 contextInfo: NULL];
	return transactionId;
}

- (uint32_t) requestSendPtpCommandWithCode: (int) code parameters: (NSArray*) params
{
	return [self requestSendPtpCommandWithCode: code parameters: params data: nil];
}

- (uint32_t) requestSendPtpCommandWithCode: (int) code parameters: (NSArray*) params data: (NSData*) data
{
	NSMutableData* paramData = [NSMutableData data];
	for (NSNumber* param in params)
	{
		uint32_t pval = param.unsignedIntValue;
		[paramData appendBytes: &pval length: sizeof(pval)];
	}

	uint32_t transactionId = [self nextTransactionId];
	NSData* command = [self ptpCommandWithType: PTP_TYPE_COMMAND code: code transactionId: transactionId parameters: paramData.length ? paramData : nil];
	
	[self.icCamera requestSendPTPCommand: command
									 outData: data
						 sendCommandDelegate: self
					  didSendCommandSelector: @selector(didSendPTPCommand:inData:response:error:contextInfo:)
								 contextInfo: NULL];
	return transactionId;
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

- (NSString*) formatPtpPropertyValue: (id) value ofProperty: (int) propertyId withDefaultValue: (id) defaultValue
{
	NSString* valueString = [NSString stringWithFormat:@"%@", value];
	
	switch (propertyId)
	{
		case PTP_PROP_BATTERYLEVEL:
			valueString = [NSString stringWithFormat: @"%.0f %%", [value doubleValue]];
			break;
		case PTP_PROP_FNUM:
			valueString = [NSString stringWithFormat: @"%.1f", 0.01*[value doubleValue]];
			break;
		case PTP_PROP_FOCUSDISTANCE:
			valueString = [NSString stringWithFormat: @"%.0f mm", [value doubleValue]];
			break;
		case PTP_PROP_EXPOSUREBIAS:
			valueString = [NSString stringWithFormat: @"%.3f", 0.001*[value doubleValue]];
			break;
		case PTP_PROP_FLEN:
			valueString = [NSString stringWithFormat: @"%.2f mm", 0.01*[value doubleValue]];
			break;
		case PTP_PROP_EXPOSURETIME:
		{
			double exposureTime = 0.0001*[value doubleValue];
			// FIXME: exposure times like 1/10000 vs. 1/8000 cannot be distinguished do to PTP property resolution of 0.0001s
			if (exposureTime < 1.0)
			{
				valueString = [NSString stringWithFormat: @"1/%.0f s", 1.0/exposureTime];
			}
			else
			{
				valueString = [NSString stringWithFormat: @"%.1f s", exposureTime];
			}
			break;
		}
		default:
		{
			NSDictionary* valueNames = self.ptpPropertyValueNames[@(propertyId)];
			NSString* name = [valueNames objectForKey: value];
			
			// if we have names for the property, but not this special value, show hex code
			if (!name && valueNames)
				name =  [NSString stringWithFormat:@"0x%04X", [value unsignedIntValue]];
			
			if (name)
				valueString = name;

			break;
		}
	}

	return valueString;
}


- (uint32_t) nextTransactionId
{
	@synchronized (self) {
		return ++transactionId;
	}
}

- (BOOL) startLiveView
{
	// a subclass needs to implement this
	[self doesNotRecognizeSelector: _cmd];
	return NO;
}

- (void) cameraDidBecomeReadyForLiveViewStreaming
{
	PtpLog(@"PtpCamera");

	videoActivityToken = [[NSProcessInfo processInfo] beginActivityWithOptions: (NSActivityLatencyCritical | NSActivityUserInitiated) reason: @"Live Video"];
	
	self.inLiveView = YES;
	
	
	if ([self.delegate respondsToSelector: @selector(cameraDidBecomeReadyForLiveViewStreaming:)])
		[(id <PtpCameraLiveViewDelegate>)self.delegate cameraDidBecomeReadyForLiveViewStreaming: self];
	[self ptpQueryKnownDeviceProperties];
	
	[self requestLiveViewImage];
	
	[self startFrameTimer];

}

- (void) cameraDidBecomeReadyForUse
{
	self.readyForUse = YES;
	[self.delegate cameraDidBecomeReadyForUse: self];

}


- (void) stopLiveView
{
	PtpLog(@"");
	@synchronized (self) {
		if (self.isInLiveView)
		{
			if (frameTimerSource)
				dispatch_source_cancel(frameTimerSource);
			frameTimerSource = nil;
			self.inLiveView = NO;

		}
	}
	
	[[NSProcessInfo processInfo] endActivity: videoActivityToken];
	videoActivityToken = nil;
}

- (void) liveViewInterrupted
{
	PtpLog(@"");
	@synchronized (self) {
		if (self.isInLiveView)
		{
			if (frameTimerSource)
				dispatch_source_cancel(frameTimerSource);
			frameTimerSource = nil;
			self.inLiveView = NO;
		}
	}
}

- (nullable NSData*) extractLiveViewJpegData: (NSData*) liveViewData
{
	// TODO: JPEG SOI marker might appear in other data, so just using that is not enough to reliably extract JPEG without knowing more
	// use JPEG SOI marker (0xFF 0xD8) to find image start
	const uint8_t soi[2] = {0xFF, 0xD8};
	const uint8_t eoi[2] = {0xFF, 0xD9};
	const uint8_t* buf = liveViewData.bytes;
	const uint8_t* eof = liveViewData.bytes + liveViewData.length;

	const uint8_t* soiPtr = NULL;
	while (1)
	{
		const uint8_t* start = soiPtr ? soiPtr+2 : buf;
		const uint8_t* searchResult = memmem(start, eof - start, soi, sizeof(soi));
		
		if (searchResult)
			soiPtr = searchResult;
		else
			break;
	}
	
	if (!soiPtr)
		return nil;
	
	
	size_t offs = soiPtr-buf;
	
	const uint8_t* eoiPtr =  memmem(soiPtr, eof - soiPtr, eoi, sizeof(eoi));

	if (!eoiPtr)
		return nil;
	
	size_t jpeglen = eoiPtr + 2 - soiPtr;

	return [liveViewData subdataWithRange: NSMakeRange( offs, jpeglen)];
	
}

- (BOOL) shouldRequestNewLiveViewImage
{
	@synchronized (self) {
		if (!self.isLiveViewRequestInProgress)
		{
			self.liveViewRequestInProgress = YES;
			return YES;
		}
		else
			return NO;
	}
}

- (void) liveViewImageRequested
{
	@synchronized (self) {
		self.liveViewRequestInProgress = YES;
	}
}
- (void) liveViewImageReceived
{
	@synchronized (self) {
		self.liveViewRequestInProgress = NO;
	}

}

- (void) requestLiveViewImage
{
	// override in subclass
	[self doesNotRecognizeSelector: _cmd];
}
- (NSSize) currenLiveViewImageSize
{
	// override in subclass
	[self doesNotRecognizeSelector: _cmd];
	return NSZeroSize;
}
- (NSArray*) liveViewImageSizes
{
	// override in subclass
	[self doesNotRecognizeSelector: _cmd];
	return nil;
}

- (int) canAutofocus
{
	return PTPCAM_AF_NONE;
}

- (void) performAutofocus
{
	[self doesNotRecognizeSelector: _cmd];
}


- (NSString*) cameraPropertyReport
{
	NSMutableString* report = [NSMutableString string];
	[report appendFormat:@"# PTP Webcam %@ %@ Camera Report\n\n", self.ptpDeviceInfo[@"manufacturer"], self.ptpDeviceInfo[@"model"]];

	[report appendFormat:@"PTP Version:              %@\n", self.ptpDeviceInfo[@"standardVersion"]];
	[report appendFormat:@"Vendor Extension ID:      %@\n", self.ptpDeviceInfo[@"vendorExtensionId"]];
	[report appendFormat:@"Vendor Extension Version: %@\n", self.ptpDeviceInfo[@"vendorExtensionVersion"]];
	[report appendFormat:@"Vendor Description:       %@\n", self.ptpDeviceInfo[@"vendorDescription"]];
	[report appendFormat:@"Functional Mode:          %@\n", self.ptpDeviceInfo[@"functionalMode"]];

	[report appendFormat:@"Device Version:           %@\n", self.ptpDeviceInfo[@"deviceVersion"]];

	[report appendFormat: @"\n## Supported Operations\n\n"];
	
	for (NSNumber* operationId in [self.ptpDeviceInfo[@"operations"] sortedArrayUsingSelector: @selector(compare:)])
	{
		NSString* name = self.ptpOperationNames[operationId];
		if (!name)
			name = @"?";
		
		[report appendFormat:@"- 0x%04X (%@)\n", operationId.unsignedIntValue, name];

	}
	
	[report appendFormat: @"\n## Supported Events\n\n"];
	
	for (NSNumber* eventId in [self.ptpDeviceInfo[@"events"] sortedArrayUsingSelector: @selector(compare:)])
	{
		[report appendFormat:@"- 0x%04X (?)\n", eventId.unsignedIntValue];
	}

	[report appendFormat: @"\n## Supported Properties\n\n"];
	
	NSArray* allPropertyIds = self.ptpDeviceInfo[@"properties"];

	for (NSNumber* propertyId in [allPropertyIds sortedArrayUsingSelector: @selector(compare:)])
	{
		NSString* name = self.ptpPropertyNames[propertyId];
		if (!name)
			name = @"?";
		
		[report appendFormat:@"- 0x%04X (%@):\n", propertyId.unsignedIntValue, name];
		
		NSDictionary* info = self.ptpPropertyInfos[propertyId];
		
		id value = info[@"value"];
		id defaultValue = info[@"defaultValue"];
		if ([value respondsToSelector: @selector(unsignedIntValue)])
			[report appendFormat:@"\t- value:   0x%04X (%@)\n", [value unsignedIntValue], [self formatPtpPropertyValue: value ofProperty: propertyId.intValue withDefaultValue: defaultValue]];
		else
			[report appendFormat:@"\t- value:   %@\n", [self formatPtpPropertyValue: value ofProperty: propertyId.intValue withDefaultValue: defaultValue]];
		if ([defaultValue respondsToSelector: @selector(unsignedIntValue)])
			[report appendFormat:@"\t- default: 0x%04X (%@)\n", [defaultValue unsignedIntValue], [self formatPtpPropertyValue: defaultValue ofProperty: propertyId.intValue withDefaultValue: defaultValue]];
		else
			[report appendFormat:@"\t- default: %@\n", [self formatPtpPropertyValue: defaultValue ofProperty: propertyId.intValue withDefaultValue: defaultValue]];
		
		for (NSString* key in [info.allKeys arrayByRemovingObjectsInArray: @[@"value", @"defaultValue", @"range"]])
		{
			[report appendFormat:@"\t- %@: 0x%04X\n", key, [info[key] unsignedIntValue]];

		}
//		if (info[@"flags"])
//		{
//			[report appendFormat:@"\t- flags:       0x%02X\n", [info[@"flags"] unsignedIntValue]];
//
//		}
//		if (info[@"auto_status"])
//		{
//			[report appendFormat:@"\t- auto_status: 0x%02X\n", [info[@"auto_status"] unsignedIntValue]];
//
//		}

		if ([info[@"range"] isKindOfClass: [NSArray class]])
		{
			[report appendFormat:@"\t- range (n=%zu):\n", [info[@"range"] count]];
			for (id enumVal in  info[@"range"])
			{
				if ([enumVal respondsToSelector:@selector(unsignedIntValue)])
					[report appendFormat:@"\t\t- 0x%04X (%@)\n", [enumVal unsignedIntValue], [self formatPtpPropertyValue: enumVal ofProperty: propertyId.intValue withDefaultValue: defaultValue]];
				else
					[report appendFormat:@"\t\t- %@\n", [self formatPtpPropertyValue: enumVal ofProperty: propertyId.intValue withDefaultValue: defaultValue]];

			}

		}
		else if ([info[@"range"] isKindOfClass: [NSDictionary class]])
		{
			NSDictionary* range = info[@"range"];
			id minValue = range[@"min"];
			id maxValue = range[@"max"];
			id stepValue = range[@"step"];
			[report appendFormat:@"\t- range:\n"];
			if ([minValue respondsToSelector: @selector(unsignedIntValue)])
				[report appendFormat:@"\t\t- min:  0x%04X (%@)\n", [minValue unsignedIntValue], [self formatPtpPropertyValue: minValue ofProperty: propertyId.intValue withDefaultValue: defaultValue]];
			else
				[report appendFormat:@"\t\t- min:  %@\n", [self formatPtpPropertyValue: minValue ofProperty: propertyId.intValue withDefaultValue: defaultValue]];

			if ([maxValue respondsToSelector: @selector(unsignedIntValue)])
				[report appendFormat:@"\t\t- max:  0x%04X (%@)\n", [maxValue unsignedIntValue], [self formatPtpPropertyValue: maxValue ofProperty: propertyId.intValue withDefaultValue: defaultValue]];
			else
				[report appendFormat:@"\t\t- max:  %@\n", [self formatPtpPropertyValue: maxValue ofProperty: propertyId.intValue withDefaultValue: defaultValue]];

			
			if ([stepValue respondsToSelector: @selector(unsignedIntValue)])
				[report appendFormat:@"\t\t- step: 0x%04X (%@)\n", [stepValue unsignedIntValue], [self formatPtpPropertyValue: stepValue ofProperty: propertyId.intValue withDefaultValue: defaultValue]];
			else
				[report appendFormat:@"\t\t- step: %@\n", [self formatPtpPropertyValue: stepValue ofProperty: propertyId.intValue withDefaultValue: defaultValue]];
		}


	}
	
	return report;
}

@end

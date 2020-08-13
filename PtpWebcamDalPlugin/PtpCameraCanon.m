//
//  PtpCameraCanon.m
//  PTP Webcam
//
//  Created by Dömötör Gulyás on 29.07.2020.
//  Copyright © 2020 Doemeotoer Gulyas. All rights reserved.
//

#import "PtpCameraCanon.h"
#import "PtpWebcamPtp.h"
#import "PtpWebcamAlerts.h"
#import "FoundationExtensions.h"

typedef enum {
	LV_STATUS_OFF,
	LV_STATUS_WAITING,
	LV_STATUS_ON,
	LV_STATUS_RESTART_STOPPING,
	LV_STATUS_ERROR
} liveViewStatus_t;

@implementation PtpCameraCanon
{
	liveViewStatus_t liveViewStatus;
	
	dispatch_queue_t eventPollQueue;
	dispatch_source_t eventPollTimer;
	
}

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
			@(PTP_PROP_CANON_EVF_EXPOSURE_PREVIEW) : @"Exposure Preview",
			@(PTP_PROP_CANON_EXPOSUREBIAS) : @"Exposure Correction",
			@(PTP_PROP_CANON_ISO) : @"ISO",
			@(PTP_PROP_CANON_APERTURE) : @"Aperture",
			@(PTP_PROP_CANON_LV_EYEDETECT) : @"AF Eye Detection",
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

- (instancetype) initWithIcCamera: (ICCameraDevice*) camera delegate: (id <PtpCameraDelegate>) delegate cameraInfo: (NSDictionary*) cameraInfo
{
	if (!(self = [super initWithIcCamera: camera delegate: delegate cameraInfo: cameraInfo]))
		return nil;
	
		self.uiPtpProperties = @[
			@(PTP_PROP_BATTERYLEVEL),
	//		@(PTP_PROP_FOCUSDISTANCE),
			@(PTP_PROP_FLEN),
			@"-",
			@(PTP_PROP_EXPOSUREPM),
			@(PTP_PROP_CANON_APERTURE),
			@(PTP_PROP_CANON_ISO),
			@(PTP_PROP_CANON_AUTOEXPOSURE),
			@(PTP_PROP_CANON_EXPOSURETIME),
			@(PTP_PROP_CANON_EVF_WHITEBALANCE),
			@(PTP_PROP_CANON_EXPOSUREBIAS),
			@(PTP_PROP_CANON_METERINGMODE),
//			@(PTP_PROP_CANON_EVF_ZOOM),
			@(PTP_PROP_CANON_LV_EYEDETECT),
			@(PTP_PROP_CANON_EVF_DOF_PREVIEW),
			@(PTP_PROP_CANON_EVF_EXPOSURE_PREVIEW),
		];
	
	
	dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);

	eventPollQueue = dispatch_queue_create("PtpWebcamCanonEventPollingQueue", queueAttributes);
	eventPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, eventPollQueue);
	dispatch_source_set_timer(eventPollTimer, DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC, 1 * NSEC_PER_MSEC);
	dispatch_source_set_event_handler(eventPollTimer, ^{
		[self queryCanonEvents];
	});
	dispatch_resume(eventPollTimer);

	return self;
}

- (void) didRemoveDevice:(nonnull ICDevice *)device
{
	@synchronized (self) {
		if (eventPollTimer)
		{
			dispatch_suspend(eventPollTimer);
			dispatch_source_set_event_handler(eventPollTimer, nil);
			eventPollTimer = nil;
		}
	}
	
	[super didRemoveDevice: device];
}

- (BOOL) startLiveView
{
	/*
	 1. set EVF Mode to 1
	 2. set EVF Output Device to PC
	 
	 issue KeepDeviceOn every now and then ?
	 
	 https://chome.nerpa.tech/canon-eos-cameras-principles-of-interfacing-and-library-description/
	 
	 apparently EOS cameras need to be polled for events
	 */
	
	liveViewStatus = LV_STATUS_WAITING;

	[self ptpSetProperty: PTP_PROP_CANON_EVF_MODE toValue: @(1)];
	[self ptpSetProperty: PTP_PROP_CANON_EVF_OUTPUTDEVICE toValue: @(2)];
	
	[self queryCanonEvents];
	
	return YES;
}

- (void) queryCanonEvents
{
	[self requestSendPtpCommandWithCode: PTP_CMD_CANON_GETEVENT];
}

- (void) ptpSetProperty: (uint32_t) propertyId toValue: (id) value
{
	if (propertyId < 0x9000) // not a vendor defined property, use standard mechanism
	{
		[super ptpSetProperty: propertyId toValue: value];
		return;
	}

	[self canonSetProperty: propertyId toValue: value];
	
}

- (NSData*) encodeCanonPropertyBlock: (uint32_t) propertyId fromValue: (id) value
{
	// a property block is 32bit length (including itself) + 32bit propertyId + value
	NSData* contentData = [self encodePtpProperty: propertyId fromValue: value];
	NSMutableData* data = [NSMutableData dataWithCapacity: 8 + contentData.length];
	uint32_t len = 8 + (uint32_t)contentData.length;
	[data appendBytes: &len length: sizeof(len)];
	[data appendBytes: &propertyId length: sizeof(propertyId)];
	[data appendData: contentData];

	return data;
}

- (void) canonSetProperty: (uint32_t) propertyId toValue: (id) value
{
	NSData* dataBlock = [self encodeCanonPropertyBlock: propertyId fromValue: value];
	
	
	NSData* command = [self ptpCommandWithType: PTP_TYPE_COMMAND code: PTP_CMD_CANON_SETPROPVAL_EX transactionId: [self nextTransactionId] parameters: nil];
	
	[self sendPtpCommand: command withData: dataBlock];

}

static uint32_t _canonDataTypeToPtpDataType(uint32_t canonDataType)
{
	return PTP_DATATYPE_EOS_MASK + canonDataType;
}

static uint32_t _canonDataTypeToArrayDataType(uint32_t canonDataType)
{
	// the data type logic here is:
	// the dataType corresponds to the the _RAW integer types, but it's actually an array
	// But what about strings you ask? I don't know.
	// some indication exists that this is only up to 32b types plus strings

	if (canonDataType < 7)
		return PTP_DATATYPE_ARRAY_MASK + canonDataType;
	else
		return 0;

}

- (void) canonPropertyChanged: (uint32_t) propertyId toData: (NSData*) data
{
	NSDictionary* oldInfo = nil;
	NSMutableDictionary* propertyInfo = nil;

	// ensure the property update itself is atomic
	@synchronized (self) {
		NSDictionary* oldInfo = self.ptpPropertyInfos[@(propertyId)];
		NSMutableDictionary* propertyInfo = oldInfo.mutableCopy;

		// try to guess property size if don't have a type
		if ([propertyInfo[@"dataType"] intValue] == PTP_DATATYPE_INVALID)
		{
			if (!propertyInfo)
				propertyInfo = [NSMutableDictionary dictionary];
			
			if (data.length == 4)
				propertyInfo[@"dataType"] = @(PTP_DATATYPE_EOS_UINT32);
		}
		
		if ([propertyInfo[@"dataType"] intValue] == PTP_DATATYPE_INVALID)
		{
			PtpLog(@"failed to update Canon property 0x%04X because data type could not be determined.", propertyId);
			return;
		}
		
		id value = [self parsePtpItem: data ofType: [propertyInfo[@"dataType"] intValue] remainingData: NULL];
		
		propertyInfo[@"value"] = value;
		
		self.ptpPropertyInfos = [self.ptpPropertyInfos dictionaryBySettingObject: propertyInfo forKey: @(propertyId)];

	}

	[self receivedProperty: propertyInfo oldProperty: oldInfo withId: @(propertyId)];
}

//- (id) parseCanonPropertyValue: (NSData*) data ofType: (uint32_t) dataType remainingData: (NSData** _Nullable) remainingData
//{
//
//}

- (void) parseCanonEventBlock: (NSData*) blockData ofType: (uint32_t) eventType
{
	switch (eventType)
	{
		case PTP_EVENT_CANON_PROPVALCHANGED:
		{
			// Event block is made up of:
			// 32bit propertyId
			// data
			if (blockData.length < 4)
			{
				PtpWebcamShowCatastrophicAlert(@"Canon Property Value Changed block data length %zu too short to read property type.", blockData.length);
				break;
			}
			
			uint32_t propertyId = 0;
			[blockData getBytes: &propertyId range: NSMakeRange(0, sizeof(propertyId))];

			[self canonPropertyChanged: propertyId toData: [blockData subdataWithRange: NSMakeRange( 4, blockData.length - 4)]];
			
			break;
		}
		case PTP_EVENT_CANON_AVAILLISTCHANGED:
		{
			// Event block is made up of:
			// 32bit propertyId
			// 32bit dataType
			// 32bit number of entries
			if (blockData.length < 8)
			{
				PtpWebcamShowCatastrophicAlert(@"Canon Available List Changed block data length %zu too short to read header.", blockData.length);
				break;
			}
			
			uint32_t propertyId = 0;
			[blockData getBytes: &propertyId range: NSMakeRange(0, sizeof(propertyId))];
			uint32_t dataType = 0;
			[blockData getBytes: &dataType range: NSMakeRange(4, sizeof(dataType))];
			
			uint32_t arrayType = _canonDataTypeToArrayDataType(dataType);
			
			NSArray* values = [self parsePtpItem: [blockData subdataWithRange: NSMakeRange(8, blockData.length - 8)] ofType: arrayType remainingData: nil];
			
			@synchronized (self) {
				NSMutableDictionary* info = [self.ptpPropertyInfos[@(propertyId)] mutableCopy];
				if (!info)
					info = [NSMutableDictionary dictionary];
				info[@"range"] = values;
				info[@"dataType"] = @(_canonDataTypeToPtpDataType(dataType));
				self.ptpPropertyInfos = [self.ptpPropertyInfos dictionaryBySettingObject: info forKey: @(propertyId)];
			}
			

			break;
		}
	}
}

- (void) parseCanonGetEventResponse: (NSData*) eventData
{
	// canon events are made up of canon blocks with [size, type, data]
	while (eventData.length >= 8)
	{
		uint32_t len = 0;
		[eventData getBytes: &len range: NSMakeRange(0, sizeof(len))];
		uint32_t type = 0;
		[eventData getBytes: &type range: NSMakeRange(4, sizeof(type))];
		
		if (eventData.length < len)
		{
			break;
		}
		
		NSData* blockData = [eventData subdataWithRange: NSMakeRange(8, len-8)];

		[self parseCanonEventBlock: blockData ofType: type];
		
		eventData = [eventData subdataWithRange: NSMakeRange(len, eventData.length - len)];
	}
}

- (void)didSendPTPCommand:(NSData*)command inData:(NSData*)data response:(NSData*)response error:(NSError*)error contextInfo:(void*)contextInfo
{
	uint16_t cmd = 0;
	[command getBytes: &cmd range: NSMakeRange(6, 2)];

	switch (cmd)
	{
		case PTP_CMD_CANON_GETEVENT:
			[self parseCanonGetEventResponse: data];
			break;
		case PTP_CMD_CANON_GETEVFIMG:
		{
//			[self parsePtpLiveViewImageResponse: response data: data];
//			if (inLiveView)
//				[self requestLiveViewImage];
			
			break;
		}
//		case PTP_CMD_NIKON_DEVICEREADY:
//		{
//			uint16_t code = 0;
//			[response getBytes: &code range: NSMakeRange(6, 2)];
//
//			switch (code)
//			{
//				case PTP_RSP_DEVICEBUSY:
//					[self queryDeviceBusy];
//					break;
//				case PTP_RSP_OK:
//				{
//					// activate frame timer when device is ready after starting live view to start getting images
//					if ([self isPtpPropertySupported:PTP_PROP_NIKON_LV_STATUS])
//						[self ptpGetPropertyDescription: PTP_PROP_NIKON_LV_STATUS];
//					else
//						[self cameraDidBecomeReadyForLiveViewStreaming];
//					// update exposure preview property for UI, as it is not automatically queried otherwise
//					if ([self isPtpPropertySupported:PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW])
//						[self ptpGetPropertyDescription: PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW];
//					break;
//				}
//				default:
//				{
//					// some error occured
//					NSLog(@"didSendPTPCommand  DeviceReady returned error 0x%04X", code);
//					[self stopLiveView];
//					break;
//				}
//			}
//
//			break;
//		}
//		case PTP_CMD_NIKON_STOPLIVEVIEW:
//		{
//			if (liveViewStatus == LV_STATUS_RESTART_STOPPING)
//				[self startLiveView];
//			break;
//		}
		default:
			[super didSendPTPCommand: command inData: data response: response error: error contextInfo: contextInfo];
			
			break;
	}

}

@end

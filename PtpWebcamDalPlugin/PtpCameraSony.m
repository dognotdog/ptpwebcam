//
//  PtpCameraSony.m
//  PTPWebcamDALPlugin
//
//  Created by Dömötör Gulyás on 21.08.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpCameraSony.h"
#import "FoundationExtensions.h"

/**
 Sony needs a special connection handshake, apparently:
 1. 0x9201 PTP_CMD_SONY_CONNECT with param0 = 1
 2. 0x9201 PTP_CMD_SONY_CONNECT with param0 = 2
 3. 0x9202 PTP_CMD_SONY_GETPROPERTIES with param0 = 0xC8 (200)
 4. 0x9201 PTP_CMD_SONY_CONNECT with param0 = 3
 
 Why PTP_CMD_SONY_GETPROPERTIES requires 0xC8 as the parameter is not known to us, neither is if the GetProperties command does necessarily have to be between the last two Connect commands.
 */


#define SONY_GETALLPROPS_MAGICNUMBER	0xC8


typedef enum {
	CAMERA_STATUS_START,
	CAMERA_STATUS_CONNECTING1,
	CAMERA_STATUS_CONNECTING2,
	CAMERA_STATUS_GETPROPERTIES,
	CAMERA_STATUS_CONNECTING3,
	CAMERA_STATUS_GETPROPERTYDESCRIPTIONS,
	CAMERA_STATUS_CONNECTED,
	CAMERA_STATUS_ERROR
} cameraStatus_t;


@implementation PtpCameraSony
{
	cameraStatus_t cameraStatus;
//	NSDictionary* targetDeviceSettings;
}

static NSDictionary* _ptpPropertyNames = nil;
static NSDictionary* _ptpPropertyValueNames = nil;
static NSDictionary* _ptpOperationNames = nil;


+ (void) initialize
{
	if (self == [PtpCameraSony self])
	{
		NSDictionary* supportedCameras = @{
			@(0x054C) : @{
				@(0x0954) : @[@"Sony", @"A7S", ],
			},
		};
		
		[PtpCamera registerSupportedCameras: supportedCameras byClass: [PtpCameraSony class]];
		
		NSMutableDictionary* operationNames = [super ptpStandardOperationNames].mutableCopy;
		[operationNames addEntriesFromDictionary: @{
//			@(PTP_CMD_SONY_GETLIVEVIEWINFO) : @"Sony Get LiveView Info",
//			@(PTP_CMD_SONY_GETLIVEVIEWIMAGE) : @"Sony Get LiveView Image",
			@(PTP_CMD_SONY_CONNECT) : @"Sony Connect",
			@(PTP_CMD_SONY_GETPROPERTIES) : @"Sony GetProperties",
			@(PTP_CMD_SONY_GETPROPDESC) : @"Sony GetPropertyDescription",
			@(PTP_CMD_SONY_GETPROPVAL) : @"Sony GetPropertyValue",
			@(PTP_CMD_SONY_SETPROPABS) : @"Sony SetProperty",
			@(PTP_CMD_SONY_SETPROPSTEP) : @"Sony StepProperty",
			@(PTP_CMD_SONY_GETALLPROPDATA) : @"Sony GetAllPropertyData",
		}];
		_ptpOperationNames = operationNames;


		NSMutableDictionary* propertyNames = [super ptpStandardPropertyNames].mutableCopy;
		[propertyNames addEntriesFromDictionary: @{
			@(PTP_PROP_SONY_SHUTTERSPEED) : @"Shutter Speed",
			@(PTP_PROP_SONY_COLORTEMP) : @"WB Color Temp",
			@(PTP_PROP_SONY_WB_GREENMAGENTA) : @"WB Tune Green-Magenta",
			@(PTP_PROP_SONY_ZOOM) : @"Zoom",
			@(PTP_PROP_SONY_BATTERYLEVEL) : @"Battery Level",
			@(PTP_PROP_SONY_WB_AMBERBLUE) : @"WB Tune Amber-Blue",
			@(PTP_PROP_SONY_ISO) : @"ISO",
			@(PTP_PROP_LV_STATUS) : @"LiveView Status",
		}];
		_ptpPropertyNames = propertyNames;
		
		NSDictionary* propertyValueNames = @{
			@(PTP_PROP_WHITEBALANCE) : @{
				@(0x8001) : @"Flourescent Warm White",
				@(0x8002) : @"Flourescent Cool White",
				@(0x8003) : @"Flourescent Day White",
				@(0x8004) : @"Flourescent Daylight",
				@(0x8010) : @"Cloudy",
				@(0x8011) : @"Shade",
				@(0x8012) : @"Color Temperature",
				@(0x8020) : @"Custom 1",
				@(0x8021) : @"Custom 2",
				@(0x8022) : @"Custom 3",
				@(0x8030) : @"Auto Underwater",
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
		@(PTP_PROP_SONY_BATTERYLEVEL),
//		@(PTP_PROP_FOCUSDISTANCE),
		@(PTP_PROP_FLEN),
		@"-",
		@(PTP_PROP_EXPOSUREPM),
		@(PTP_PROP_FNUM),
		@(PTP_PROP_EXPOSUREISO),
		@(PTP_PROP_SONY_ISO),
		@(PTP_PROP_EXPOSURETIME),
		@(PTP_PROP_SONY_SHUTTERSPEED),
		@(PTP_PROP_WHITEBALANCE),
		@(PTP_PROP_EXPOSUREBIAS),
	];

		
	return self;
}

- (void) didRemoveDevice:(nonnull ICDevice *)device
{
	@synchronized (self) {
	}
	
	[super didRemoveDevice: device];
}

- (void) parsePtpDeviceInfoResponse: (NSData*) eventData
{
	[super parsePtpDeviceInfoResponse: eventData];
	
	// do sony special connect
	if ([self isPtpOperationSupported: PTP_CMD_SONY_CONNECT])
	{
		cameraStatus = CAMERA_STATUS_CONNECTING1;
		[self requestSendPtpCommandWithCode: PTP_CMD_SONY_CONNECT parameters: @[@(1)]];
	}
	else
	{
		// if no further information has to be determined, we're ready to talk to the DAL plugin
		[self cameraDidBecomeReadyForUse];
	}

}

- (void) didSendPTPCommand: (NSData*)command inData: (NSData*)data response: (NSData*)response error: (NSError*)error contextInfo: (void*)contextInfo
{
	uint16_t cmd = 0;
	[command getBytes: &cmd range: NSMakeRange(6, 2)];
	
//	assert(response || data);

	switch (cmd)
	{
		case PTP_CMD_SONY_CONNECT:
		{
			switch(cameraStatus)
			{
				case CAMERA_STATUS_CONNECTING1:
				{
					cameraStatus = CAMERA_STATUS_CONNECTING2;
					[self requestSendPtpCommandWithCode: PTP_CMD_SONY_CONNECT parameters: @[@(2)]];
					break;
				}
				case CAMERA_STATUS_CONNECTING2:
				{
					if ([self isPtpOperationSupported: PTP_CMD_SONY_GETPROPERTIES])
					{
						cameraStatus = CAMERA_STATUS_GETPROPERTIES;
						[self requestSendPtpCommandWithCode: PTP_CMD_SONY_GETPROPERTIES parameters: @[@(SONY_GETALLPROPS_MAGICNUMBER)]];
					}
					else
					{
						cameraStatus = CAMERA_STATUS_CONNECTING3;
						[self requestSendPtpCommandWithCode: PTP_CMD_SONY_CONNECT parameters: @[@(3)]];

					}
					break;
				}
				case CAMERA_STATUS_CONNECTING3:
				{
					cameraStatus = CAMERA_STATUS_CONNECTED;
					if ([self isPtpOperationSupported: PTP_CMD_SONY_GETALLPROPDATA])
					{
						cameraStatus = CAMERA_STATUS_GETPROPERTYDESCRIPTIONS;
						[self requestSendPtpCommandWithCode: PTP_CMD_SONY_GETALLPROPDATA];
					}

					break;
				}
				default:
				{
					break;
				}
			}
			break;
		}
		case PTP_CMD_SONY_GETPROPERTIES:
		{
			if (cameraStatus == CAMERA_STATUS_GETPROPERTIES)
			{
				cameraStatus = CAMERA_STATUS_CONNECTING3;
				[self requestSendPtpCommandWithCode: PTP_CMD_SONY_CONNECT parameters: @[@(3)]];
			}
			[self parseSonyPropertiesResponse: data];

			break;
		}
		case PTP_CMD_SONY_GETPROPDESC:
		{
			[self parseSonyPropertyDescriptionResponse: data];
			break;
		}
		case PTP_CMD_SONY_GETALLPROPDATA:
		{
			[self parseSonyAllPropertyDataResponse: data];
			
			@synchronized (self) {
				if (cameraStatus == CAMERA_STATUS_GETPROPERTYDESCRIPTIONS)
				{
					cameraStatus = CAMERA_STATUS_CONNECTED;
				}
				[self cameraDidBecomeReadyForUse];
			}

			
			break;
		}
		case PTP_CMD_SONY_SETPROPABS:
		case PTP_CMD_SONY_SETPROPSTEP:
		{
			break;
		}
		default:
			[super didSendPTPCommand: command inData: data response: response error: error contextInfo: contextInfo];
			
			break;
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


- (void) parseSonyPropertyDescriptionResponse: (NSData*) data
{
	
}

- (void) parseSonyAllPropertyDataResponse: (NSData*) data
{
	// first 8 bytes unknown, then sony format property descriptions:
		// 2 byte propertyId
		// 2 bytes dataType
		// 2 bytes unknown
		// default value
		// current value
		// 1 byte formFlag
		// range
	
	if (data.length < 8)
	{
		assert(0);
		return;
	}
	
	data = [data subdataWithRange: NSMakeRange( 8, data.length-8)];
	
	while (data.length)
	{
		id propertyId = [self parsePtpItem: data ofType: PTP_DATATYPE_UINT16_RAW remainingData: &data];
		id dataType = [self parsePtpItem: data ofType: PTP_DATATYPE_UINT16_RAW remainingData: &data];
		
		
		// for the next two bytes, following was recorded with an A7S:
		// 0x5004 File Format   (3)		= 0x01, 1
		// 0x5005 White Balance (2)		= 0x01, 1
		// when 0x500E = 2 (auto)
		//   0x5007 Aperture 	(400)	= 0x00, 2
		// when 0x500E = 1 (manual)
		//   0x5007 Aperture 	(560)	= 0x00, 1
		// 0x500A Focus Mode	(2)		= 0x00, 2
		// 0x500B Metering Mode (1)		= 0x00, 2
		// 0x500C Flash Mode 	(0)		= 0x00, 0
		// 0x500E Exposure PM 	(2)		= 0x00, 2		(dial)
		// 0x5010 Exposure Bias (1700)	= 0x00, 2		(dial)
		// 0x5013 AF Drive		(1)		= 0x01, 1
		// 0xD200 Flash	Bias	(0)		= 0x00, 1
		// 0xD201 Auto HDR		(31)	= 0x01, 1
		// 0xD203 Image Size	(1)		= 0x01, 1
		// when 0x500E = 2 (auto)
		//   0xD20D Shutter Speed (19660810) = 0x00, 2
		// when 0x500E = 1 (manual)
		//   0xD20D Shutter Speed (65596)    = 0x00, 1
		// 0xD20E ???			(1) 	= 0x00, 2
		// when 0x5005 = 2 (auto)
		//   0xD20F WB Color Temp (0) 	= 0x01, 0
		// when 0x5005 = 32786 (color temp)
		//   0xD20F WB Color Temp (5500)= 0x01, 1
		// 0xD210 WB GM			(128)	= 0x01, 1
		// 0xD21C WB AB			(128)	= 0x01, 1
		// 0xD211 Aspect Ratio 	(1)		= 0x01, 1
		// 0xD213 AF State		(1)		= 0x00, 2
		// 0xD21E ISO			(100)	= 0x00, 1
		// 0xD21B Picture FX	(32768) = 0x01, 0
		// 0xD21D Rec Video St	(0)		= 0x00, 2
		// 0xD21F FEL State		(1)		= 0x00, 2
		// 0xD217 AEL State		(1)		= 0x00, 2
		// 0xD218 Battery Info	(-1)	= 0x00, 2
		// 0xD219 Sensor Crop	(1)		= 0x00, 2
		// 0xD2C1 Shutter Half	(1)		= 0x81, 1
		// 0xD2C2 Shutter Full	(1)		= 0x81, 1
		// 0xD2C3 AEL Button	(1)		= 0x81, 1
		// 0xD2C9 FEL Button	(1)		= 0x81, 1
		// 0xD2C8 Video Rec But (1)		= 0x81, 1
		// 0xD212 ???			(0)		= 0x00, 1
		// 0xD221 LiveView Stat (1)		= 0x01, 1
		// 0xD214 Zoom			(18324480) = 0x00, 1
		// 0xD215 Photo Queue	(0)		= 0x00, 1
		// 0xD2C5 ???			(1)		= 0x83, 1
		// 0xD2C7 ???			(1)		= 0x81, 1
		
		
		// this seems to be flags
		// 0x81 is a button
		// maybe 0x01 indicates the settings bank (main/sub)
		// maybe 0x01 indicates incremental setting?
		id flags = [self parsePtpItem: data ofType: PTP_DATATYPE_UINT8_RAW remainingData: &data];
		
		// this seems to indicate read/write status
		// 0 = no effect, 1 = settable, 2 = set by camera
		id readwrite = [self parsePtpItem: data ofType: PTP_DATATYPE_UINT8_RAW remainingData: &data];

		id defaultValue = [self parsePtpItem: data ofType: [dataType unsignedIntValue] remainingData: &data];
		id currentValue = [self parsePtpItem: data ofType: [dataType unsignedIntValue] remainingData: &data];
		id formFlag = [self parsePtpItem: data ofType: PTP_DATATYPE_UINT8_RAW remainingData: &data];

		id form = @[];
		
		switch([formFlag unsignedIntValue])
		{
			case 0x01: // range
			{
				id rmin = [self parsePtpItem: data ofType: [dataType unsignedIntValue] remainingData: &data];
				id rmax = [self parsePtpItem: data ofType: [dataType unsignedIntValue] remainingData: &data];
				id rstep = [self parsePtpItem: data ofType: [dataType unsignedIntValue] remainingData: &data];
				
				form = @{@"min" : rmin, @"max" : rmax, @"step" : rstep};
				break;
			}
			case 0x02: // enum
			{
				uint16_t enumCount = [[self parsePtpItem: data ofType: PTP_DATATYPE_UINT16_RAW remainingData: &data] unsignedShortValue];
				
				NSMutableArray* enumValues = [NSMutableArray arrayWithCapacity: enumCount];
				for (size_t i = 0; i < enumCount; ++i)
				{
					[enumValues addObject: [self parsePtpItem: data ofType: [dataType unsignedIntValue] remainingData: &data]];
				}
				form = enumValues;
				break;
			}
		}
		
		NSDictionary* info = @{
			@"defaultValue" : defaultValue,
			@"value" : currentValue,
			@"range" : form,
			@"rw" : @([readwrite unsignedIntValue] == 1),
			@"dataType" : dataType,
			@"incremental" : @(([flags unsignedIntValue] & 0x01) == 0),
			@"flags" : flags
		};
		
//		NSLog(@"0x%04X : %@", [propertyId unsignedIntValue], info);
		NSDictionary* oldInfo = nil;
		@synchronized (self) {
			oldInfo = self.ptpPropertyInfos[propertyId];
			
			if (!self.ptpPropertyInfos)
				self.ptpPropertyInfos = @{};
			
			// update list of supported properties, as apparently not all property IDs that are returned via GetAllPropertyData are reported in GetProperties
			if (![self.ptpDeviceInfo[@"properties"] containsObject: propertyId])
				self.ptpDeviceInfo = [self.ptpDeviceInfo dictionaryBySettingObject: [self.ptpDeviceInfo[@"properties"] arrayByAddingObject: propertyId] forKey: @"properties"];
			
			self.ptpPropertyInfos = [self.ptpPropertyInfos dictionaryBySettingObject: info forKey: propertyId];
		}
		
		[self receivedProperty: info oldProperty: oldInfo withId: propertyId];
		
		

	}
	
	// with the A7S, it looks like 0xD220 is in the list of GetProperties, but not in GetAllPropertyData
	// and the A7S doesn't have a mechanism for querying just a single property description

	
	// check for properties that were not returned by GetAllPropertyData
	NSSet* receivedProperties = [NSSet setWithArray: self.ptpPropertyInfos.allKeys];
	NSMutableSet* supportedProperties = [NSMutableSet setWithArray: self.ptpDeviceInfo[@"properties"]];
	

	[supportedProperties minusSet: receivedProperties];
	
	// A7S specific dangling property, remove it
	if ([supportedProperties containsObject: @(0xD220)] && (supportedProperties.count == 1))
	{
		[supportedProperties removeObject: @(0xD220)];
		@synchronized (self) {
			self.ptpDeviceInfo = [self.ptpDeviceInfo dictionaryBySettingObject: [self.ptpDeviceInfo[@"properties"] arrayByRemovingObject: @(0xD220)] forKey: @"properties"];

		}
	}
	
	for (NSNumber* propertyId in supportedProperties)
	{
		[self ptpGetPropertyDescription: propertyId.unsignedIntValue];
	}
	
}


- (void) parseSonyPropertiesResponse: (NSData*) data
{
	if (data.length < 2)
	{
		assert(0);
		return;
	}
	
	uint16_t code = 0;
	[data getBytes: &code range: NSMakeRange(0, sizeof(code))];

	if (code != SONY_GETALLPROPS_MAGICNUMBER)
	{
		assert(0);
		return;
	}

	NSArray* properties = [self parsePtpItem: [data subdataWithRange: NSMakeRange(2, data.length - 2)] ofType: PTP_DATATYPE_UINT16_ARRAY remainingData: NULL];
	
	@synchronized (self) {
		NSArray* oldProperties = self.ptpDeviceInfo[@"properties"];
		if (!oldProperties)
			oldProperties = @[];
		self.ptpDeviceInfo = [self.ptpDeviceInfo dictionaryBySettingObject: [oldProperties arrayByAddingObjectsFromArray: properties] forKey: @"properties"];
	}
}

- (void) ptpGetPropertyDescription: (uint32_t) property
{
//	if (property < 0xD000)
//	{
//		[super ptpGetPropertyDescription: property];
//		return;
//	}
	
	if ([self isPtpOperationSupported: PTP_CMD_SONY_GETPROPDESC])
		[self requestSendPtpCommandWithCode: PTP_CMD_SONY_GETPROPDESC parameters: @[@(property)]];
	else if ([self isPtpOperationSupported: PTP_CMD_GETPROPDESC])
		[self requestSendPtpCommandWithCode: PTP_CMD_GETPROPDESC parameters:@[@(property)]];
	else if ([self isPtpOperationSupported: PTP_CMD_SONY_GETALLPROPDATA])
		[self requestSendPtpCommandWithCode: PTP_CMD_SONY_GETALLPROPDATA];
//	else
//		assert(0);

}

- (void) ptpSetProperty: (uint32_t) propertyId toValue: (id) value
{
	NSDictionary* propertyInfo = self.ptpPropertyInfos[@(propertyId)];
	
	if (!propertyInfo)
		return;
	
	bool incremental = [propertyInfo[@"incremental"] boolValue];
	
	if (incremental)
	{
		[self ptpIncrementProperty: propertyId toValue: value];
	}
	else
	{
		[self requestSendPtpCommandWithCode: PTP_CMD_SONY_SETPROPABS parameters: @[@(propertyId)] data: [self encodePtpProperty: propertyId fromValue: value]];
	}
		
}

- (void) ptpIncrementProperty: (uint32_t) propertyId toValue: (id) value
{
	NSDictionary* propertyInfo = self.ptpPropertyInfos[@(propertyId)];
	
	if (!propertyInfo)
		return;

	id range = propertyInfo[@"range"];
	if (![range isKindOfClass: [NSArray class]])
		return;
	
	NSArray* rangeArray = range;
	
	NSInteger oldIndex = [rangeArray indexOfObject: propertyInfo[@"value"]];
	NSInteger newIndex = [rangeArray indexOfObject: value];
	
	NSInteger difference = newIndex - oldIndex;
	
	[self ptpIncrementProperty: propertyId by: difference];
}

- (void) ptpIncrementProperty: (uint32_t) propertyId by: (int32_t) increment
{
	[self requestSendPtpCommandWithCode: PTP_CMD_SONY_SETPROPSTEP parameters: @[@(propertyId)] data: [self encodePtpDataOfType: PTP_DATATYPE_EOS_SINT32 fromValue: @(increment)]];
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
		case PTP_EVENT_SONY_PROPVALCHANGED:
		{
			// if a device property changed that's shown in the UI, update its value
			if (_ptpPropertyNames[@(eventParam)])
				[self ptpGetPropertyDescription: eventParam];

			break;
		}
		default:
		{
			[super cameraDevice: camera didReceivePTPEvent: eventData];
			break;
		}
	}
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
	return @[[NSValue valueWithSize: self.currenLiveViewImageSize]];
}

@end

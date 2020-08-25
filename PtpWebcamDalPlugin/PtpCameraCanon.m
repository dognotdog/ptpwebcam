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
static NSDictionary* _ptpOperationNames = nil;

+ (void) initialize
{
	if (self == [PtpCameraCanon self])
	{
		NSDictionary* supportedCameras = @{
			@(0x04A9) : @{
				@(0x3145) : @[@"Canon", @"450D"],
				@(0x3146) : @[@"Canon", @"40D"],
				@(0x317B) : @[@"Canon", @"1000D"],
				@(0x3199) : @[@"Canon", @"5D-II"],
				@(0x319A) : @[@"Canon", @"7D"],
				@(0x319B) : @[@"Canon", @"50D"],
				@(0x31CF) : @[@"Canon", @"500D"],
				@(0x31D0) : @[@"Canon", @"1D-IV"],
				@(0x31EA) : @[@"Canon", @"550D"],
				@(0x3215) : @[@"Canon", @"60D"],
				@(0x3217) : @[@"Canon", @"1100D"],
				@(0x3218) : @[@"Canon", @"600D"],
				@(0x3218) : @[@"Canon", @"1DX"],
				@(0x323A) : @[@"Canon", @"5D-III"],
				@(0x323B) : @[@"Canon", @"650D"],
				@(0x323D) : @[@"Canon", @"M"],
				@(0x3250) : @[@"Canon", @"6D"],
				@(0x3252) : @[@"Canon", @"1DC"],
				@(0x3253) : @[@"Canon", @"70D"],
				@(0x3270) : @[@"Canon", @"100D"],
				@(0x3272) : @[@"Canon", @"700D"],
				@(0x3273) : @[@"Canon", @"M2"],
				@(0x327F) : @[@"Canon", @"1200D"],
				@(0x3280) : @[@"Canon", @"760D"],
				@(0x3281) : @[@"Canon", @"5D-IV"],
				@(0x3292) : @[@"Canon", @"1DX-II"],
				@(0x3294) : @[@"Canon", @"80D"],
				@(0x3295) : @[@"Canon", @"5Ds"],
				@(0x3299) : @[@"Canon", @"M3"],
				@(0x32A0) : @[@"Canon", @"M10"],
				@(0x32A1) : @[@"Canon", @"750D"],
				@(0x32AF) : @[@"Canon", @"5Ds-R"],
				@(0x32B4) : @[@"Canon", @"1300D"],
				@(0x32BB) : @[@"Canon", @"M5"],
				@(0x32C5) : @[@"Canon", @"M6"],
				@(0x32C9) : @[@"Canon", @"800D"],
				@(0x32CA) : @[@"Canon", @"6D-II"],
				@(0x32CB) : @[@"Canon", @"77D"],
				@(0x32CC) : @[@"Canon", @"200D"],
				@(0x32D1) : @[@"Canon", @"M100"],
				@(0x32D2) : @[@"Canon", @"M50"],
				@(0x32D9) : @[@"Canon", @"4000D"],
				@(0x32DA) : @[@"Canon", @"R"],
				@(0x32E1) : @[@"Canon", @"1500D"],
				@(0x32E2) : @[@"Canon", @"R2"],
				@(0x32E7) : @[@"Canon", @"M6-II"],
				@(0x32E8) : @[@"Canon", @"1DX-III"],
				@(0x32E9) : @[@"Canon", @"250D"],
				@(0x32EA) : @[@"Canon", @"90D"],
				@(0x32F4) : @[@"Canon", @"R5"],
			},
		};
		
		[PtpCamera registerSupportedCameras: supportedCameras byClass: [PtpCameraCanon class]];

		NSMutableDictionary* operationNames = [super ptpStandardOperationNames].mutableCopy;
		[operationNames addEntriesFromDictionary: @{
			@(PTP_CMD_CANON_GETEVFIMG) : @"Canon Get EVF Image",
			@(PTP_CMD_CANON_GETDEVICEINFO_EX) : @"Canon GetDeviceInfoEx",
			@(PTP_CMD_CANON_SETPROPVAL_EX) : @"Canon SetPropValEx",
			@(PTP_CMD_CANON_SETREMOTEMODE) : @"Canon SetRemoteMode",
			@(PTP_CMD_CANON_SETEVENTMODE) : @"Canon SetEventMode",
			@(PTP_CMD_CANON_GETEVENT) : @"Canon GetEvent",
			@(PTP_CMD_CANON_KEEPDEVICEON) : @"Canon KeepDeviceOn",
			@(PTP_CMD_CANON_REQUESTPROPVAL) : @"Canon RequestPropVal",
			@(PTP_CMD_CANON_GETVIEWFINDERDATA) : @"Canon GetViewFinderData",
			@(PTP_CMD_CANON_DOAF) : @"Canon Do AF",
			@(PTP_CMD_CANON_DRIVELENS) : @"Canon DriveLens",
			@(PTP_CMD_CANON_DOF_PREVIEW) : @"Canon Exposure Preview",
			@(PTP_CMD_CANON_AF_CANCEL) : @"Canon AF Cancel",
		}];
		_ptpOperationNames = operationNames;

		NSMutableDictionary* propertyNames = [super ptpStandardPropertyNames].mutableCopy;
		[propertyNames addEntriesFromDictionary: @{
			@(PTP_PROP_CANON_EVF_OUTPUTDEVICE) : @"LiveView Output Device",
			@(PTP_PROP_CANON_EVF_MODE) : @"EVF Mode",
			@(PTP_PROP_CANON_EVF_WHITEBALANCE) : @"EVF Whitebalance",
			@(PTP_PROP_CANON_EVF_EXPOSURE_PREVIEW) : @"Exposure Preview",
			@(PTP_PROP_CANON_EXPOSUREBIAS) : @"Exposure Correction",
			@(PTP_PROP_CANON_METERINGMODE) : @"Metering Mode",
			@(PTP_PROP_CANON_FOCUSMODE) : @"Focus Mode",
			@(PTP_PROP_CANON_APERTURE) : @"Aperture",
			@(PTP_PROP_CANON_EXPOSURETIME) : @"Shutter Speed",
			@(PTP_PROP_CANON_ISO) : @"ISO",
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

+ (BOOL) enumeratesContentCatalogOnSessionOpen
{
	return NO;
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
			@(PTP_PROP_CANON_EVF_COLORTEMP),
			@(PTP_PROP_CANON_EXPOSUREBIAS),
			@(PTP_PROP_CANON_METERINGMODE),
//			@(PTP_PROP_CANON_FOCUSMODE),
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

- (void) parsePtpDeviceInfoResponse: (NSData*) eventData
{
	[super parsePtpDeviceInfoResponse: eventData];
	
	// do Canon special connect
	if ([self isPtpOperationSupported: PTP_CMD_CANON_SETREMOTEMODE])
	{
		[self requestSendPtpCommandWithCode: PTP_CMD_CANON_SETREMOTEMODE parameters: @[@(1)]];
	}
	else
	{
		// if no further information has to be determined, we're ready to talk to the DAL plugin
		[self cameraDidBecomeReadyForUse];
	}

}

- (NSArray*) parsePtpRangeEnumData: (NSData*) data ofType: (int) dataType remainingData: (NSData**) remData
{
	uint16_t enumCount = [[self parsePtpItem: data ofType: PTP_DATATYPE_UINT16_RAW remainingData: &data] unsignedShortValue];
	
	// adjust dataType because Canon decided to use 16bit enum values even for 8bit dataTypes
	switch(dataType)
	{
		case PTP_DATATYPE_SINT8_RAW:
			dataType = PTP_DATATYPE_SINT16_RAW;
		case PTP_DATATYPE_UINT8_RAW:
			dataType = PTP_DATATYPE_UINT16_RAW;
	}
	
	NSMutableArray* enumValues = [NSMutableArray arrayWithCapacity: enumCount];
	for (size_t i = 0; i < enumCount; ++i)
	{
		[enumValues addObject: [self parsePtpItem: data ofType: dataType remainingData: &data]];
	}
	if (remData)
		*remData = data;
	return enumValues;
}

- (void) didRemoveDevice:(nonnull ICDevice *)device
{
	@synchronized (self) {
		if (eventPollTimer)
		{
			dispatch_suspend(eventPollTimer);
//			dispatch_source_set_event_handler(eventPollTimer, nil);
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
//	[self ptpSetProperty: PTP_PROP_CANON_EVF_OUTPUTDEVICE toValue: @(2)];
	
	[self queryCanonEvents];
	
	return YES;
}

- (void) requestLiveViewImage
{
	[self requestSendPtpCommandWithCode: PTP_CMD_CANON_GETVIEWFINDERDATA parameters: @[@(0x00100000)]];

}

- (void) queryCanonEvents
{
	[self requestSendPtpCommandWithCode: PTP_CMD_CANON_GETEVENT];
}

- (NSString*) formatPtpPropertyValue: (id) value ofProperty: (int) propertyId withDefaultValue: (id) defaultValue
{
	switch (propertyId)
	{
		case PTP_PROP_CANON_APERTURE:
		{
			return [NSString stringWithFormat: @"%.1f", 0.1*[value doubleValue]];
		}
		case PTP_PROP_CANON_ISO:
		{
			// 72 is 100
			// 80 is 200
			// 88 is 400
			// 96 is 800
			// 104 is 1600
			// ... so 72 is 100, every +8 is doubling
			//     but in-between values are linear, great...
			int base = [value intValue]/8;
			int frac = [value intValue] - base*8;
			double roundedFrac = (10.0*(1.0 + 0.1*floor(10.0*frac/8.0)))/10.0;
			double val = 100.0*pow(2, (base - 9))*roundedFrac;
			double roundedVal = val;
			if (frac != 0) // only round fractionals
			{
				double targets[] = {0.8, 1.0, 1.25, 1.6, 2.0, 2.5, 3.2, 4.0, 5.0, 6.4, 8.0, 10.0, 12.5};
				for (size_t i = 0; i < 10; ++i)
				{
					double decadeLow = pow(10, i);
					double decadeHigh = pow(10, i+1);
					if ((val > decadeLow) && (val < decadeHigh))
					{
						double dval = val / decadeLow;
						
						for (size_t k = 1; k+1 < sizeof(targets)/sizeof(*targets); ++k)
						{
							if ((fabs(dval-targets[k]) < fabs(dval-targets[k-1])) && (fabs(dval-targets[k]) < fabs(dval-targets[k+1])))
								dval = targets[k];
						}

						roundedVal = decadeLow * dval;
						break;
					}
				}
			}
//			return [NSString stringWithFormat: @"%.0f", [value doubleValue]];
			return [NSString stringWithFormat: @"%.0f", roundedVal];
		}
		case PTP_PROP_CANON_EXPOSURETIME:
		{
			// inferred 56 = 1/1
			// inferred 64 = 1/2
			// inferred 72 = 1/4
			// inferred 80 = 1/8
			// inferred 88 = 1/16
			// 96 = 1/30
			// 99 = 1/40
			// 101 = 1/50
			// 104 = 1/60
			// 107 = 1/80
			// 109 = 1/100
			// 112 = 1/125
			// 115 = 1/160
			// 117 = 1/200
			// 120 = 1/250
			// 128 = 1/500
			// ... seems same 8 ish setup as with ISO

			int base = [value intValue]/8;
			int frac = [value intValue] - base*8;
			base = base - 7;
			
			bool over1sec = [value intValue] <= 56;
			if (over1sec)
			{
				base = -base - (frac>0);
				frac = (8-frac) % 8;
			}
			
			double val = 1.0*pow(2, base)*0.1*floor(10.0*(1.0+frac/8.0));
			
			double roundedVal = val;
//			if (frac != 0) // only round fractionals
			{
				double targets[] = {0.8, 1.0, 1.25, 1.6, 2.0, 2.5, 3.2, 4.0, 5.0, 6.4, 8.0, 10.0, 12.5};
				for (size_t i = 0; i < 10; ++i)
				{
					targets[2] = i < 2 ? 1.3 : 1.25;
					targets[6] = i < 2 ? 3.0 : 3.2;
					targets[9] = i < 2 ? 6.0 : 6.4;
					double decadeLow = pow(10, i);
					double decadeHigh = pow(10, i+1);
					if ((val > decadeLow) && (val < decadeHigh))
					{
						double dval = val / decadeLow;
						
						for (size_t k = 1; k+1 < sizeof(targets)/sizeof(*targets); ++k)
						{
							if ((fabs(dval-targets[k]) < fabs(dval-targets[k-1])) && (fabs(dval-targets[k]) < fabs(dval-targets[k+1])))
								dval = targets[k];
						}

						roundedVal = decadeLow * dval;
						break;
					}
				}
			}

			if (over1sec)
			{
				if (roundedVal < 3.0)
					return [NSString stringWithFormat: @"%.1f s", roundedVal];
				else
					return [NSString stringWithFormat: @"%.0f s", roundedVal];
			}
			else
			{
				if (roundedVal < 3.0)
					return [NSString stringWithFormat: @"1/%.1f s", roundedVal];
				else
					return [NSString stringWithFormat: @"1/%.0f s", roundedVal];
			}
		}
		case PTP_PROP_CANON_EXPOSUREBIAS:
		{
			return [NSString stringWithFormat: @"%+.1f", 0.1*[value charValue]];
		}
		default:
		{
			return [super formatPtpPropertyValue: value ofProperty: propertyId withDefaultValue: defaultValue];
		}
	}
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

- (NSArray*) parseEosDataArray: (NSData*) data ofType: (int) dataType remainingData: (NSData**) remainingData
{
	if (data.length < 4)
		return nil;
	
	uint32_t len = 0;
	[data getBytes: &len range: NSMakeRange(0, sizeof(len))];
	
	size_t bytesRequired = 0;
	
	size_t (^reader)(NSData* data, size_t i, id* value) = nil;

	switch (dataType)
	{
		case PTP_DATATYPE_EOS_SINT8_ARRAY:
		{
			bytesRequired = 4+len*4;
			
 			reader = ^size_t(NSData* data, size_t i, id* value){
				int8_t val = 0;
				[data getBytes: &val range: NSMakeRange(i, sizeof(val))];
				*value = @(val);
				return 4;
			};
			
			break;
		}
		case PTP_DATATYPE_EOS_UINT8_ARRAY:
		{
				bytesRequired = 4+len*4;
				
				reader = ^size_t(NSData* data, size_t i, id* value){
				uint8_t val = 0;
				[data getBytes: &val range: NSMakeRange(i, sizeof(val))];
				*value = @(val);
				return 4;
			};
			
			break;
		}
		case PTP_DATATYPE_EOS_SINT16_ARRAY:
		{
			bytesRequired = 4+len*4;
			
			reader = ^size_t(NSData* data, size_t i, id* value){
				int16_t val = 0;
				[data getBytes: &val range: NSMakeRange(i, sizeof(val))];
				*value = @(val);
				return 4;
			};
			
			break;
		}
		case PTP_DATATYPE_EOS_UINT16_ARRAY:
		{
			bytesRequired = 4+len*4;
			
			reader = ^size_t(NSData* data, size_t i, id* value){
				uint16_t val = 0;
				[data getBytes: &val range: NSMakeRange(i, sizeof(val))];
				*value = @(val);
				return 4;
			};
			
			break;
		}
		case PTP_DATATYPE_EOS_SINT32_ARRAY:
		{
			bytesRequired = 4+len*4;
			
			reader = ^size_t(NSData* data, size_t i, id* value){
				int32_t val = 0;
				[data getBytes: &val range: NSMakeRange(i, sizeof(val))];
				*value = @(val);
				return 4;
			};
			
			break;
		}
		case PTP_DATATYPE_EOS_UINT32_ARRAY:
		{
			bytesRequired = 4+len*4;
			
			reader = ^size_t(NSData* data, size_t i, id* value){
				uint32_t val = 0;
				[data getBytes: &val range: NSMakeRange(i, sizeof(val))];
				*value = @(val);
				return 4;
			};
			
			break;
		}
		case PTP_DATATYPE_EOS_STRING:
		{
			reader = ^size_t(NSData* data, size_t i, id* value) {
				NSData* remaining = data;
				[self parseEosString: data remainingData: &remaining];
				size_t bytesRead = data.length - remaining.length;
								
				return bytesRead;
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
		*remainingData = [data subdataWithRange: NSMakeRange(k, data.length - k)];

	return values;

}

- (NSNumber*) parseEosSint8: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	if (data.length < 4)
		return nil;
	
	int8_t val = 0;
	[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
		
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( 4, data.length - 4)];
	}
	
	return @(val);
}

- (NSNumber*) parseEosUint8: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	if (data.length < 4)
		return nil;
	
	uint8_t val = 0;
	[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
		
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( 4, data.length - 4)];
	}
	
	return @(val);
}

- (NSNumber*) parseEosSint16: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	if (data.length < 4)
		return nil;
	
	int16_t val = 0;
	[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
		
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( 4, data.length - 4)];
	}
	
	return @(val);
}

- (NSNumber*) parseEosUint16: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	if (data.length < 4)
		return nil;
	
	uint16_t val = 0;
	[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
		
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( 4, data.length - 4)];
	}
	
	return @(val);
}

- (NSNumber*) parseEosSint32: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	if (data.length < 4)
		return nil;
	
	int32_t val = 0;
	[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
		
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( 4, data.length - 4)];
	}
	
	return @(val);
}

- (NSNumber*) parseEosUint32: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	if (data.length < 4)
		return nil;
	
	uint32_t val = 0;
	[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
		
	if (remData)
	{
		*remData = [data subdataWithRange: NSMakeRange( 4, data.length - 4)];
	}
	
	return @(val);
}

- (NSString*) parseEosString: (NSData*) data remainingData: (NSData** _Nullable) remData
{
	size_t len = strnlen(data.bytes, data.length);
	NSString* string = [[NSString alloc] initWithData: [data subdataWithRange: NSMakeRange(0, len)] encoding: NSUTF8StringEncoding];
	
	if (remData && len < data.length)
		*remData = [data subdataWithRange: NSMakeRange(len+1, data.length - (len+1))];
	
	return string;
	
}

- (id) parsePtpItem: (NSData*) data ofType: (int) dataType remainingData: (NSData**) remData
{
	switch (dataType)
	{
		case PTP_DATATYPE_EOS_SINT8:
		{
			return [self parseEosSint8: data remainingData: remData];
		}
		case PTP_DATATYPE_EOS_UINT8:
		{
			return [self parseEosUint8: data remainingData: remData];
		}
		case PTP_DATATYPE_EOS_SINT16:
		{
			return [self parseEosSint16: data remainingData: remData];
		}
		case PTP_DATATYPE_EOS_UINT16:
		{
			return [self parseEosUint16: data remainingData: remData];
		}
		case PTP_DATATYPE_EOS_SINT32:
		{
			return [self parseEosSint32: data remainingData: remData];
		}
		case PTP_DATATYPE_EOS_UINT32:
		{
			return [self parseEosUint32: data remainingData: remData];
		}
		case PTP_DATATYPE_EOS_STRING:
		{
			return [self parseEosString: data remainingData: remData];
		}
		case PTP_DATATYPE_EOS_SINT8_ARRAY:
		case PTP_DATATYPE_EOS_UINT8_ARRAY:
		case PTP_DATATYPE_EOS_SINT16_ARRAY:
		case PTP_DATATYPE_EOS_UINT16_ARRAY:
		case PTP_DATATYPE_EOS_SINT32_ARRAY:
		case PTP_DATATYPE_EOS_UINT32_ARRAY:
		case PTP_DATATYPE_EOS_STRING_ARRAY:
		{
			return [self parseEosDataArray: data ofType: dataType remainingData: remData];
		}
		default:
		{
			return [super parsePtpItem: data ofType: dataType remainingData: remData];
		}
	}
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
	
	[self requestSendPtpCommandWithCode: PTP_CMD_CANON_SETPROPVAL_EX parameters: nil data: dataBlock];
}

- (void) ptpGetPropertyDescription: (uint32_t) property
{
	if (property < 0x9000)
	{
		[super ptpGetPropertyDescription: property];
		return;
	}
	
	if ([self isPtpOperationSupported: PTP_CMD_CANON_REQUESTPROPVAL])
		[self requestSendPtpCommandWithCode: PTP_CMD_CANON_REQUESTPROPVAL parameters: @[@(property)]];
//	else
//		assert(0);

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

	if (canonDataType <= 7)
		return PTP_DATATYPE_EOS_ARRAY_MASK + canonDataType;
	else
		return 0;

}

- (void) canonPropertyChanged: (uint32_t) propertyId toData: (NSData*) data
{
	NSDictionary* oldInfo = nil;
	NSMutableDictionary* propertyInfo = nil;

	// ensure the property update itself is atomic
	@synchronized (self) {
		oldInfo = self.ptpPropertyInfos[@(propertyId)];
		propertyInfo = oldInfo.mutableCopy;

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

		if (![self.ptpDeviceInfo[@"properties"] containsObject: @(propertyId)])
		{
			self.ptpDeviceInfo = [self.ptpDeviceInfo dictionaryBySettingObject: [self.ptpDeviceInfo[@"properties"] arrayByAddingObject: @(propertyId)] forKey: @"properties"];
		}

	}

	[self receivedProperty: propertyInfo oldProperty: oldInfo withId: @(propertyId)];
}

- (void) receivedProperty: (NSDictionary*) propertyInfo oldProperty: (NSDictionary*) oldInfo withId: (NSNumber*) propertyId
{
	switch(propertyId.intValue)
	{
		case PTP_PROP_CANON_EVF_MODE:
		{
			if ([propertyInfo[@"value"] intValue] == 1)
				[self ptpSetProperty: PTP_PROP_CANON_EVF_OUTPUTDEVICE toValue: @(2)];
			break;
		}
		case PTP_PROP_CANON_EVF_OUTPUTDEVICE:
		{
			if ([propertyInfo[@"value"] intValue] == 2)
				[self cameraDidBecomeReadyForLiveViewStreaming];
			break;
		}
		case PTP_PROP_CANON_FOCUSMODE:
		{
			if ([self.delegate respondsToSelector:@selector(cameraAutofocusCapabilityChanged:)])
				[(id <PtpCameraLiveViewDelegate>)self.delegate cameraAutofocusCapabilityChanged: self];
			break;
		}
		case PTP_PROP_CANON_FOCUSINFO:
		{
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
				if ([self isPtpOperationSupported: PTP_CMD_CANON_AF_CANCEL])
					[self requestSendPtpCommandWithCode: PTP_CMD_CANON_AF_CANCEL];
			});
			break;
		}
	}
	
	[super receivedProperty: propertyInfo oldProperty: oldInfo withId: propertyId];
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
				if (values.count > 0)
					info[@"rw"] = @(YES);
				info[@"dataType"] = @(_canonDataTypeToPtpDataType(dataType));
				self.ptpPropertyInfos = [self.ptpPropertyInfos dictionaryBySettingObject: info forKey: @(propertyId)];
				
				if (![self.ptpDeviceInfo[@"properties"] containsObject: @(propertyId)])
				{
					self.ptpDeviceInfo = [self.ptpDeviceInfo dictionaryBySettingObject: [self.ptpDeviceInfo[@"properties"] arrayByAddingObject: @(propertyId)] forKey: @"properties"];
				}
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

		if (blockData.length > 0)
			[self parseCanonEventBlock: blockData ofType: type];
		
		eventData = [eventData subdataWithRange: NSMakeRange(len, eventData.length - len)];
	}
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

//	bool isDeviceBusy = code == PTP_RSP_DEVICEBUSY;
	
	if (!data) // no data means no image to present
	{
		if (code != PTP_RSP_CANON_NOT_READY)
			PtpLog(@"parsePtpLiveViewImageResponse: no data!");
		
		
		// restart live view if it got turned off after timeout or error
		// device busy does not restart, as it does not indicate a permanent error condition that necessitates cycling.
//		if (!isDeviceBusy && (liveViewStatus == LV_STATUS_ON))
//		{
//			PtpLog(@"error code 0x%04X", code);
//			[self restartLiveView];
//		}
		
		return;
	}
	
	
	switch (code)
	{
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
	
	NSData* jpegData = [self extractLiveViewJpegData: data];
	
	// TODO: JPEG SOI marker might appear in other data, so just using that is not enough to reliably extract JPEG without knowing more
//	NSData* jpegData = [self extractNikonLiveViewJpegData: data];
	
	if ([self.delegate respondsToSelector: @selector(receivedLiveViewJpegImage:withInfo:fromCamera:)])
		[(id <PtpCameraLiveViewDelegate>)self.delegate receivedLiveViewJpegImage: jpegData withInfo: @{} fromCamera: self];
	
}

- (void)didSendPTPCommand:(NSData*)command inData:(NSData*)data response:(NSData*)response error:(NSError*)error contextInfo:(void*)contextInfo
{
	uint16_t cmd = 0;
	[command getBytes: &cmd range: NSMakeRange(6, 2)];

	// response is
	// length (32bit)
	// type (16bit) 0x0003
	// response code (16bit)
	// transaction id (32bit)

	uint16_t responseCode = 0;
	[response getBytes: &responseCode range: NSMakeRange(6, 2)];

	switch (cmd)
	{
		case PTP_CMD_CANON_SETREMOTEMODE:
		{
			if ([self isPtpOperationSupported: PTP_CMD_CANON_SETEVENTMODE])
			{
				[self requestSendPtpCommandWithCode: PTP_CMD_CANON_SETEVENTMODE parameters: @[@(1)]];
			}
			else
			{
				[self cameraDidBecomeReadyForUse];
			}
			break;
		}
		case PTP_CMD_CANON_SETEVENTMODE:
		{
			[self cameraDidBecomeReadyForUse];
			break;
		}
		case PTP_CMD_CANON_GETEVENT:
			[self parseCanonGetEventResponse: data];
			break;
		case PTP_CMD_CANON_GETVIEWFINDERDATA:
		{
			[self parsePtpLiveViewImageResponse: response data: data];
//			if (inLiveView)
//				[self requestLiveViewImage];
			
			break;
		}
		case PTP_CMD_CANON_DOAF:
		{
			break;
		}
		case PTP_CMD_CANON_REQUESTPROPVAL:
		{
			break;
		}
		case PTP_CMD_CANON_SETPROPVAL_EX:
		{
			if ((responseCode == PTP_RSP_OK) || (responseCode == PTP_RSP_DEVICEBUSY))
			{
				id dataLength = [self parsePtpItem: data ofType: PTP_DATATYPE_UINT32_RAW remainingData: &data];
				#pragma unused(dataLength)

				id property = [self parsePtpItem: data ofType: PTP_DATATYPE_UINT32_RAW remainingData: &data];
				[self canonPropertyChanged: [property unsignedIntValue] toData: data];
			}
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



- (NSSize) currenLiveViewImageSize
{
	return NSMakeSize(1024, 768);
}

- (NSArray*) liveViewImageSizes
{
	return @[[NSValue valueWithSize: self.currenLiveViewImageSize]];
}

- (int) canAutofocus
{
	bool afOpSupported = [self isPtpOperationSupported: PTP_CMD_CANON_DOAF];
	if (afOpSupported && [self isPtpPropertySupported: PTP_PROP_CANON_FOCUSMODE])
	{
		NSDictionary* info = self.ptpPropertyInfos[@(PTP_PROP_CANON_FOCUSMODE)];
		id val = info[@"value"];
		switch ([val intValue])
		{
			case 0:
				return PTPCAM_AF_AVAILABLE;
			case 3:
				return PTPCAM_AF_MANUAL_MODE;
			default:
				return PTPCAM_AF_UNKNOWN;

		}
	}
	else if (afOpSupported)
		return PTPCAM_AF_AVAILABLE;
	else
		return PTPCAM_AF_UNKNOWN;
}

- (void) performAutofocus
{
	if ([self isPtpOperationSupported: PTP_CMD_CANON_AF_CANCEL])
	{
		[self requestSendPtpCommandWithCode: PTP_CMD_CANON_AF_CANCEL];
	}
	if ([self isPtpOperationSupported: PTP_CMD_CANON_DOAF])
	{
		[self requestSendPtpCommandWithCode: PTP_CMD_CANON_DOAF];
	}
}

@end

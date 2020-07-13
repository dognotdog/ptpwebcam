//
//  PtpWebcamPtpDevice.m
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 06.06.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamPtpDevice.h"
#import "PtpWebcamPtpStream.h"


@interface PtpWebcamPtpDevice ()
{
	uint32_t transactionId;
	NSStatusItem* statusItem;

}
@end

static NSDictionary* _ptpPropertyNames = nil;
static NSDictionary* _ptpProgramModeNames = nil;
static NSDictionary* _ptpWhiteBalanceModeNames = nil;
static NSDictionary* _ptpLiveViewImageSizeNames = nil;

static NSDictionary* _supportedCameras = nil;

static NSDictionary* _liveViewJpegDataOffsets = nil;

@implementation PtpWebcamPtpDevice

+ (BOOL) supportsCamera: (ICDevice*) camera
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_supportedCameras = @{
			// Nikon
			@(0x04B0) : @{
//				@(0x0410) : @[@"Nikon", @"D200"],
				@(0x041A) : @[@"Nikon", @"D300"],
				@(0x041C) : @[@"Nikon", @"D3"],
				@(0x0422) : @[@"Nikon", @"D700"],
//				@(0x0423) : @[@"Nikon", @"D5000"],
//				@(0x0424) : @[@"Nikon", @"D3000"],
				@(0x0425) : @[@"Nikon", @"D300S"],
				@(0x0426) : @[@"Nikon", @"D3S"],
//				@(0x0428) : @[@"Nikon", @"D7000"],
//				@(0x0429) : @[@"Nikon", @"D5100"],
				@(0x042A) : @[@"Nikon", @"D800"],
				@(0x042E) : @[@"Nikon", @"D800E"],
//				@(0x0430) : @[@"Nikon", @"D7100"],
				@(0x0436) : @[@"Nikon", @"D810"],
				@(0x0437) : @[@"Nikon", @"D750"],
				@(0x043B) : @[@"Nikon", @"D810A"],
//				@(0x043F) : @[@"Nikon", @"D5600"],
//				@(0x0440) : @[@"Nikon", @"D7500"],
				@(0x0441) : @[@"Nikon", @"D850"],
			},
		};
	});
	NSDictionary* modelDict = _supportedCameras[@(camera.usbVendorID)];
	if (!modelDict)
		return NO;
	NSArray* cameraInfo = modelDict[@(camera.usbProductID)];
	if (cameraInfo)
		return YES;
	return NO;
}

- (instancetype) initWithIcDevice: (ICCameraDevice*) device pluginInterface: (_Nonnull CMIOHardwarePlugInRef) pluginInterface
{
	if (!(self = [super initWithPluginInterface: pluginInterface]))
		return nil;
	
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
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
			@(0x8010) : @"Overcast",
			@(0x8011) : @"Shadow",
			@(0x8012) : @"Color Temperature",
			@(0x8013) : @"Preset",
		};

		_ptpLiveViewImageSizeNames = @{
			@(0x0000) : @"Undefined",
			@(0x0001) : @"VGA",
			@(0x0002) : @"QVGA",
			@(0x0003) : @"XGA",
		};


		_liveViewJpegDataOffsets = @{
			@(0x04B0) : @{
				// JPEG data offset
				@(0x041A) : @(64), // D300
				@(0x041C) : @(64), // D3
				@(0x0422) : @(64), // D700
				@(0x0425) : @(64), // D300S
				@(0x0426) : @(128), // D3S
				@(0x042A) : @(384), // D800
				@(0x042E) : @(384), // D800E
				@(0x0436) : @(384), // D810
				@(0x0437) : @(384), // D750
				@(0x043B) : @(384), // D810A
				@(0x0441) : @(384), // D850
			},
		};

	});
	
	NSDictionary* liveViewJpegOffsetsMake = _liveViewJpegDataOffsets[@(device.usbVendorID)];
	self.liveViewHeaderLength = [liveViewJpegOffsetsMake[@(device.usbProductID)] unsignedIntegerValue];
	
	self.cameraDevice = device;
	device.delegate = self;
	
	self.name = device.name;
	self.manufacturer = @"Nikon";
	self.elementNumberName = @"1";
	self.elementCategoryName = @"DSLR Webcam";
	self.deviceUid = @"ptp-webcam-plugin-device";
	self.modelUid = @"ptp-webcam-plugin-model";
	self.ptpPropertyInfos = @{};

	device.delegate = self;

		
	[device requestEnableTethering];

	NSData* command = [self ptpCommandWithType: PTP_TYPE_COMMAND code: PTP_CMD_GETDEVICEINFO transactionId: [self nextTransactionId]];
	
	[device requestSendPTPCommand: command
						  outData: nil
			  sendCommandDelegate: self
		   didSendCommandSelector: @selector(didSendPTPCommand:inData:response:error:contextInfo:)
					  contextInfo: NULL];

	return self;
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


- (void) device:(ICDevice *)device didOpenSessionWithError:(NSError *)error
{
	NSLog(@"D800 didOpenSession");
	if (error)
		NSLog(@"D800 could not open session because %@", error);
	
}

- (void)device:(nonnull ICDevice *)device didCloseSessionWithError:(nonnull NSError *)error {
}

- (void)didRemoveDevice:(nonnull ICDevice *)device
{
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
	[self.cameraDevice requestSendPTPCommand: command
									 outData: nil
						 sendCommandDelegate: self
					  didSendCommandSelector: @selector(didSendPTPCommand:inData:response:error:contextInfo:)
								 contextInfo: NULL];

}

- (void) sendPtpCommand: (NSData*) command withData: (NSData*) data
{
	[self.cameraDevice requestSendPTPCommand: command
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
		case MTP_CMD_GETOBJECTPROPSSUPPORTED:
			[self parseMtpObjectPropertiesSupportedResponse: data];
			break;
		case PTP_CMD_NIKON_GETVENDORPROPS:
			[self parseNikonPropertiesResponse: data];
			break;
		default:
			NSLog(@"didSendPTPCommand  cmd=%@", command);
			NSLog(@"didSendPTPCommand data=%@", data);
			break;
	}
	
}

- (void) parseNikonPropertiesResponse: (NSData*) data
{
	uint32_t len = 0;
	[data getBytes: &len range: NSMakeRange(0, sizeof(len))];
	assert(len*2+4 == data.length); // length is how many items we have following
	
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

	dispatch_async(dispatch_get_main_queue(), ^{
		[self rebuildStatusItem];
	});

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
	
	assert(1+len*2 <= data.length);
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

- (void) parseMtpObjectPropertiesSupportedResponse: (NSData*) eventData
{
	
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
	
	ptpDeviceInfo[@"operations"] = opsSupported;
	
	for (id prop in opsSupported)
		NSLog(@"supports operation  0x%04X", [prop intValue]);

	NSArray* eventsSupported = [self parsePtpUint16Array: moreData remainingData: &moreData];
	//	NSLog(@"  events = %@", eventsSupported);
	
	ptpDeviceInfo[@"events"] = eventsSupported;
	
	
	NSArray* propsSupported = [self parsePtpUint16Array: moreData remainingData: &moreData];
	//	NSLog(@"  props = %@", propsSupported);
	
	ptpDeviceInfo[@"properties"] = propsSupported;
	
	for (id prop in propsSupported)
		NSLog(@"supports property  0x%04X", [prop intValue]);
	
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
	if ([opsSupported containsObject: @(PTP_CMD_NIKON_GETVENDORPROPS)])
		[self requestSendPtpCommandWithCode: PTP_CMD_NIKON_GETVENDORPROPS];

//	[self ptpGetPropertyDescription: PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW];
//	[self ptpGetPropertyDescription: PTP_PROP_NIKON_LV_STATUS];

	
//	if ([ptpDeviceInfo[@"operations"] containsObject: @(MTP_CMD_GETOBJECTPROPSSUPPORTED)])
//	{
//		[self querySupportedMtpProperties];
//	}
	
}

- (void) requestSendPtpCommandWithCode: (int) code
{
	NSData* command = [self ptpCommandWithType: PTP_TYPE_COMMAND code: code transactionId: [self nextTransactionId]];
	
	[self.cameraDevice requestSendPTPCommand: command
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

- (void) querySupportedMtpProperties
{
	[self requestSendPtpCommandWithCode: MTP_CMD_GETOBJECTPROPSSUPPORTED];
}

- (uint32_t) nextTransactionId
{
	@synchronized (self) {
		return ++transactionId;
	}
}

- (void) unplugDevice
{
	
	[self.stream unplugDevice];

	[self removeStatusItem];

	[self deleteCmioDevice];
	
}

- (void) createStatusItem
{
	statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength: NSVariableStatusItemLength];

	// The text that will be shown in the menu bar
	statusItem.button.title = @"D800";

	// The image that will be shown in the menu bar, a 16x16 black png works best
//	_statusItem.image = [NSImage imageNamed:@"feedbin-logo"];

	// The highlighted image, use a white version of the normal image
//	_statusItem.alternateImage = [NSImage imageNamed:@"feedbin-logo-alt"];

	// The image gets a blue background when the item is selected
//	statusItem.highlightMode = YES;

}

- (void) removeStatusItem
{
	
	[[NSStatusBar systemStatusBar] removeStatusItem: statusItem];
	
}

- (NSString*) formatValue: (id) value ofType: (int) dataType
{
	NSString* valueString = [NSString stringWithFormat:@"%@", value];
	
	switch (dataType)
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
		case PTP_PROP_EXPOSUREPM:
		{
			NSString* name = [_ptpProgramModeNames objectForKey: value];
			if (!name)
				name =  [NSString stringWithFormat:@"0x%04X", [value unsignedIntValue]];
			
			valueString = name;
			break;
		}
		case PTP_PROP_WHITEBALANCE:
		{
			NSString* name = [_ptpWhiteBalanceModeNames objectForKey: value];
			if (!name)
				name =  [NSString stringWithFormat:@"0x%04X", [value unsignedIntValue]];
			
			valueString = name;
			break;
		}
		case PTP_PROP_NIKON_LV_IMAGESIZE:
		{
			NSString* name = [_ptpLiveViewImageSizeNames objectForKey: value];
			if (!name)
				name =  [NSString stringWithFormat:@"0x%04X", [value unsignedIntValue]];
			
			valueString = name;
			break;
		}
		case PTP_PROP_NIKON_LV_STATUS:
		case PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW:
		{
			valueString = [value boolValue] ? @"On" : @"Off";
			break;
		}
	}

	return valueString;
}

- (void) rebuildStatusItem
{
	if (!statusItem)
	{
		[self createStatusItem];
	}
	
	
	NSMenu* menu = [[NSMenu alloc] init];
	
	for (NSNumber* propertyId in [self.ptpPropertyInfos.allKeys sortedArrayUsingSelector: @selector(compare:)])
	{
		NSString* name = _ptpPropertyNames[propertyId];
		NSDictionary* property = self.ptpPropertyInfos[propertyId];

		id value = property[@"value"];
		NSString* valueString = [self formatValue: value ofType: propertyId.intValue];
		
		
				
		NSMenuItem* menuItem = [[NSMenuItem alloc] init];
		[menuItem setTitle: [NSString stringWithFormat: @"%@ (%@)", name, valueString]];
		
		// add submenus for writable items
		if ([property[@"rw"] boolValue])
		{
			if ([property[@"range"] isKindOfClass: [NSArray class]])
			{
				NSMenu* submenu = [[NSMenu alloc] init];
				NSArray* values = property[@"range"];
				
				for (id enumVal in values)
				{
					NSString* valStr = [self formatValue: enumVal ofType: propertyId.intValue];

					NSMenuItem* subItem = [[NSMenuItem alloc] init];
					subItem.title =  valStr;
					subItem.target = self;
					subItem.action =  @selector(changeCameraPropertyAction:);
					subItem.tag = propertyId.integerValue;
					subItem.representedObject = enumVal;
					
					if ([value isEqual: enumVal])
						subItem.state = NSControlStateValueOn;
					
					[submenu addItem: subItem];

				}
				
				menuItem.submenu = submenu;

			}

		}

		
		[menu addItem: menuItem];
	}
	
	statusItem.menu = menu;

}

- (IBAction) changeCameraPropertyAction:(NSMenuItem*)sender
{
	uint32_t propertyId = (uint32_t)sender.tag;
	
	[self ptpSetProperty: propertyId toValue: sender.representedObject];

	[self ptpQueryKnownDeviceProperties];
}

@end

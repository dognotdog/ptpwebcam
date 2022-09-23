//
//  UvcCamera.m
//  PtpWebcamLaunchAgent
//
//  Created by Dömötör Gulyás on 24.01.2021.
//  Copyright © 2021 InRobCo. All rights reserved.
//

/**
 UVC devices have units and terminals. Units have several input and one output "pin".
 
 Video controls have current, min/max resolution, size, default fields
 
 Camera Terminal has shutter / lens adjustments
 Processing Unit has image, white balance, gain controls
 */


#import "UvcCamera.h"
#import "../PtpWebcamDalPlugin/PtpWebcamAlerts.h"

#import <IOKit/usb/IOUSBLib.h>
#import <IOKit/IOCFPlugIn.h>

#import <AVKit/AVKit.h>


#define CC_VIDEO		kUSBVideoInterfaceClass
#define SC_VIDEOCONTROL kUSBVideoControlSubClass

// UVC 1.5 Class Specification, p 156, Table A-4 VC Descriptor Types
#define CS_UNDEFINED		0x20
#define CS_DEVICE			0x21
#define CS_CONFIGURATION	0x22
#define CS_STRING			0x23
#define CS_INTERFACE		0x24
#define CS_ENDPOINT			0x25

// UVC 1.5 Class Specification, p 157, Table A-5 VC Interface Descriptor Subtypes
#define VC_DESCRIPTOR_UNDEFINED	0x00
#define VC_HEADER				0x01
#define VC_INPUT_TERMINAL		0x02
#define VC_OUTPUT_TERMINAL		0x03
#define VC_SELECTOR_UNIT		0x04
#define VC_PROCESSING_UNIT		0x05
#define VC_EXTENSION_UNIT		0x06
#define VC_ENCODING_UNIT		0x07

// UVC 1.5 Class Specification, pp 159, Table A-12 Camera Terminal Control Selectors
#define CT_CONTROL_UNDEFINED				0x00
#define CT_SCANNING_MODE_CONTROL			0x01
#define CT_AE_MODE_CONTROL					0x02
#define CT_AE_PRIORITY_CONTROL				0x03
#define CT_EXPOSURE_TIME_ABSOLUTE_CONTROL	0x04
#define CT_EXPOSURE_TIME_RELATIVE_CONTROL	0x05
#define CT_FOCUS_ABSOLUTE_CONTROL	0x06
#define CT_FOCUS_RELATIVE_CONTROL	0x07
#define CT_FOCUS_AUTO_CONTROL		0x08
#define CT_IRIS_ABSOLUTE_CONTROL	0x09
#define CT_IRIS_RELATIVE_CONTROL	0x0A
#define CT_ZOOM_ABSOLUTE_CONTROL	0x0B
#define CT_ZOOM_RELATIVE_CONTROL	0x0C
#define CT_PANTILT_ABSOLUTE_CONTROL	0x0D
#define CT_PANTILT_RELATIVE_CONTROL	0x0E
#define CT_ROLL_ABSOLUTE_CONTROL	0x0F
#define CT_ROLL_RELATIVE_CONTROL	0x10
#define CT_PRIVACY_CONTROL			0x11
#define CT_FOCUS_SIMPLE_CONTROL		0x12
#define CT_WINDOW_CONTROL			0x13
#define CT_REGION_OF_INTEREST_CONTROL		0x14

// UVC 1.5 Class Specification, pp 160, Table A-13 Processing Unit Control Selectors
#define PU_CONTROL_UNDEFINED				0x00
#define PU_BACKLIGHT_COMPENSATION_CONTROL	0x01
#define PU_BRIGHTNESS_CONTROL				0x02
#define PU_CONTRAST_CONTROL					0x03
#define PU_GAIN_CONTROL						0x04
#define PU_POWER_LINE_FREQUENCY_CONTROL		0x05
#define PU_HUE_CONTROL						0x06
#define PU_SATURATION_CONTROL				0x07
#define PU_SHARPNESS_CONTROL				0x08
#define PU_GAMMA_CONTROL					0x09
#define PU_WB_TEMPERATURE_CONTROL			0x0A
#define PU_WB_TEMPERATURE_AUTO_CONTROL		0x0B
#define PU_WB_COMPONENT_CONTROL				0x0C
#define PU_WB_COMPONENT_AUTO_CONTROL		0x0D
#define PU_DIGITAL_MULTIPLIER_CONTROL		0x0E
#define PU_DIGITAL_MULTIPLIER_LIMIT_CONTROL	0x0F
#define PU_HUE_AUTO_CONTROL					0x10
#define PU_ANALOG_VIDEO_STANDARD_CONTROL	0x11
#define PU_ANALOG_LOCK_STATUS_CONTROL		0x12
#define PU_CONTRAST_AUTO_CONTROL			0x13

// UVC 1.5 Class Specification, p 162, Table B-2 Input Terminal Types
#define ITT_CAMERA		0x0201

// UVC 1.5 Class Specification, p 158, Table A-8 Video Class-Specific Request Codes
#define SET_CUR		0x01
#define GET_CUR		0x81
#define GET_MIN		0x82
#define GET_MAX		0x83
#define GET_RES		0x84
#define GET_LEN		0x85
#define GET_INFO	0x86
#define GET_DEF		0x87


typedef struct UVCTypedDescriptorHeader {
    uint8_t bLength;
    uint8_t bDescriptorType;
	uint8_t bDescriptorSubType;
} __attribute__((packed)) UVCTypedDescriptorHeader;


typedef struct UVCInterfaceDescriptorHeader {
    uint8_t bLength;
    uint8_t bDescriptorType;
	uint8_t bDescriptorSubType;
	uint16_t bcdUVC;
	uint16_t wTotalLength;
	uint32_t dwClockFrequency;
	uint8_t bInCollection;
	uint8_t baInterfaceNr[];
} __attribute__((packed)) UVCInterfaceDescriptorHeader;

typedef struct UVCInputTerminalDescriptor {
    uint8_t bLength;
    uint8_t bDescriptorType;
	uint8_t bDescriptorSubType;
	uint8_t bTerminalID;
	uint16_t wTerminalType;
	uint8_t bAssocTerminal;
	uint8_t iTerminal;
	// ... additional fields depending on type
} __attribute__((packed)) UVCInputTerminalDescriptor;

typedef struct UVCOutputTerminalDescriptor {
    uint8_t bLength;
    uint8_t bDescriptorType;
	uint8_t bDescriptorSubType;
	uint8_t bTerminalID;
	uint16_t wTerminalType;
	uint8_t bAssocTerminal;
	uint8_t bSourceID;
	uint8_t iTerminal;
	// ... additional fields depending on type
} __attribute__((packed)) UVCOutputTerminalDescriptor;


typedef struct UVCCameraTerminalDescriptor {
    uint8_t bLength; 			// 18
    uint8_t bDescriptorType; 	// CS_INTERFACE
	uint8_t bDescriptorSubType; // VC_INPUT_TERMINAL
	uint8_t bTerminalID;
	uint16_t wTerminalType; 	// ITT_CAMERA
	uint8_t bAssocTerminal;
	uint8_t iTerminal;
	uint16_t wObjectiveFocalLengthMin;
	uint16_t wObjectiveFocalLengthMax;
	uint16_t wOcularFocalLength;
	uint8_t bControlSize;
	uint8_t bmControls[3];
} __attribute__((packed)) UVCCameraTerminalDescriptor;

typedef struct UVCProcessingUnitDescriptor {
    uint8_t bLength; 			// 13
    uint8_t bDescriptorType; 	// CS_INTERFACE
	uint8_t bDescriptorSubType; // VC_PROCESSING_UNIT
	uint8_t bUnitId;
	uint8_t bSourceId;
	uint16_t wMaxMultiplier;
	uint8_t bControlSize;
	uint8_t bmControls[3];
	uint8_t iProcessing;
	uint8_t bmVideoStandards;
} __attribute__((packed)) UVCProcessingUnitDescriptor;


// Processing Unit Settings
static NSDictionary* puSettingsBits = nil;

// Camera Terminal Settings
static NSDictionary* ctSettingsBits = nil;

static NSDictionary* settingsSelectors = nil;
static NSDictionary* settingsLengths = nil;
static NSDictionary* settingsUiNames = nil;
static NSDictionary* settingsValueUiNames = nil;





@implementation UvcCamera
{
	IOUSBInterfaceInterface300 **controlInterface;
	io_object_t generalInterestNotification;
	
	NSMutableDictionary* cameraTerminalSettings;
	NSMutableDictionary* processingUnitSettings;

	NSMutableDictionary* settingsUnits; // which unit the settings belong to

	uint8_t cameraTerminalId;
	uint8_t processingUnitId;
	uint32_t maxDigitalMultiplier;
}

+ (NSDictionary*) settingsNames
{
	return settingsUiNames;
}

+ (NSDictionary<id, NSDictionary*>*) settingsValueNames
{
	return settingsValueUiNames;
}

- (instancetype) initWithCaptureDevice: (AVCaptureDevice *) device
{
	if (!(self = [super init]))
		return nil;
	
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		puSettingsBits = @{
			@"brightness" : @(0),
			@"contrast" : @(1),
			@"hue" : @(2),
			@"saturation" : @(3),
			@"sharpness" : @(4),
			@"gamma" : @(5),
			@"whiteBalanceTemperature" : @(6),
			@"whiteBalanceComponent" : @(7),

			@"backlightCompensation" : @(8),
			@"gain" : @(9),
			@"powerLineFrequency" : @(10),
			@"hueAuto" : @(11),
			@"whiteBalanceTemperatureAuto" : @(12),
			@"whiteBalanceCompnoentAuto" : @(13),
			@"digitalMultiplier" : @(14),
			@"digitalMultiplierLimit" : @(15),

			@"analogVideoStandard" : @(16),
			@"analogVideoLockStatus" : @(17),
			@"contrastAuto" : @(18),

		};

		ctSettingsBits = @{
			@"scanningMode" : 		@(0),
			@"autoExposureMode" : 	@(1),
			@"autoExposurePriority" : @(2),
			@"exposureTimeAbsolute" : @(3),
			@"exposureTimeRelative" : @(4),
			@"focusAbsolute" : 		@(5),
			@"focusRelative" : 		@(6),
			@"apertureAbsolute" : 	@(7),
			
			@"apertureRelative" : 	@(8),
			@"zoomAbsolute" : 		@(9),
			@"zoomRelative" : 		@(10),
			@"panTiltAbsolute" : 	@(11),
			@"panTiltRelative" : 	@(12),
			@"rollAbsolute" : 		@(13),
			@"rollRelative" : 		@(14),

			@"focusAuto" : 			@(16),
			@"privacy" : 			@(18),
			@"focusSimple" : 		@(19),
			@"window" : 			@(20),
			@"regionOfInterest" : 	@(21),

		};

		settingsSelectors = @{
			// PU Settings
			@"brightness" : 	@(PU_BRIGHTNESS_CONTROL),
			@"contrast" : 		@(PU_CONTRAST_CONTROL),
			@"hue" : 			@(PU_HUE_CONTROL),
			@"saturation" : 	@(PU_SATURATION_CONTROL),
			@"sharpness" : 		@(PU_SHARPNESS_CONTROL),
			@"gamma" : 			@(PU_GAMMA_CONTROL),
			@"whiteBalanceTemperature" : @(PU_WB_TEMPERATURE_CONTROL),
//			@"whiteBalanceComponent" : @(7),

			@"backlightCompensation" : 	@(PU_BACKLIGHT_COMPENSATION_CONTROL),
			@"gain" : 					@(PU_GAIN_CONTROL),
			@"powerLineFrequency" : 	@(PU_POWER_LINE_FREQUENCY_CONTROL),
			@"hueAuto" : @(PU_HUE_AUTO_CONTROL),
			@"whiteBalanceTemperatureAuto" : @(PU_WB_TEMPERATURE_AUTO_CONTROL),
			@"whiteBalanceComponentAuto" : @(PU_WB_COMPONENT_AUTO_CONTROL),
			@"digitalMultiplier" : @(PU_DIGITAL_MULTIPLIER_CONTROL),
			@"digitalMultiplierLimit" : @(PU_DIGITAL_MULTIPLIER_LIMIT_CONTROL),

//			@"analogVideoStandard" : @(16),
//			@"analogVideoLockStatus" : @(17),
			@"contrastAuto" : @(PU_CONTRAST_AUTO_CONTROL),

			// CT settings
			@"scanningMode" : 		@(CT_SCANNING_MODE_CONTROL),
			@"autoExposureMode" : 	@(CT_AE_MODE_CONTROL),
			@"autoExposurePriority" : @(CT_AE_PRIORITY_CONTROL),
			@"exposureTimeAbsolute" : @(CT_EXPOSURE_TIME_ABSOLUTE_CONTROL),
			@"exposureTimeRelative" : @(CT_EXPOSURE_TIME_RELATIVE_CONTROL),
			@"focusAbsolute" : 		@(CT_FOCUS_ABSOLUTE_CONTROL),
//			@"focusRelative" : 		@(6),
			@"apertureAbsolute" : 	@(CT_IRIS_ABSOLUTE_CONTROL),

//			@"apertureRelative" : 	@(8),
			@"zoomAbsolute" : 		@(CT_ZOOM_ABSOLUTE_CONTROL),
//			@"zoomRelative" : 		@(10),
//			@"panTiltAbsolute" : 	@(11),
//			@"panTiltRelative" : 	@(12),
			@"rollAbsolute" : 		@(CT_ROLL_ABSOLUTE_CONTROL),
//			@"rollRelative" : 		@(14),

			@"focusAuto" : 			@(CT_FOCUS_AUTO_CONTROL),
			@"privacy" : 			@(CT_PRIVACY_CONTROL),
			@"focusSimple" : 		@(CT_FOCUS_SIMPLE_CONTROL),
//			@"window" : 			@(20),
//			@"regionOfInterest" : 	@(21),
		};

		settingsLengths = @{
			// PU Settings
			@"brightness" : @(-2),
			@"contrast" : 	@(2),
			@"hue" : 		@(-2),
			@"saturation" : @(2),
			@"sharpness" : 	@(2),
			@"gamma" : 		@(2),
			@"whiteBalanceTemperature" : 	@(2),
			@"whiteBalanceComponent" : 		@(4),

			@"backlightCompensation" : 		@(2),
			@"gain" : 						@(2),
			@"powerLineFrequency" : 		@(1),
			@"hueAuto" : 					@(1),
			@"whiteBalanceTemperatureAuto" : @(1),
			@"whiteBalanceComponentAuto" : 	@(1),
			@"digitalMultiplier" : 			@(2),
			@"digitalMultiplierLimit" : 	@(2),

			@"analogVideoStandard" : 	@(1),
			@"analogVideoLockStatus" : 	@(1),
			@"contrastAuto" : 			@(1),

			// CT settings
			@"scanningMode" : 		@(1),
			@"autoExposureMode" : 	@(1),
			@"autoExposurePriority" : @(1),
			@"exposureTimeAbsolute" : @(4),
			@"exposureTimeRelative" : @(-1),
			@"focusAbsolute" : 		@(2),
			@"focusRelative" : 		@(2),
			@"apertureAbsolute" : 	@(2),

			@"apertureRelative" : 	@(1),
			@"zoomAbsolute" : 		@(2),
			@"zoomRelative" : 		@(3),
			@"panTiltAbsolute" : 	@(8),
			@"panTiltRelative" : 	@(4),
			@"rollAbsolute" : 		@(-2),
			@"rollRelative" : 		@(2),

			@"focusAuto" : 			@(1),
			@"privacy" : 			@(1),
			@"focusSimple" : 		@(1),
			@"window" : 			@(12),
			@"regionOfInterest" : 	@(10),

		};

		settingsUiNames = @{
			// PU Settings
			@"brightness" : @"Brightness",
			@"contrast" : 	@"Contrast",
			@"hue" : 		@"Hue",
			@"saturation" : @"Saturation",
			@"sharpness" : 	@"Sharpness",
			@"gamma" : 		@"Gamma",
			@"whiteBalanceTemperature" : 	@"WB Color Temp",
			@"whiteBalanceComponent" : 		@"WB Tune",

			@"backlightCompensation" : 		@"Backlight Compensation",
			@"gain" : 						@"Gain",
			@"powerLineFrequency" : 		@"Flicker Reduction",
			@"hueAuto" : 					@"Auto Hue",
			@"whiteBalanceTemperatureAuto" : @"Auto WB Color Temp",
			@"whiteBalanceComponentAuto" : 	@"Auto WB Tune",
//			@"digitalMultiplier" : 			@(2),
//			@"digitalMultiplierLimit" : 	@(2),

//			@"analogVideoStandard" : 	@(1),
//			@"analogVideoLockStatus" : 	@(1),
//			@"contrastAuto" : 			@(1),

			// CT settings
			@"scanningMode" : 		@"Scan Mode",
			@"autoExposureMode" : 	@"Exposure Mode",
			@"autoExposurePriority" : @"Auto Exposure Priority",
			@"exposureTimeAbsolute" : @"Exposure Time",
//			@"exposureTimeRelative" : @(1),
			@"focusAbsolute" : 		@"Focus",
//			@"focusRelative" : 		@(2),
			@"apertureAbsolute" : 	@"Aperture",

//			@"apertureRelative" : 	@(1),
//			@"zoomAbsolute" : 		@(2),
//			@"zoomRelative" : 		@(3),
//			@"panTiltAbsolute" : 	@(8),
//			@"panTiltRelative" : 	@(4),
//			@"rollAbsolute" : 		@(2),
//			@"rollRelative" : 		@(2),

			@"focusAuto" : 			@"Auto Focus",
			@"privacy" : 			@"Privacy Shutter",
//			@"focusSimple" : 		@(1),
//			@"window" : 			@(12),
//			@"regionOfInterest" : 	@(10),

		};

		settingsValueUiNames = @{
			// PU Settings
//			@"brightness" : @"Brightness",
//			@"contrast" : 	@(2),
//			@"hue" : 		@(2),
//			@"saturation" : @(2),
//			@"sharpness" : 	@(2),
//			@"gamma" : 		@(2),
//			@"whiteBalanceTemperature" : 	@(2),
//			@"whiteBalanceComponent" : 		@(4),

//			@"backlightCompensation" : 		@(2),
//			@"gain" : 						@(2),
			@"powerLineFrequency" : @{
				@(0) : @"Disabled",
				@(1) : @"50 Hz",
				@(2) : @"60 Hz",
				@(3) : @"Auto",
			},
			@"hueAuto" : @{
				@(0) : @"Off",
				@(1) : @"Auto",
			},
			@"whiteBalanceTemperatureAuto" : @{
				@(0) : @"Off",
				@(1) : @"Auto",
			},
			@"whiteBalanceComponentAuto" : @{
				@(0) : @"Off",
				@(1) : @"Auto",
			},
//			@"digitalMultiplier" : 			@(2),
//			@"digitalMultiplierLimit" : 	@(2),

//			@"analogVideoStandard" : 	@(1),
//			@"analogVideoLockStatus" : 	@(1),
//			@"contrastAuto" : 			@(1),

			// CT settings
			@"scanningMode" : @{
				@(0) : @"Interleaved",
				@(1) : @"Progressive",
			},
			@"autoExposureMode" : @{
				@(0x01) : @"Manual",
				@(0x02) : @"Auto",
				@(0x04) : @"Shutter Priority",
				@(0x08) : @"Aperture Priority",
			},
			@"autoExposurePriority" : @{
				@(0) : @"Shutter",
				@(1) : @"Aperture",
			},
//			@"exposureTimeAbsolute" : @(4),
//			@"exposureTimeRelative" : @(1),
//			@"focusAbsolute" : 		@(2),
//			@"focusRelative" : 		@(2),
//			@"apertureAbsolute" : 	@(2),

//			@"apertureRelative" : 	@(1),
//			@"zoomAbsolute" : 		@(2),
//			@"zoomRelative" : 		@(3),
//			@"panTiltAbsolute" : 	@(8),
//			@"panTiltRelative" : 	@(4),
//			@"rollAbsolute" : 		@(2),
//			@"rollRelative" : 		@(2),

//			@"focusAuto" : 			@(1),
			@"privacy" : @{
				@(0) : @"Open",
				@(1) : @"Closed",
			},
//			@"focusSimple" : 		@(1),
//			@"window" : 			@(12),
//			@"regionOfInterest" : 	@(10),

		};
	});
	
	uint32_t locationId = 0;
	sscanf(device.uniqueID.UTF8String, "0x%8x", &locationId);
	
	if (!locationId)
	{
//		NSLog(@"could not parse locationID for capture device %@", device.localizedName);
		return nil;
	}
	
	self.device = device;

	self.supportedSettings = [NSMutableDictionary dictionary];
	cameraTerminalSettings = [NSMutableDictionary dictionary];
	processingUnitSettings = [NSMutableDictionary dictionary];
	self.settingsInfos = [NSMutableDictionary dictionary];
	settingsUnits = [NSMutableDictionary dictionary];

	kern_return_t err = 0;
	
    NSMutableDictionary* matchingDictionary = (__bridge_transfer id)IOServiceMatching(kIOUSBDeviceClassName);	// requires <IOKit/usb/IOUSBLib.h>
    if (!matchingDictionary)
    {
        NSLog(@"could not create USB matching dictionary for device 0x%08x", locationId);
        return nil;
    }

	io_iterator_t iterator = 0;
    err = IOServiceGetMatchingServices(kIOMasterPortDefault, (__bridge_retained void*) matchingDictionary, &iterator);
	
	io_service_t usbDevice = 0;
	
	while ((usbDevice = IOIteratorNext(iterator)))
	{
		IOUSBDeviceInterface**	deviceInterface = NULL;
		
		{
			IOCFPlugInInterface**	pluginInterface = NULL;
			SInt32					score = 0;
			
			err = IOCreatePlugInInterfaceForService(usbDevice, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &pluginInterface, &score);
			if (err || (pluginInterface == NULL))
			{
				NSLog(@"could not access USB plugin interface for device 0x%08x", locationId);
				continue;
			}

			err = (*pluginInterface)->QueryInterface(pluginInterface, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID*)&deviceInterface);
			IODestroyPlugInInterface(pluginInterface);

			if (err || (deviceInterface == NULL))
			{
				NSLog(@"could not access USB device interface for device 0x%08x", locationId);
				continue;
			}
		}

		UInt32 currentLocationID = 0;
		(*deviceInterface)->GetLocationID(deviceInterface, &currentLocationID);
		
//		self.serialNumber = [self queryUsbSerialNumberOfInterface: deviceInterface];
//		// trim leading zeroes
//		NSRange range = [self.serialNumber rangeOfString:@"^0*" options: NSRegularExpressionSearch];
//		self.serialNumber = [self.serialNumber stringByReplacingCharactersInRange: range withString:@""];
//		NSLog(@"SERNO = %@ @0x%08X", self.serialNumber, currentLocationID);

		if (currentLocationID == locationId)
		{
			self.locationId = locationId;
			// parse descriptor for usable UVC units/terminals
			{
//				UInt8 config = 0;
//				(*deviceInterface)->GetConfiguration(deviceInterface, &config);
//				NSLog(@"USB device 0x%08x config %u", locationId, config);
				IOUSBConfigurationDescriptorPtr descriptor = NULL;
				err =  (*deviceInterface)->GetConfigurationDescriptorPtr(deviceInterface, 0, &descriptor);
				
				if (descriptor)
				{
					[self parseUsbConfigurationDescriptor: descriptor];
				}
				else
				{
					NSLog(@"could not get descriptor for USB device 0x%08x because 0x%x", locationId, err);

				}
			}


			io_iterator_t interfaceIterator = 0;
			// interface request to find the video control interface
			IOUSBFindInterfaceRequest interfaceRequest = {
				.bInterfaceClass = kUSBVideoInterfaceClass,
				.bInterfaceSubClass = kUSBVideoControlSubClass,
				.bInterfaceProtocol = kIOUSBFindInterfaceDontCare,
				.bAlternateSetting = kIOUSBFindInterfaceDontCare,
			};
			
			err = (*deviceInterface)->CreateInterfaceIterator(deviceInterface, &interfaceRequest, &interfaceIterator);
			
			if (err)
			{
				NSLog(@"could not create interface iterator for USB device 0x%08x", locationId);
				break;
			}
			
			io_service_t uvcService = 0;
			
			if ((uvcService = IOIteratorNext(interfaceIterator)))
			{
				IOCFPlugInInterface**	pluginInterface = NULL;
				SInt32					score = 0;
				
				err = IOCreatePlugInInterfaceForService(uvcService, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &pluginInterface, &score);
				
				IOObjectRelease(uvcService);
				uvcService = 0;
				
				if (err || (pluginInterface == NULL))
				{
					NSLog(@"could not access UVC plugin interface for device 0x%08x because 0x%x", locationId, err);
					continue;
				}

				err = (*pluginInterface)->QueryInterface(pluginInterface, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID*)&controlInterface);
				IODestroyPlugInInterface(pluginInterface);

				if (err || (controlInterface == NULL))
				{
					NSLog(@"could not access UVC control interface for device 0x%08x because 0x%x", locationId, err);
					continue;
				}
				
				NSLog(@"created UVC control interface for device 0x%08x", locationId);
				

			}
			
			[self registerForDeviceRemovalNotification: usbDevice];
			
			break;
		}
		
	}

	if (!controlInterface)
		return nil;
	
	
	[self queryControlInfos];
	
	return self;
}



static void _usbDeviceGeneralInterest( void * refcon, io_service_t service, uint32_t messageType, void * messageArgument )
{
	UvcCamera* self = (__bridge id)refcon;
	
	if(messageType == kIOMessageServiceIsTerminated)
	{
		NSLog(@"_usbDeviceGeneralInterest(kIOMessageServiceIsTerminated)");
		[self.delegate cameraRemoved: self];
	}
}

- (void) registerForDeviceRemovalNotification: (io_service_t) usbDevice
{
    IONotificationPortRef notificationPort = IONotificationPortCreate(kIOMasterPortDefault);
    CFRunLoopSourceRef notificationRunLoopSource = IONotificationPortGetRunLoopSource(notificationPort);
	NSRunLoop* runLoop = [NSRunLoop currentRunLoop];
	assert(runLoop);
	assert([runLoop getCFRunLoop]);
    CFRunLoopAddSource([runLoop getCFRunLoop], notificationRunLoopSource, kCFRunLoopCommonModes);

	IOReturn err = IOServiceAddInterestNotification(
		notificationPort,
		usbDevice,
		kIOGeneralInterest,
		_usbDeviceGeneralInterest,
		(__bridge void *)self,
		&generalInterestNotification
	);
	
	if (err)
	{
		NSLog(@"could not register for general interest notification because 0x%08X", err);
	}

}

- (NSString*) queryUsbSerialNumberOfInterface: (IOUSBDeviceInterface**) dif
{
	IOReturn err = 0;
	
	uint8_t sernoIndex = 0;
	err = (*dif)->USBGetSerialNumberStringIndex(dif, &sernoIndex);
	
	if (err)
	{
		NSLog(@"could not get USB serial number string index because 0x%08X", err);
		return nil;
	}
	
	NSMutableData* data = [NSMutableData dataWithLength: 256];
	
	IOUSBDevRequest request = {
		.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice),
		.bRequest = kUSBRqGetDescriptor,
		.wValue = (kUSBStringDesc << 8) | sernoIndex,
		.wIndex = 0x0409, // English
		.wLength = data.length,
		.pData = data.mutableBytes,
	};
	
	err = (*dif)->DeviceRequest(dif, &request);
	
	if (err)
	{
		NSLog(@"could not get USB serial number string because 0x%08X", err);
		return nil;
	}
	uint8_t sernolen = 0;
	[data getBytes: &sernolen range: NSMakeRange(0, sizeof(sernolen))];
	
	if (sernolen > data.length)
	{
		NSLog(@"could not get USB serial number string because string header length is %u, but data buffer is only %zu long, with wLenDone %u.", sernolen, data.length, request.wLenDone);
		return nil;
	}
	NSString* serno = [[NSString alloc] initWithBytes: [data subdataWithRange: NSMakeRange(2, data.length -2)].bytes length: sernolen-2 encoding: NSUTF16LittleEndianStringEncoding];
	NSLog(@"USB serial number is %@", serno);

	return serno;
}

- (void) readSettingInfo: (id) setting
{
	NSMutableDictionary* infoDict = self.settingsInfos[setting] ? self.settingsInfos[setting] : [NSMutableDictionary dictionary];

	uint8_t infoFlags = [self queryInfoForSetting: setting];
	
	infoDict[@"flags"] = @(infoFlags);
	

	// supports GET requests
	if (infoFlags & 0x01)
	{
		NSData* minData = nil;
		[self queryMinValueForSetting: setting into: &minData];
		NSData* maxData = nil;
		[self queryMaxValueForSetting: setting into: &maxData];
		NSData* resolutionData = nil;
		[self queryResolutionForSetting: setting into: &resolutionData];
		NSData* currentData = nil;
		[self queryCurrentValueForSetting: setting into: &currentData];
		NSData* defaultData = nil;
		[self queryDefaultValueForSetting: setting into: &defaultData];

		if (minData)
			infoDict[@"min"] = minData;
		if (maxData)
			infoDict[@"max"] = maxData;
		if (resolutionData)
			infoDict[@"resolution"] = resolutionData;
		if (currentData)
			infoDict[@"current"] = currentData;
		if (defaultData)
			infoDict[@"default"] = defaultData;
	}
	
	NSLog(@"  %@ = %@", setting, infoDict);
	self.settingsInfos[setting] = infoDict;
}

- (void) queryControlInfos
{
	PtpLog(@"supported settings %@", self.supportedSettings);
	for (id setting in self.supportedSettings)
	{
		// skip unsupported settings
		if (![self.supportedSettings[setting] boolValue])
			continue;
		
		NSNumber* selno = settingsSelectors[setting];
		
		if (nil != selno)
		{
			[self readSettingInfo: setting];
		}
	}
}

- (uint16_t) queryLengthForSetting: (id) setting
{
	size_t selector = [settingsSelectors[setting] unsignedLongValue];
	size_t unitId = [settingsUnits[setting] unsignedLongValue];

	uint16_t len = 0;
	IOUSBDevRequest request = {
		.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBClass, kUSBInterface),
		.bRequest = GET_LEN,
		.wValue = selector << 8,
		.wIndex = unitId << 8,
		.wLength = 2,
		.wLenDone = 0,
		.pData = &len,
	};
	if ([self sendUsbControlRequest: request])
	{
//		NSLog(@"SELECTOR 0x%02zX of 0x%02zX len 0x%04X", selector, unitId, len);
		
		return len;
	}
	return 0;
}

- (BOOL) queryMinValueForSetting: (id) setting into: (NSData**) dataPtr
{
	return [self get: GET_MIN forSetting: setting into: dataPtr];
}

- (BOOL) queryMaxValueForSetting: (id) setting into: (NSData**) dataPtr
{
	return [self get: GET_MAX forSetting: setting into: dataPtr];
}

- (BOOL) queryResolutionForSetting: (id) setting into: (NSData**) dataPtr
{
	return [self get: GET_RES forSetting: setting into: dataPtr];
}

- (BOOL) queryCurrentValueForSetting: (id) setting into: (NSData**) dataPtr
{
	return [self get: GET_CUR forSetting: setting into: dataPtr];
}

- (BOOL) queryDefaultValueForSetting: (id) setting into: (NSData**) dataPtr
{
	return [self get: GET_DEF forSetting: setting into: dataPtr];
}

- (NSNumber*) rawValueForSetting: (id) setting fromData: (NSData*) data
{
	bool isSigned = false;
	NSInteger len = [settingsLengths[setting] integerValue];
	if (len < 0)
	{
		len = -len;
		isSigned = true;
	}

	if (!isSigned)
	{
		if (data.length == 1)
		{
			uint8_t val = 0;
			[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
			return @(val);
		}
		else if (data.length == 2)
		{
			uint16_t val = 0;
			[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
			return @(val);
		}
		else if (data.length == 4)
		{
			uint32_t val = 0;
			[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
			return @(val);
		}
		else
			return nil;
	}
	else
	{
		if (data.length == 1)
		{
			int8_t val = 0;
			[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
			return @(val);
		}
		else if (data.length == 2)
		{
			int16_t val = 0;
			[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
			return @(val);
		}
		else if (data.length == 4)
		{
			int32_t val = 0;
			[data getBytes: &val range: NSMakeRange(0, sizeof(val))];
			return @(val);
		}
		else
			return nil;

	}
}

- (BOOL) get: (uint8_t) query forSetting: (id) setting into: (NSData**) dataPtr
{
	size_t selector = [settingsSelectors[setting] unsignedLongValue];
	size_t unitId = [settingsUnits[setting] unsignedLongValue];
	NSInteger len = [settingsLengths[setting] integerValue];
	if (len < 0)
		len = -len;
	NSMutableData* data = [NSMutableData dataWithLength: len];
	IOUSBDevRequest request = {
		.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBClass, kUSBInterface),
		.bRequest = query,
		.wValue = selector << 8,
		.wIndex = unitId << 8,
		.wLength = len,
		.wLenDone = 0,
		.pData = data.mutableBytes,
	};
	if ([self sendUsbControlRequest: request])
	{
//		NSLog(@"GET 0x%02X SEL 0x%02zX of 0x%02zX data %@", query, selector, unitId, data);
		
		*dataPtr = data;
		return YES;
	}
	return NO;

}

- (BOOL) setCurrentData: (NSData*) data forSetting: (id) setting
{
	size_t selector = [settingsSelectors[setting] unsignedLongValue];
	size_t unitId = [settingsUnits[setting] unsignedLongValue];

	IOUSBDevRequest request = {
		.bmRequestType = USBmakebmRequestType(kUSBOut, kUSBClass, kUSBInterface),
		.bRequest = SET_CUR,
		.wValue = selector << 8,
		.wIndex = unitId << 8,
		.wLength = data.length,
		.wLenDone = 0,
		.pData = (void*)data.bytes,
	};
	if ([self sendUsbControlRequest: request])
	{
//		NSLog(@"SET SEL 0x%02zX of 0x%02zX data %@", selector, unitId, data);
		
		return YES;
	}
	return NO;

}

- (BOOL) setCurrentValue: (NSNumber*) value forSetting: (id) setting
{
	NSInteger len = [settingsLengths[setting] integerValue];
	if (len < 0)
		len = -len;
	
	NSData* data = nil;
	switch(len)
	{
		case 1:
		{
			uint8_t val = value.unsignedCharValue;
			data = [NSData dataWithBytes: &val length: sizeof(val)];
			break;
		}
		case 2:
		{
			uint16_t val = value.unsignedShortValue;
			data = [NSData dataWithBytes: &val length: sizeof(val)];
			break;
		}
		case 4:
		{
			uint32_t val = value.unsignedIntValue;
			data = [NSData dataWithBytes: &val length: sizeof(val)];
			break;
		}
		case 8:
		{
			uint64_t val = value.unsignedLongValue;
			data = [NSData dataWithBytes: &val length: sizeof(val)];
			break;
		}
		default:
			NSLog(@"Unknown data length %zu for setting %@", len, setting);
			return NO;
	}
	
	return [self setCurrentData: data forSetting: setting];
	
}

- (uint8_t) queryInfoForSetting: (id) setting
{
	size_t selector = [settingsSelectors[setting] unsignedLongValue];
	size_t unitId = [settingsUnits[setting] unsignedLongValue];

	uint8_t info = 0;
	IOUSBDevRequest request = {
		.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBClass, kUSBInterface),
		.bRequest = GET_INFO,
		.wValue = selector << 8,
		.wIndex = unitId << 8,
		.wLength = 1,
		.wLenDone = 0,
		.pData = &info,
	};
	if ([self sendUsbControlRequest: request])
	{
//		NSLog(@"SELECTOR 0x%02zX of 0x%02zX can 0x%02X", selector, unitId, info);
		
		return info;
	}
	else
	{
		PtpLog(@"failed to GET_INFO for %@", setting);
		return 0;
	}
}

- (BOOL) sendUsbControlRequest: (IOUSBDevRequest) request
{
	if (!controlInterface)
	{
		NSLog(@"OOPS, no control interface to send request!");
		return NO;
	}
	
	IOReturn err = 0;
	
	err = (*controlInterface)->USBInterfaceOpen(controlInterface);
	if (err != kIOReturnSuccess)
	{
		NSLog(@"OOPS, could not open control interface because 0x%08X!", err);
		return NO;
	}
	
	err = (*controlInterface)->ControlRequest(controlInterface, 0, &request);
	if (err != kIOReturnSuccess)
	{
		switch (err)
		{
			case kIOUSBPipeStalled:
				// Pipe stalled is how devices respond when the request is unsupported
//				NSLog(@"OOPS, could not send control request because pipe stalled, this probably means that the request is not supported.");
				break;
			default:
				NSLog(@"OOPS, could not send control request because 0x%08X!", err);
				break;
		}
		return NO;
	}
	
	(*controlInterface)->USBInterfaceClose(controlInterface);

	return YES;
}

- (size_t) parseEndpointDescriptor: (IOUSBEndpointDescriptorPtr) epdesc ofMaxLength: (size_t) maxLength
{
	// bDescriptorType 0x05 (endpoint descriptor)
//	NSLog(@"  endpoint length   0x%02X", epdesc->bLength);
//	NSLog(@"  endpoint type     0x%02X", epdesc->bDescriptorType);
//	NSLog(@"  endpoint addr     0x%02X", epdesc->bEndpointAddress);
//	NSLog(@"  endpoint max size 0x%04X", epdesc->wMaxPacketSize);
	assert(epdesc->bDescriptorType == 0x05);
	
	
	return epdesc->bLength;
}

- (size_t) parseProcessingUnitDescriptor: (UVCProcessingUnitDescriptor*) desc ofMaxLength: (size_t) maxLength
{
	assert(desc->bLength >= 11); // should be 13 according to spec, but last 2 fields apparently can be missing
//	assert(desc->bControlSize == 3);
	
//	NSLog(@"  PU_CONTROLS 0x %02X %02X %02X", desc->bmControls[0], desc->bmControls[1], desc->bmControls[2]);
	
	maxDigitalMultiplier = desc->wMaxMultiplier;
	processingUnitId = desc->bUnitId;

	// check which settings are supported
	for (id setting in puSettingsBits)
	{
		NSNumber* bitno = puSettingsBits[setting];
		size_t n = bitno.unsignedIntValue;
		size_t byte = n / 8;
		size_t bit = n - byte*8;
		
		if (desc->bControlSize > byte)
		{
			bool hasSetting = (0 != (desc->bmControls[byte] & (1 << bit)));
			
			if (hasSetting)
			{
				processingUnitSettings[setting] = @YES;
				self.supportedSettings[setting] = @YES;
				settingsUnits[setting] = @(processingUnitId);
			}
		}
	}


//	NSLog(@"  PU supports: %@ @ ID %u", processingUnitSettings, processingUnitId);

	return desc->bLength;
}

- (size_t) parseCameraTerminalDescriptor: (UVCCameraTerminalDescriptor*) desc ofMaxLength: (size_t) maxLength
{
	assert(desc->bLength == 18);
	assert(desc->bControlSize == 3);
	
//	NSLog(@"  ITT_CAMERA   0x %02X %02X %02X", desc->bmControls[0], desc->bmControls[1], desc->bmControls[2]);
	
	cameraTerminalId = desc->bTerminalID;

	// check which settings are supported
	for (id setting in ctSettingsBits)
	{
		NSNumber* bitno = ctSettingsBits[setting];
		size_t n = bitno.unsignedIntValue;
		size_t byte = n / 8;
		size_t bit = n - byte*8;
		
		if (desc->bControlSize > byte)
		{
			bool hasSetting = (0 != (desc->bmControls[byte] & (1 << bit)));
			
			if (hasSetting)
			{
				cameraTerminalSettings[setting] = @YES;
				self.supportedSettings[setting] = @YES;
				settingsUnits[setting] = @(cameraTerminalId);
			}
		}
	}
	

//	NSLog(@"  Camera supports: %@ @ ID %u", cameraTerminalSettings, cameraTerminalId);

	return desc->bLength;
}


- (size_t) parseInputTerminalDescriptor: (UVCInputTerminalDescriptor*) desc ofMaxLength: (size_t) maxLength
{
//	NSLog(@"  ITT terminalID   0x%02X", desc->bTerminalID);
//	NSLog(@"  ITT terminalType 0x%04X", desc->wTerminalType);

	switch (desc->wTerminalType)
	{
		case ITT_CAMERA:
			return [self parseCameraTerminalDescriptor: (UVCCameraTerminalDescriptor*)desc ofMaxLength: maxLength];
		default:
			return desc->bLength;
	}
}


- (size_t) parseCsInterfaceDescriptor: (UVCTypedDescriptorHeader*) desc ofMaxLength: (size_t) maxLength
{
//	NSLog(@"  CS_INTERFACE len     0x%02X", desc->bLength);
//	NSLog(@"  CS_INTERFACE type    0x%02X", desc->bDescriptorType);
//	NSLog(@"  CS_INTERFACE subtype 0x%02X", desc->bDescriptorSubType);
	
	switch (desc->bDescriptorSubType)
	{
		case VC_HEADER:
			return [self parseCsInterfaceDescriptorHeader: (void*)desc ofMaxLength: maxLength];
		case VC_INPUT_TERMINAL:
			return [self parseInputTerminalDescriptor: (void*)desc ofMaxLength: maxLength];
		case VC_PROCESSING_UNIT:
			return [self parseProcessingUnitDescriptor: (void*)desc ofMaxLength: maxLength];
		default:
			NSLog(@"Unknown CS_INTERFACE subtype 0x%02X, skipping...", desc->bDescriptorSubType);
			return desc->bLength;
	}
}

- (size_t) parseCsInterfaceDescriptorHeader: (UVCInterfaceDescriptorHeader*) desc ofMaxLength: (size_t) maxLength
{
//	NSLog(@"  IF header len     0x%02X", desc->bLength);
//	NSLog(@"  IF header type    0x%02X", desc->bDescriptorType);
//	NSLog(@"  IF header subtype 0x%02X", desc->bDescriptorSubType);
//	NSLog(@"  IF header total   0x%04X", desc->wTotalLength);
	NSLog(@"  IF header bcdUVC  0x%02X", desc->bcdUVC);

	size_t offset = desc->bLength;
	maxLength -= desc->bLength;
	
	while (offset < desc->wTotalLength) {
		IOUSBDescriptor* subdesc = (void*)((uint8_t*)desc + offset);
		size_t len = [self parseUsbDescriptor: subdesc ofMaxLength: desc->wTotalLength - offset];
		offset += len;
		maxLength -= len;
	}
	
	return desc->wTotalLength;
}

- (size_t) parseInterfaceDescriptor: (IOUSBInterfaceDescriptor*) ifdesc ofMaxLength: (size_t) maxLength
{
	size_t offset = 0;
	// bDescriptorType 0x04 (interface descriptor)
//	NSLog(@"  interface length   0x%02X", ifdesc->bLength);
//	NSLog(@"  interface type     0x%02X", ifdesc->bDescriptorType);
//	NSLog(@"  interface class    0x%02X", ifdesc->bInterfaceClass);
//	NSLog(@"  interface subclass 0x%02X", ifdesc->bInterfaceSubClass);
	assert(ifdesc->bLength == 9);
	assert(ifdesc->bDescriptorType == 0x04);
	
	offset += ifdesc->bLength;
	maxLength -= ifdesc->bLength;
	
//	bool isUvcCtrlInterface = (ifdesc->bInterfaceClass == kUSBVideoInterfaceClass) && (ifdesc->bInterfaceSubClass == kUSBVideoControlSubClass);
//
//	if (isUvcCtrlInterface)
//	{
//		NSLog(@"  %u is a UVC/CTRL interface", ifdesc->bInterfaceNumber);
//	}
	
	for (size_t i = 0; i < ifdesc->bNumEndpoints; ++i)
	{
		IOUSBDescriptor* desc = (void*)((uint8_t*)ifdesc + offset);
		size_t len = [self parseUsbDescriptor: desc ofMaxLength: maxLength];
		offset += len;
		maxLength -= len;
	}
	
	return offset;
}


- (void) parseUsbConfigurationDescriptor: (IOUSBConfigurationDescriptorPtr) descriptor
{
	// bDescriptorType 0x02 (configuration descriptor)
	assert(descriptor->bDescriptorType == 0x02);

//	NSLog(@"USB Descriptor of length %u", descriptor->bLength);
//	NSLog(@"                    type %u", descriptor->bDescriptorType);
//	NSLog(@"            total length %u", descriptor->wTotalLength);
//	NSLog(@"              interfaces %u", descriptor->bNumInterfaces);
//	NSLog(@"                  config %u", descriptor->bConfigurationValue);
//	NSLog(@"                 current %u", descriptor->iConfiguration);
	
	size_t offset = descriptor->bLength;
	size_t maxLength = descriptor->wTotalLength - offset;
	for (size_t i = 0; i < descriptor->bNumInterfaces; ++i)
	{
		IOUSBDescriptor* desc = (void*)(((uint8_t*)descriptor) + offset);

		size_t len = [self parseUsbDescriptor: desc ofMaxLength: maxLength];
		offset += len;
		maxLength -= len;
	}
}

- (size_t) parseUsbDescriptor: (IOUSBDescriptor*) desc ofMaxLength: (size_t) maxLength
{
	switch (desc->bDescriptorType)
	{
		// association header, skip
		case 0x04:
			return [self parseInterfaceDescriptor: (IOUSBInterfaceDescriptor*)desc ofMaxLength: maxLength];
		case 0x05:
			return [self parseEndpointDescriptor: (IOUSBEndpointDescriptor*)desc ofMaxLength: maxLength];
		case 0x0B: // IAD, we do nothing with it
			return desc->bLength;
		case CS_INTERFACE:
			return [self parseCsInterfaceDescriptor: (UVCTypedDescriptorHeader*)desc ofMaxLength: maxLength];
		default:
			NSLog(@"unknown descriptor of typ 0x%02X", desc->bDescriptorType);
			return desc->bLength;
	}
}


- (void) dealloc
{
	if (generalInterestNotification)
		IOObjectRelease(generalInterestNotification);
	
	if (controlInterface)
	{
		(*controlInterface)->USBInterfaceClose(controlInterface);
		(*controlInterface)->Release(controlInterface);
	}
}

@end

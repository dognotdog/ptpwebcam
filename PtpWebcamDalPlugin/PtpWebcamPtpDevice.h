//
//  PtpWebcamPtpDevice.h
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 06.06.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamDevice.h"

#import "PtpWebcamPlugin.h"

#import <CoreMediaIo/CMIOHardwarePlugIn.h>
#import <ImageCaptureCore/ImageCaptureCore.h>

#define PTP_TYPE_COMMAND 0x0001

#define PTP_CMD_GETDEVICEINFO	0x1001
#define PTP_CMD_GETNUMOBJECTS	0x1006
//#define PTP_CMD_GETOBJECT		0x1009

#define PTP_CMD_GETPROPDESC		0x1014
#define PTP_CMD_GETPROPVAL		0x1015
#define PTP_CMD_SETPROPVAL		0x1016

#define PTP_CMD_STARTLIVEVIEW	0x9201
#define PTP_CMD_STOPLIVEVIEW	0x9202
#define PTP_CMD_GETLIVEVIEWIMG	0x9203

#define PTP_RSP_OK					0x2001
#define PTP_RSP_INCOMPLETETRANSFER	0x2007
#define PTP_RSP_DEVICEBUSY			0x2019
#define PTP_RSP_NIKON_NOTLIVEVIEW	0xA00B

#define PTP_CMD_NIKON_AFDRIVE			0x90C1
#define PTP_CMD_NIKON_DEVICEREADY		0x90C8
#define PTP_CMD_NIKON_GETVENDORPROPS	0x90CA
#define MTP_CMD_GETOBJECTPROPSSUPPORTED	0x9801
#define PTP_CMD_NIKON_MFDRIVE			0x9204
	#define PTP_NIKON_MFDRIVE_CLOSER	0x00000001
	#define PTP_NIKON_MFDRIVE_FARTHER	0x00000002

#define PTP_PROP_BATTERYLEVEL	0x5001
#define PTP_PROP_WHITEBALANCE	0x5005
#define PTP_PROP_FNUM			0x5007
#define PTP_PROP_FLEN			0x5008
#define PTP_PROP_FOCUSDISTANCE	0x5009
#define PTP_PROP_EXPOSURETIME	0x500D
#define PTP_PROP_EXPOSUREPM		0x500E
#define PTP_PROP_EXPOSUREISO	0x500F
#define PTP_PROP_EXPOSUREBIAS	0x5010

#define PTP_PROP_NIKON_LV_APPLYSETTINGS		0xD17B
#define PTP_PROP_NIKON_LV_MODE				0xD1A0
#define PTP_PROP_NIKON_LV_DRIVEMODE			0xD1A1
#define PTP_PROP_NIKON_LV_STATUS			0xD1A2
#define PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW	0xD1A5
#define PTP_PROP_NIKON_LV_SELECTOR			0xD1A6
#define PTP_PROP_NIKON_LV_WHITEBALANCE		0xD1A7
#define PTP_PROP_NIKON_MOVIE_EXPOSUREBIAS	0xD1AB
#define PTP_PROP_NIKON_LV_IMAGESIZE			0xD1AC
#define PTP_PROP_NIKON_LV_IMAGECOMPRESSION	0xD1BC

#define PTP_EVENT_DEVICEPROPCHANGED			0x4006

enum {
	PTP_DATATYPE_INVALID,
	PTP_DATATYPE_UINT8_RAW,
	PTP_DATATYPE_SINT16_RAW,
	PTP_DATATYPE_UINT16_RAW,
	PTP_DATATYPE_UINT32_RAW,
};

NS_ASSUME_NONNULL_BEGIN

@interface PtpWebcamPtpDevice : PtpWebcamDevice <ICCameraDeviceDelegate>

@property ICCameraDevice* cameraDevice;
@property NSDictionary* ptpDeviceInfo;
@property NSDictionary* ptpPropertyInfos;

@property size_t liveViewHeaderLength;

- (uint32_t) nextTransactionId;

- (instancetype) initWithIcDevice: (ICCameraDevice*) device pluginInterface: (_Nonnull CMIOHardwarePlugInRef) pluginInterface;

- (NSData*) ptpCommandWithType: (uint16_t) type code: (uint16_t) code transactionId: (uint32_t) transId;
- (void) ptpQueryKnownDeviceProperties;

+ (nullable NSDictionary*) supportsCamera: (ICDevice*) camera;

- (BOOL) isPtpOperationSupported: (uint16_t) opId;

@end

NS_ASSUME_NONNULL_END

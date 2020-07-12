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

#define PTP_RSP_OK				0x2001
#define PTP_RSP_NOTLIVEVIEW		0xA00B

#define MTP_CMD_GETOBJECTPROPSSUPPORTED	0x9801

#define PTP_PROP_BATTERYLEVEL	0x5001
#define PTP_PROP_WHITEBALANCE	0x5005
#define PTP_PROP_FNUM			0x5007
#define PTP_PROP_FLEN			0x5008
#define PTP_PROP_FOCUSDISTANCE	0x5009
#define PTP_PROP_EXPOSURETIME	0x500D
#define PTP_PROP_EXPOSUREPM		0x500E
#define PTP_PROP_EXPOSUREISO	0x500F
#define PTP_PROP_EXPOSUREBIAS	0x5010

#define PTP_PROP_NIKON_LV_MODE				0xD1A0
#define PTP_PROP_NIKON_LV_DRIVEMODE			0xD1A1
#define PTP_PROP_NIKON_LV_STATUS			0xD1A2
#define PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW	0xD1A5
#define PTP_PROP_NIKON_LV_SELECTOR			0xD1A6
#define PTP_PROP_NIKON_LV_WHITEBALANCE		0xD1A7

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

- (uint32_t) nextTransactionId;

- (instancetype) initWithIcDevice: (ICCameraDevice*) device;

- (NSData*) ptpCommandWithType: (uint16_t) type code: (uint16_t) code transactionId: (uint32_t) transId;
- (void) ptpQueryKnownDeviceProperties;

@end

NS_ASSUME_NONNULL_END

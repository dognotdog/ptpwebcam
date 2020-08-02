//
//  PtpWebcamAlerts.h
//  PTP Webcam
//
//  Created by Dömötör Gulyás on 25.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#ifndef PtpWebcamAlerts_h
#define PtpWebcamAlerts_h

#import <Foundation/Foundation.h>

bool PtpWebcamIsProcessGuiBlacklisted(void);
void PTPWebcamShowCameraIssueBlockingAlert(NSString* make, NSString* model);

void PtpWebcamShowCatastrophicAlert(NSString* format, ...) NS_FORMAT_FUNCTION(1,2);
void PtpWebcamShowDeviceAlert(NSString* format, ...) NS_FORMAT_FUNCTION(1,2);

#define PtpWebcamShowCatastrophicAlertOnce(format, ...) \
{ 										\
	static bool happenedOnce = false; 	\
	if (!happenedOnce)					\
	{									\
		happenedOnce = true;			\
		PtpWebcamShowCatastrophicAlert(format, ## __VA_ARGS__); \
	}									\
}

#define PtpLog(format, ...) NSLog(@"PTPW %@ %@", NSStringFromSelector(_cmd), [NSString stringWithFormat: format, ## __VA_ARGS__])

#endif /* PtpWebcamAlerts_h */

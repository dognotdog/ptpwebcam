//
//  PtpWebcamAlerts_noGui.m
//  PTP Webcam
//
//  Created by Dömötör Gulyás on 31.08.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Foundation/Foundation.h>

void PtpWebcamShowCatastrophicAlert(NSString* format, ...)
{
    va_list args;
    va_start(args, format);
	NSString* message = [[NSString alloc] initWithFormat: format arguments: args];
	va_end(args);
	
//	NSLog(@"PtpWebcamDalPlugin process name: %@", [[NSProcessInfo processInfo] processName]);
//	NSLog(@"PtpWebcamDalPlugin experienced a catastrophic failure: %@", message);
//
//	if (!PtpWebcamIsProcessGuiBlacklisted())
//	{
//		dispatch_async(dispatch_get_main_queue(), ^{
//			NSAlert *alert = [[NSAlert alloc] init];
//			[alert setMessageText: @"The PTP Webcam DAL Plugin has encountered an unrecoverable error:"];
//			[alert setInformativeText: [NSString stringWithFormat: @"%@\n\nPlease file a bug report.", message]];
//			[alert addButtonWithTitle:@"Bummer."];
//			[alert setAlertStyle: NSAlertStyleCritical];
//			[alert runModal];
//		});
//	}
}

void PtpWebcamShowDeviceAlert(NSString* format, ...)
{
    va_list args;
    va_start(args, format);
	NSString* message = [[NSString alloc] initWithFormat: format arguments: args];
	va_end(args);
	
//	NSLog(@"PtpWebcamDalPlugin process name: %@", [[NSProcessInfo processInfo] processName]);
//	NSLog(@"PtpWebcamDalPlugin experienced a device failure: %@", message);
//
//	if (!PtpWebcamIsProcessGuiBlacklisted())
//	{
//		dispatch_async(dispatch_get_main_queue(), ^{
//			NSAlert *alert = [[NSAlert alloc] init];
//			[alert setMessageText: @"Camera Error"];
//			[alert setInformativeText: message];
////			[alert addButtonWithTitle:@"Bummer."];
//			[alert setAlertStyle: NSAlertStyleWarning];
//			[alert runModal];
//		});
//	}
}

void PtpWebcamShowInfoAlert(NSString* title, NSString* format, ...)
{
    va_list args;
    va_start(args, format);
	NSString* message = [[NSString alloc] initWithFormat: format arguments: args];
	va_end(args);
		
//	if (!PtpWebcamIsProcessGuiBlacklisted())
//	{
//		dispatch_async(dispatch_get_main_queue(), ^{
//			NSAlert *alert = [[NSAlert alloc] init];
//			[alert setMessageText: title];
//			[alert setInformativeText: message];
////			[alert addButtonWithTitle:@"OK"];
//			[alert setAlertStyle: NSAlertStyleInformational];
//			[alert runModal];
//		});
//	}
}

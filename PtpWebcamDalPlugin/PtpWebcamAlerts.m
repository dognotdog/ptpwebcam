//
//  PtpWebcamAlerts.m
//  PTP Webcam
//
//  Created by Dömötör Gulyás on 25.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <AppKit/AppKit.h>

#import "PtpWebcamAlerts.h"

NSArray* PtpWebcamGuiBlacklistedProcesses(void)
{
	// Some processes in which the plugin lives might not have proper UI runloops setup, so things like alerts and the status item might not work right.
	static NSArray* blacklistedProcesses = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		blacklistedProcesses = @[
			@"Google Chrome Helper (Renderer)",
			@"Google Chrome Helper (Plugin)",
//			@"Google Chrome",
			@"Skype Helper (Renderer)",
	//		@"Skype Helper",
	//		@"Skype",
			@"caphost", // zoom's video capture process
	//		@"zoom.us",
		];
	});
	return blacklistedProcesses;
}

bool PtpWebcamIsProcessGuiBlacklisted(void)
{
	NSString *processName = [[NSProcessInfo processInfo] processName];
	NSArray* blacklistedProcesses = PtpWebcamGuiBlacklistedProcesses();
	bool processIsBlacklisted =  ([blacklistedProcesses containsObject: processName]);
	
//	if (!processIsBlacklisted)
//		NSLog(@"PTPWEBCAM Process Name: %@", processName);
	
	return processIsBlacklisted;
}

void PtpWebcamShowCatastrophicAlert(NSString* format, ...)
{
    va_list args;
    va_start(args, format);
	NSString* message = [[NSString alloc] initWithFormat: format arguments: args];
	va_end(args);
	
	NSLog(@"PtpWebcamDalPlugin process name: %@", [[NSProcessInfo processInfo] processName]);
	NSLog(@"PtpWebcamDalPlugin experienced a catastrophic failure: %@", message);
	
	if (!PtpWebcamIsProcessGuiBlacklisted())
	{
		dispatch_async(dispatch_get_main_queue(), ^{
			NSAlert *alert = [[NSAlert alloc] init];
			[alert setMessageText: @"The PTP Webcam DAL Plugin has encountered an unrecoverable error:"];
			[alert setInformativeText: [NSString stringWithFormat: @"%@\n\nPlease file a bug report.", message]];
			[alert addButtonWithTitle:@"Bummer."];
			[alert setAlertStyle: NSAlertStyleCritical];
			[alert runModal];
		});
	}
}

void PtpWebcamShowDeviceAlert(NSString* format, ...)
{
    va_list args;
    va_start(args, format);
	NSString* message = [[NSString alloc] initWithFormat: format arguments: args];
	va_end(args);
	
	NSLog(@"PtpWebcamDalPlugin process name: %@", [[NSProcessInfo processInfo] processName]);
	NSLog(@"PtpWebcamDalPlugin experienced a device failure: %@", message);
	
	if (!PtpWebcamIsProcessGuiBlacklisted())
	{
		dispatch_async(dispatch_get_main_queue(), ^{
			NSAlert *alert = [[NSAlert alloc] init];
			[alert setMessageText: @"Camera Error"];
			[alert setInformativeText: message];
//			[alert addButtonWithTitle:@"Bummer."];
			[alert setAlertStyle: NSAlertStyleWarning];
			[alert runModal];
		});
	}
}

/**
 We want this function to block as long as the dialog shows, as a crash might be imminent with an unknown camera if we proceed.
 */
void PTPWebcamShowCameraIssueBlockingAlert(NSString* make, NSString* model)
{
	if (!PtpWebcamIsProcessGuiBlacklisted())
	{
		NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
//		NSUserDefaults* defaults = [[NSUserDefaults alloc] initWithSuiteName: @"net.monkeyinthejungle.PtpWebcam"];
		NSString* hasBeenAlertedKey = [NSString stringWithFormat: @"CameraReportAlertedFor%@%@", make, model];
		
		BOOL hasBeenAlerted = [defaults boolForKey: hasBeenAlertedKey];
		
		// only show if the user defaults exist and alert has not been shown prior
		if (!hasBeenAlerted && defaults)
		{
			void (^block)(void) = ^{
				NSAlert *alert = [[NSAlert alloc] init];
				[alert setMessageText: @"PTP Webcam Detected an Untested Camera"];
				[alert setInformativeText: [NSString stringWithFormat: @"We do not have confirmation of a %@ %@ working with PTP Webcam, yet. You can support the project by filing a bug report detailing if your camera works, or if it does not, how it failed.\n\nThis message will not appear again with this application.", make, model]];
				
				NSButton* reportButton = [alert addButtonWithTitle: @"Make a Report…"];
				reportButton.tag = 0;
				NSButton* noButton = [alert addButtonWithTitle: @"No Thanks"];
				noButton.tag = 1;

				[alert setAlertStyle: NSAlertStyleInformational];
				NSInteger result = [alert runModal];
				
				// mark alert having been shown
				[defaults setBool: YES forKey: hasBeenAlertedKey];
				
				// if the report button was selected, send user off to github issues
				if (result == reportButton.tag)
				{
					NSString* body = [@"" stringByAddingPercentEncodingWithAllowedCharacters: [NSCharacterSet URLQueryAllowedCharacterSet]];
					NSString* title = [[NSString stringWithFormat: @"%@ %@ compatibility report", make, model] stringByAddingPercentEncodingWithAllowedCharacters: [NSCharacterSet URLQueryAllowedCharacterSet]];
					NSString* newIssueLink = [NSString stringWithFormat: @"https://github.com/dognotdog/ptpwebcam/issues/new?title=%@&body=%@", title, body];
					
					[[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: newIssueLink]];
				}
			};
			
			if ([NSThread isMainThread])
				block();
			else
				dispatch_sync(dispatch_get_main_queue(), block);
		}
	}
}

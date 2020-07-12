//
//  AppDelegate.m
//  PTP Webcam Preview
//
//  Created by Dömötör Gulyás on 27.05.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "AppDelegate.h"

@interface AppDelegate ()
{
}

@property (weak) IBOutlet NSWindow *window;
@end

static AppDelegate* _sharedAppDelegate = nil;

@implementation AppDelegate

+ (instancetype) sharedAppDelegate
{
	return _sharedAppDelegate;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	_sharedAppDelegate = self;
	
	
//	NSLog(@"devices %@", deviceBrowser.devices);
	
}



- (void)applicationWillTerminate:(NSNotification *)aNotification {
	// Insert code here to tear down your application
	
//	[self stopLiveView];
//	[cameraDevice requestDisableTethering];
//	[cameraDevice requestCloseSession];
}

- (void) dealloc
{
}

@end

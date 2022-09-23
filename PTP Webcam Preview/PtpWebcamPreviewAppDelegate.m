//
//  AppDelegate.m
//  PTP Webcam Preview
//
//  Created by Dömötör Gulyás on 27.05.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamPreviewAppDelegate.h"

#import <objc/runtime.h>


int _printIvars(id obj)
{
	unsigned int count = 0;
	Ivar *vars = class_copyIvarList([obj class], &count);
	for (NSUInteger i = 0; i < count; i++) {
		Ivar var = vars[i];
		NSLog(@"%s %s", ivar_getName(var), ivar_getTypeEncoding(var));
	}
	free(vars);
	return 0;
}

int _printMethods(Class class)
{
	NSLog(@"%s", class_getName(class));
	unsigned int count = 0;
	Method *methods = class_copyMethodList(class, &count);
	for (size_t i = 0; i < count; i++) {
		Method method = methods[i];
		NSLog(@"  %s %s", sel_getName(method_getName(method)), method_getTypeEncoding(method));
	}

	return 0;
}

@interface PtpWebcamPreviewAppDelegate ()
{
}

@property (weak) IBOutlet NSWindow *window;

@end

static PtpWebcamPreviewAppDelegate* _sharedAppDelegate = nil;

@implementation PtpWebcamPreviewAppDelegate

+ (instancetype) sharedAppDelegate
{
	return _sharedAppDelegate;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	_sharedAppDelegate = self;

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

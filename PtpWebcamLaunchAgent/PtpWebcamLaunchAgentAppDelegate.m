//
//  PtpWebcamLaunchAgentAppDelegate.m
//  PtpWebcamLaunchAgent
//
//  Created by Dömötör Gulyás on 02.09.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamLaunchAgentAppDelegate.h"

#import "../PtpWebcamAssistantService/PtpWebcamAssistantServiceProtocol.h"
#import "../PtpWebcamDalPlugin/PtpWebcamAlerts.h"
#import "../PtpWebcamDalPlugin/FoundationExtensions.h"

@interface PtpWebcamLaunchAgentAppDelegate ()

@property (weak) IBOutlet NSWindow *window;
@end

@implementation PtpWebcamLaunchAgentAppDelegate
{
	NSStatusItem* statusItem;
	NSXPCConnection* assistantConnection;
}

- (instancetype) init
{
	if (!(self = [super init]))
		return nil;
	
	self.devices = @{};
	self.connections = @[];
	
	return self;
}

- (void) startListening
{
	NSXPCListener* listener = [[NSXPCListener alloc] initWithMachServiceName: @"org.ptpwebcam.PtpWebcamAgent"];
	listener.delegate = self;
	[listener resume];
	
//	[self startEventStreamHandler];
//	[self setupAssistantXpc];
//
	[self createStatusItem];
}

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection
{
    // This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
	    
    // Configure the connection.
    // First, set the interface that the exported object implements.
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpWebcamAssistantServiceProtocol)];
	
	
	NSXPCInterface* remoteInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpWebcamAssistantDelegateProtocol)];
	
	
	newConnection.remoteObjectInterface = remoteInterface;
    
    // Next, set the object that the connection exports. All messages sent on the connection to this service will be sent to the exported object to handle. The connection retains the exported object.
    newConnection.exportedObject = self;
    
	__weak NSXPCConnection* weakConnection = newConnection;
	newConnection.invalidationHandler = ^{
		PtpLog(@"connection died");
		NSXPCConnection* connection = weakConnection;
		if (connection)
		{
			@synchronized (self) {
				self.connections = [self.connections arrayByRemovingObject: connection];
			}
		}
	};

	@synchronized (self) {
		self.connections = [self.connections arrayByAddingObject: newConnection];
	}

    // Resuming the connection allows the system to deliver more incoming messages.
    [newConnection resume];
	    
    // Returning YES from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call -invalidate on the connection and return NO.
    return YES;
}

- (void) pingService: (void (^)(void)) pongCallback;
{
	pongCallback();
}

- (void) createStatusItem
{

	if (!statusItem)
		statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength: NSVariableStatusItemLength];

	// The text that will be shown in the menu bar
	statusItem.button.title = @"LA";
	

}


- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	[self startListening];
}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
	// Insert code here to tear down your application
}


@end

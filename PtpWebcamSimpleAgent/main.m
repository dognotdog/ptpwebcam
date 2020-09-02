//
//  main.m
//  PtpWebcamSimpleAgent
//
//  Created by Dömötör Gulyás on 01.09.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#import "../PtpWebcamAssistantService/PtpWebcamAssistantServiceProtocol.h"
#import "../PtpWebcamDalPlugin/PtpWebcamAlerts.h"
#import "../PtpWebcamDalPlugin/FoundationExtensions.h"

@interface PtpWebcamAgent : NSObject <NSXPCListenerDelegate, PtpWebcamAssistantServiceProtocol>

@property NSArray* connections;
@property NSDictionary* devices;

- (void) startListening;

@end

@implementation PtpWebcamAgent
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

// this is for consuming com.apple.iokit.matching events
- (void) startEventStreamHandler
{
//	dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
	xpc_set_event_stream_handler("com.apple.iokit.matching", NULL, ^(xpc_object_t _Nonnull object) {
		const char *event = xpc_dictionary_get_string(object, XPC_EVENT_KEY_NAME);
		NSLog(@"%s", event);
//		dispatch_semaphore_signal(semaphore);
	});
//	dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC));

}

- (void) setupAssistantXpc
{
//	assistantConnection = [[NSXPCConnection alloc] initWithMachServiceName: @"org.ptpwebcam.PtpWebcamAssistant" options: 0];
	assistantConnection = [[NSXPCConnection alloc] initWithMachServiceName: @"org.ptpwebcam.PtpWebcamAssistant" options: NSXPCConnectionPrivileged];

//	assistantConnection = [[NSXPCConnection alloc] initWithServiceName: @"org.ptpwebcam.PtpWebcamAssistant"];
//	assistantConnection = [[NSXPCConnection alloc] initWithServiceName: @"org.ptpwebcam.PtpWebcamAssistantService"];

	__weak NSXPCConnection* weakConnection = assistantConnection;
	assistantConnection.invalidationHandler = ^{
		NSLog(@"oops, connection failed: %@", weakConnection);
	};
	assistantConnection.interruptionHandler = ^{
		NSLog(@"oops, connection interrupted: %@", weakConnection);
	};
	assistantConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpWebcamAssistantServiceProtocol)];

	//	NSXPCInterface* cameraInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PtpCameraProtocol)];
	NSXPCInterface* exportedInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PtpWebcamAssistantDelegateProtocol)];
	//	[exportedInterface setInterface: cameraInterface forSelector: @selector(cameraConnected:) argumentIndex: 0 ofReply: NO];

	assistantConnection.exportedObject = self;
	assistantConnection.exportedInterface = exportedInterface;

	[assistantConnection resume];

	// send message to get the service started by launchd
	[[assistantConnection remoteObjectProxy] pingService:^{
		PtpLog(@"assistant pong received.");
	}];

}

- (void) startListening
{
	NSXPCListener* listener = [[NSXPCListener alloc] initWithMachServiceName: @"org.ptpwebcam.PtpWebcamAgent"];
	listener.delegate = self;
	[listener resume];
	
	[self startEventStreamHandler];
//	[self setupAssistantXpc];
//
//	[self createStatusItem];
}

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection
{
    // This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
	    
    // Configure the connection.
    // First, set the interface that the exported object implements.
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpWebcamAssistantServiceProtocol)];
	
//	NSXPCInterface* cameraInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpCameraProtocol)];
	
	NSXPCInterface* remoteInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpWebcamAssistantDelegateProtocol)];
//	[remoteInterface setInterface: cameraInterface forSelector: @selector(cameraConnected:) argumentIndex: 0 ofReply: NO];
	
	
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

@end


int main(int argc, const char * argv[]) {
	@autoreleasepool {
	    NSLog(@"Hello, World!");

		
		PtpWebcamAgent* listener = [[PtpWebcamAgent alloc] init];
		
		[listener startListening];
		
		[[NSRunLoop currentRunLoop] run];
		
		NSLog(@"Bye, World!");
	}
    return 0;
//    return NSApplicationMain(argc, argv);
}

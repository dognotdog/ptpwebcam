//
//  main.m
//  PtpWebcamAssistantService
//
//  Created by Dömötör Gulyás on 22.07.2020.
//  Copyright © 2020 InRobCo. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "PtpWebcamAssistantService.h"
#import "PtpWebcamAlerts.h"

@interface ServiceDelegate : NSObject <NSXPCListenerDelegate>
@end

@implementation ServiceDelegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection
{
    // This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
	
	static PtpWebcamAssistantService* sharedService = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		sharedService = [[PtpWebcamAssistantService alloc] init];
	});
    
    // Configure the connection.
    // First, set the interface that the exported object implements.
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpWebcamAssistantServiceProtocol)];
	
//	NSXPCInterface* cameraInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpCameraProtocol)];
	
	NSXPCInterface* remoteInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpWebcamAssistantDelegateProtocol)];
//	[remoteInterface setInterface: cameraInterface forSelector: @selector(cameraConnected:) argumentIndex: 0 ofReply: NO];
	
	
	newConnection.remoteObjectInterface = remoteInterface;
    
    // Next, set the object that the connection exports. All messages sent on the connection to this service will be sent to the exported object to handle. The connection retains the exported object.
    newConnection.exportedObject = sharedService;
    
	newConnection.invalidationHandler = ^{
		PtpLog(@"connection died");
		@synchronized (sharedService) {
			NSMutableArray* connections = sharedService.connections.mutableCopy;
			[connections removeObject: newConnection];
			sharedService.connections = connections;
		}
	};

	@synchronized (sharedService) {
		sharedService.connections = [sharedService.connections arrayByAddingObject: newConnection];
	}

    // Resuming the connection allows the system to deliver more incoming messages.
    [newConnection resume];
    
    // Returning YES from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call -invalidate on the connection and return NO.
    return YES;
}

@end

int main(int argc, const char *argv[])
{
//	assert(NSApplicationLoad());
    // Create the delegate for the service.
    ServiceDelegate *delegate = [[ServiceDelegate alloc] init];
    
    // Set up the one NSXPCListener for this service. It will handle all incoming connections.
    NSXPCListener *listener = [NSXPCListener serviceListener];
    listener.delegate = delegate;
    
    // Resuming the serviceListener starts this service. This method does not return.
    [listener resume];
    return 0;
}

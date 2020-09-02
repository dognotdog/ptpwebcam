//
//  main.m
//  PtpWebcamSimpleAssistant
//
//  Created by Dömötör Gulyás on 01.09.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "../PtpWebcamDalPlugin/PtpWebcamAlerts.h"
#import "../PtpWebcamDalPlugin/FoundationExtensions.h"
#import "../PtpWebcamAssistantService/PtpWebcamAssistantServiceProtocol.h"


#import <Foundation/Foundation.h>
#include <servers/bootstrap.h>

@interface PtpWebcamAssistantListener : NSObject <NSXPCListenerDelegate>

@property NSArray* connections;

@end

@implementation PtpWebcamAssistantListener

- (void) startListening
{
	NSXPCListener* listener = [[NSXPCListener alloc] initWithMachServiceName: @"org.ptpwebcam.PtpWebcamAssistant"];
	listener.delegate = self;
	[listener resume];

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
    
	newConnection.invalidationHandler = ^{
		PtpLog(@"connection died");
		@synchronized (self) {
			self.connections = [self.connections arrayByRemovingObject: newConnection];
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

@end



int main(int argc, const char * argv[]) {
	@autoreleasepool {
	    NSLog(@"Hello, World!");

		
		PtpWebcamAssistantListener* listener = [[PtpWebcamAssistantListener alloc] init];
		
		[listener startListening];
		
		[[NSRunLoop currentRunLoop] run];
		
		NSLog(@"Bye, World!");
	}
	return 0;
}

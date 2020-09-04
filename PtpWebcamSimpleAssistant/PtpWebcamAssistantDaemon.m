//
//  PtpWebcamAssistantDaemon.m
//  PtpWebcamSimpleAssistant
//
//  Created by Dömötör Gulyás on 01.09.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamAssistantDaemon.h"
#import "../PtpWebcamDalPlugin/PtpCamera.h"
#import "../PtpWebcamAssistantService/PtpCameraMachAssistant.h"
#import "../PtpWebcamDalPlugin/PtpWebcamAlerts.h"

@implementation PtpWebcamAssistantDaemon
{
	NSXPCListenerEndpoint* agentEndpoint;
}

- (instancetype) init
{
	if (!(self = [super init]))
		return nil;
	
	self.connections = @[];
	
		return self;
}

#pragma mark Assistant Service Protocol

- (void) startListening
{
//	[self setupAgentXpc];
	NSXPCListener* listener = [[NSXPCListener alloc] initWithMachServiceName: @"org.ptpwebcam.PtpWebcamAssistant"];
	listener.delegate = self;
	[listener resume];

}

#pragma mark Listener Delegate

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection
{
    // This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
	    
    // Configure the connection.
    // First, set the interface that the exported object implements.
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PtpWebcamAssistantXpcProtocol)];
	
//	NSXPCInterface* cameraInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpCameraProtocol)];
	
	NSXPCInterface* remoteInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PtpWebcamAssistantDelegateXpcProtocol)];
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
	
	@synchronized (self) {
		if (agentEndpoint)
		{
			PtpLog(@"setting endpoint to new connection");
			[[newConnection remoteObjectProxy] setAgentEndpoint: agentEndpoint];
		}
	}
    // Returning YES from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call -invalidate on the connection and return NO.
    return YES;
}

#pragma mark Agent Comms

//- (void) setupAgentXpc
//{
//	agentConnection = [[NSXPCConnection alloc] initWithMachServiceName: @"org.ptpwebcam.PtpWebcamAgent" options: 0];
//
//	__weak NSXPCConnection* weakConnection = agentConnection;
//	agentConnection.invalidationHandler = ^{
//		NSLog(@"oops, connection failed: %@", weakConnection);
//	};
//	agentConnection.interruptionHandler = ^{
//		NSLog(@"oops, connection interrupted: %@", weakConnection);
//	};
//	agentConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpWebcamAssistantServiceProtocol)];
//
//	//	NSXPCInterface* cameraInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PtpCameraProtocol)];
//	NSXPCInterface* exportedInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PtpWebcamAssistantDelegateProtocol)];
//	//	[exportedInterface setInterface: cameraInterface forSelector: @selector(cameraConnected:) argumentIndex: 0 ofReply: NO];
//
//	agentConnection.exportedObject = self;
//	agentConnection.exportedInterface = exportedInterface;
//
//	[agentConnection resume];
//
//	// send message to get the service started by launchd
//	[[agentConnection remoteObjectProxy] pingService:^{
//		PtpLog(@"agent pong received.");
//	}];
//
//}


- (void) ping: (NSString*) pingMessage withCallback: (void (^)(NSString* pongMessage)) pongCallback
{
	PtpLog(@"ping received: %@", pingMessage);
	pongCallback(@"assistant");
}

- (void) setAgentEndpoint:(NSXPCListenerEndpoint *)endpoint
{
	PtpLog(@"setting endpoints.");
	agentEndpoint = endpoint;
	for (NSXPCConnection* connection in self.connections)
	{
		[[connection remoteObjectProxy] setAgentEndpoint: endpoint];
	}
}

@end

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
#import "../PtpWebcamDalPlugin/PtpCameraSettingsController.h"

@interface PtpWebcamLaunchAgentAppDelegate ()

@property (weak) IBOutlet NSWindow *window;
@end

@implementation PtpWebcamLaunchAgentAppDelegate
{
	NSStatusItem* statusItem;
	NSXPCConnection* assistantConnection;
	ICDeviceBrowser* deviceBrowser;
	NSXPCListener* agentListener;
	NSXPCListener* anonListener;
}

- (instancetype) init
{
	if (!(self = [super init]))
		return nil;
	
	self.devices = @{};
	self.connections = @[];
	
	return self;
}

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
	assistantConnection = [[NSXPCConnection alloc] initWithMachServiceName: @"org.ptpwebcam.PtpWebcamAssistant" options: NSXPCConnectionPrivileged];

	__weak NSXPCConnection* weakConnection = assistantConnection;
	__weak PtpWebcamLaunchAgentAppDelegate* weakSelf = self;
	
	assistantConnection.invalidationHandler = ^{
		NSXPCConnection* connection = weakConnection;
		PtpLog(@"oops, connection failed: %@", connection);
		
		// retry xpc connection after 1 second if it failed
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			[weakSelf setupAssistantXpc];
		});
	};
	assistantConnection.interruptionHandler = ^{
		PtpLog(@"oops, connection interrupted: %@", weakConnection);
	};
	assistantConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PtpWebcamAssistantXpcProtocol)];

	NSXPCInterface* exportedInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PtpWebcamCameraDelegateXpcProtocol)];

	assistantConnection.exportedObject = self;
	assistantConnection.exportedInterface = exportedInterface;

	[assistantConnection resume];

	// send message to get the service started by launchd
	[[assistantConnection remoteObjectProxy] ping: @"LaunchAgent" withCallback:^(NSString *pongMessage) {
		PtpLog(@"assistant pong received: %@", pongMessage);
	}];
	// communicate our endpoint to the assistant, so the DAL plugin can get it from the assistant
	[[assistantConnection remoteObjectProxy] setAgentEndpoint: anonListener.endpoint];

}

- (void) startListening
{
	anonListener = [NSXPCListener anonymousListener];
	anonListener.delegate = self;
	[anonListener resume];
	PtpLog(@"starting listeners...");
	agentListener = [[NSXPCListener alloc] initWithMachServiceName: @"org.ptpwebcam.PtpWebcamAgent"];
	agentListener.delegate = self;
	[agentListener resume];

	[self startEventStreamHandler];
	[self setupAssistantXpc];
//
//	[self createStatusItem];
}

- (NSDictionary*) infoForConnection: (NSXPCConnection*) connection
{
	for (NSDictionary* info in self.connections)
	{
		if ([info[@"connection"] isEqual: connection])
			return info;
	}
	return nil;
}

- (void) setConnectionInfo: (NSDictionary*) newInfo
{
	for (NSDictionary* info in self.connections)
	{
		if ([info[@"connection"] isEqual: newInfo[@"connection"]])
		{
			self.connections = [self.connections arrayByRemovingObject: info];
			self.connections = [self.connections arrayByAddingObject: newInfo];
		}
	}

}

- (void) decrementStreamCountForCameraId: (id) cameraId
{
	PtpCameraSettingsController* settingsController = self.devices[cameraId];
	if (!settingsController)
		return;
	
	@synchronized (settingsController) {
		int streamCounter = settingsController.streamCounter;
		if (streamCounter == 1)
			[settingsController.camera stopLiveView];
		settingsController.streamCounter = MAX(0, streamCounter-1);
	}
}

- (void) incrementStreamCountForCameraId: (id) cameraId
{
	PtpCameraSettingsController* settingsController = self.devices[cameraId];
	if (!settingsController)
		return;
	
	@synchronized (settingsController) {
		int streamCounter = settingsController.streamCounter;
		if (streamCounter == 0)
			[settingsController.camera startLiveView];
		settingsController.streamCounter = streamCounter+1;
	}
}


- (void) connectionDied: (NSXPCConnection*) connection
{
	NSDictionary* connectionInfo = nil;
	@synchronized (self) {
		connectionInfo = [self infoForConnection: connection];
		if (connectionInfo)
			self.connections = [self.connections arrayByRemovingObject: connectionInfo];
	}
	
	// if connection was subscribed to streams, kill them
	NSSet* liveStreams = connectionInfo[@"liveStreamIds"];
	
	for (id cameraId in liveStreams)
	{
		[self decrementStreamCountForCameraId: cameraId];
		
	}
}

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection
{
	PtpLog(@"incoming connection...");
	if (listener == anonListener)
		PtpLog(@"from anonListener...");

    // This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
	    
    // Configure the connection.
    // First, set the interface that the exported object implements.
    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PtpWebcamCameraXpcProtocol)];
	
	
	NSXPCInterface* remoteInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PtpWebcamCameraDelegateXpcProtocol)];
	
	
	newConnection.remoteObjectInterface = remoteInterface;
    
    // Next, set the object that the connection exports. All messages sent on the connection to this service will be sent to the exported object to handle. The connection retains the exported object.
    newConnection.exportedObject = self;
    
	__weak NSXPCConnection* weakConnection = newConnection;
	newConnection.invalidationHandler = ^{
		PtpLog(@"connection died");
		NSXPCConnection* connection = weakConnection;
		[self connectionDied: connection];
	};

	@synchronized (self) {
		self.connections = [self.connections arrayByAddingObject: @{@"connection" : newConnection}];
	}

    // Resuming the connection allows the system to deliver more incoming messages.
    [newConnection resume];
	
	// tell the connection about the existing cameras
	for (PtpCameraSettingsController* settingsController in self.devices.allValues)
	{
		if (settingsController.camera.isReadyForUse)
		{
			NSDictionary* cameraInfo = [self cameraConnectionInfo: settingsController.camera];
			[[newConnection remoteObjectProxy] cameraConnected: settingsController.camera.cameraId withInfo: cameraInfo];
		}
	}
	    
	PtpLog(@"... connection accepted.");

    // Returning YES from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call -invalidate on the connection and return NO.
    return YES;
}

#pragma mark assistant service

- (void) setAgentEndpoint:(NSXPCListenerEndpoint *)endpoint
{
	// ignore this as its our endpoint.
}

- (void) ping: (NSString*) pingMessage withCallback: (void (^)(NSString* pongMessage)) pongCallback
{
	PtpLog(@"ping received from: %@", pingMessage);
	pongCallback(@"LaunchAgent");
}

- (void) startLiveViewForCamera:(id)cameraId
{
	NSXPCConnection* connection = [NSXPCConnection currentConnection];
	@synchronized (self) {
		NSDictionary* connectionInfo = [self infoForConnection: connection];
		NSSet* liveStreamIds = connectionInfo[@"liveStreamIds"];
		if (!liveStreamIds)
			liveStreamIds = [NSSet set];
		liveStreamIds = [liveStreamIds setByAddingObject: cameraId];
		connectionInfo = [connectionInfo dictionaryBySettingObject: liveStreamIds forKey: @"liveStreamIds"];
		[self setConnectionInfo: connectionInfo];
	}
		
	[self incrementStreamCountForCameraId: cameraId];
}

- (void) stopLiveViewForCamera:(id)cameraId
{
	NSXPCConnection* connection = [NSXPCConnection currentConnection];
	@synchronized (self) {
		NSDictionary* connectionInfo = [self infoForConnection: connection];
		NSSet* liveStreamIds = connectionInfo[@"liveStreamIds"];
		if (liveStreamIds)
		{
			liveStreamIds = [liveStreamIds setByRemovingObject: cameraId];
			connectionInfo = [connectionInfo dictionaryBySettingObject: liveStreamIds forKey: @"liveStreamIds"];
			[self setConnectionInfo: connectionInfo];
		}
	}

	[self decrementStreamCountForCameraId: cameraId];
}


- (void) requestLiveViewImageForCamera:(id)cameraId
{
	PtpCamera* camera = [self.devices[cameraId] camera];

	[camera requestLiveViewImage];
	
}


#pragma mark ICDevice Browser

- (void) device:(ICDevice *)icCamera didOpenSessionWithError:(NSError *)error
{
	NSLog(@"device didOpenSession");
	
	
	if (error)
	{
		NSLog(@"device could not open session because %@", error);
		return;
	}
	
	NSDictionary* cameraInfo = [PtpCamera isDeviceSupported: (id)icCamera];
	Class cameraClass = cameraInfo[@"Class"];
	
	if (![cameraClass enumeratesContentCatalogOnSessionOpen])
	{
		PtpCamera* camera = [PtpCamera cameraWithIcCamera: (id)icCamera delegate: self];

		if (!camera)
		{
			PtpWebcamShowCatastrophicAlert(@"Camera with USB Vendor ID 0x%04X, Product ID 0x%04X could not be instantiated.", icCamera.usbVendorID, icCamera.usbProductID);
			return;
		}

		PtpCameraSettingsController* deviceController = [[PtpCameraSettingsController alloc] initWithCamera: camera];

		@synchronized (self) {
			self.devices = [self.devices dictionaryBySettingObject: deviceController forKey: camera.cameraId];
		}
	}

	
}

- (void) deviceDidBecomeReadyWithCompleteContentCatalog:(ICCameraDevice *) icCamera
{
	PtpLog(@"");
		
	PtpCamera* camera = [PtpCamera cameraWithIcCamera: icCamera delegate: self];
	
	if (!camera)
	{
		PtpWebcamShowCatastrophicAlert(@"Camera with USB Vendor ID 0x%04X, Product ID 0x%04X could not be instantiated.", icCamera.usbVendorID, icCamera.usbProductID);
		return;
	}
	
	PtpCameraSettingsController* deviceController = [[PtpCameraSettingsController alloc] initWithCamera: camera];

	@synchronized (self) {
		self.devices = [self.devices dictionaryBySettingObject: deviceController forKey: camera.cameraId];
	}
}

- (void)deviceBrowser:(ICDeviceBrowser*)browser didAddDevice:(ICDevice*)camera moreComing:(BOOL) moreComing
{
//	NSLog(@"add device %@", device);
	NSDictionary* cameraInfo = [PtpCamera isDeviceSupported: camera];
	if (cameraInfo)
	{
		if (![cameraInfo[@"confirmed"] boolValue])
		{
			PTPWebcamShowCameraIssueBlockingAlert(cameraInfo[@"make"], cameraInfo[@"model"]);
		}
//		NSLog(@"camera capabilities %@", camera.capabilities);
		camera.delegate = self;
		[camera requestOpenSession];

	}
}

- (void)deviceBrowser:(nonnull ICDeviceBrowser *)browser didRemoveDevice:(nonnull ICDevice *)icDevice moreGoing:(BOOL)moreGoing
{
//	NSLog(@"remove device %@", icDevice);
	
	for(id cameraId in self.devices.copy)
	{
		
		PtpCameraSettingsController* settingsController = self.devices[cameraId];
		PtpCamera* camera = settingsController.camera;
		
		[settingsController removeStatusItem];
		
		if ([icDevice isEqual: camera.icCamera])
		{
			// remove camera from devices list
			@synchronized (self) {
				self.devices = [self.devices dictionaryByRemovingObjectForKey: cameraId];
			}
			
			// notify clients that camera is gone
			for (NSDictionary* connectionInfo in self.connections)
			{
				NSXPCConnection* connection = connectionInfo[@"connection"];
				[[connection remoteObjectProxy] cameraDisconnected: camera.cameraId];
			}

		}

	}
}



- (void)device:(nonnull ICDevice *)device didCloseSessionWithError:(nonnull NSError *)error {
}


- (void)didRemoveDevice:(nonnull ICDevice *)device
{
	// do nothing, as we receive a notification from the device browser, roo
}

#pragma mark Camera Delegate

- (void) cameraWasRemoved:(PtpCamera *)camera
{
	// do nothing as we also get device browser callback
}

- (NSDictionary*) cameraConnectionInfo: (PtpCamera*) camera
{
	NSString* serno = camera.icCamera.serialNumberString;
	NSDictionary* cameraInfo = @{
		@"make" : camera.make,
		@"model" : camera.model,
		@"serialNumber" : (serno ? serno : @"no serial number found"),
	};
	return cameraInfo;
}

- (void) cameraDidBecomeReadyForUse: (PtpCamera*) camera
{
	NSDictionary* cameraInfo = [self cameraConnectionInfo: camera];
	for (NSDictionary* connectionInfo in self.connections)
	{
		NSXPCConnection* connection = connectionInfo[@"connection"];
		[[connection remoteObjectProxy] cameraConnected: camera.cameraId withInfo: cameraInfo];
	}
}

- (void) receivedCameraProperty: (NSDictionary*) propertyInfo oldProperty: (NSDictionary*) oldInfo withId: (NSNumber*) propertyId fromCamera: (PtpCamera*) camera
{
	PtpCameraSettingsController* settingsController = self.devices[camera.cameraId];
	
	[settingsController receivedCameraProperty: propertyInfo oldProperty: oldInfo withId: propertyId fromCamera: camera];
}

- (void) receivedLiveViewJpegImage:(NSData *)jpegData withInfo:(NSDictionary *)info fromCamera:(PtpCamera *)camera
{
	for (NSDictionary* connectionInfo in self.connections)
	{
		NSXPCConnection* connection = connectionInfo[@"connection"];
		[[connection remoteObjectProxy] receivedLiveViewJpegImageData: jpegData withInfo: @{} forCameraWithId: camera.cameraId];
	}

}

- (void) cameraDidBecomeReadyForLiveViewStreaming:(PtpCamera *)camera
{
	PtpLog(@"");
	for (NSDictionary* connectionInfo in self.connections)
	{
		NSXPCConnection* connection = connectionInfo[@"connection"];
		[[connection remoteObjectProxy] liveViewReadyforCameraWithId: camera.cameraId];
	}
}

- (void)cameraAutofocusCapabilityChanged:(nonnull PtpCamera *)camera {
	// don't care in this class
}


- (void)cameraFailedToStartLiveView:(nonnull PtpCamera *)camera {
	// don't care in this class
}


- (void)cameraLiveViewStreamDidBecomeInterrupted:(nonnull PtpCamera *)camera {
	// don't care in this class
}


#pragma mark Various

- (void) createStatusItem
{

	if (!statusItem)
		statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength: NSVariableStatusItemLength];

	// The text that will be shown in the menu bar
	statusItem.button.title = @"LA";
	

}

#pragma mark App Delegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	[self startListening];
	
	deviceBrowser = [[ICDeviceBrowser alloc] init];
	deviceBrowser.delegate = self;
	deviceBrowser.browsedDeviceTypeMask |= ICDeviceTypeMaskCamera | ICDeviceLocationTypeMaskLocal;


	[deviceBrowser start];

}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
	// Insert code here to tear down your application
}


@end

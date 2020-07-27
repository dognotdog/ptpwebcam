//
//  PtpWebcamAgentAppDelegate.m
//  PtpWebcamAgent
//
//  Created by Dömötör Gulyás on 23.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamAgentAppDelegate.h"

#import "PtpWebcamAssistantServiceProtocol.h"
#import "PtpWebcamAlerts.h"
#import "../PtpWebcamDalPlugin/PtpWebcamPtp.h"

@interface PtpWebcamAgentAppDelegate ()
{
	NSPort* assistantPort;
	NSPort* agentPort;
	NSStatusItem* statusItem;
}

@end

@implementation PtpWebcamAgentAppDelegate

static NSDictionary* _ptpPropertyNames = nil;
static NSDictionary* _ptpProgramModeNames = nil;
static NSDictionary* _ptpWhiteBalanceModeNames = nil;
static NSDictionary* _ptpLiveViewImageSizeNames = nil;

+ (void)initialize
{
	if (self == [PtpWebcamAgentAppDelegate self])
	{
		_ptpPropertyNames = @{
			@(PTP_PROP_BATTERYLEVEL) : @"Battery Level",
			@(PTP_PROP_WHITEBALANCE) : @"White Balance",
			@(PTP_PROP_FNUM) : @"Aperture",
			@(PTP_PROP_FOCUSDISTANCE) : @"Focus Distance",
			@(PTP_PROP_EXPOSUREPM) : @"Exposure Program Mode",
			@(PTP_PROP_EXPOSUREISO) : @"ISO",
			@(PTP_PROP_EXPOSUREBIAS) : @"Exposure Correction",
			@(PTP_PROP_FLEN) : @"Focal Length",
			@(PTP_PROP_EXPOSURETIME) : @"Exposure Time",
			@(PTP_PROP_NIKON_LV_STATUS) : @"LiveView Status",
			@(PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW) : @"Exposure Preview",
		};
		_ptpProgramModeNames = @{
			@(0x0000) : @"Undefined",
			@(0x0001) : @"Manual",
			@(0x0002) : @"Automatic",
			@(0x0003) : @"Aperture Priority",
			@(0x0004) : @"Shutter Priority",
			@(0x0005) : @"Creative",
			@(0x0006) : @"Action",
			@(0x0007) : @"Portrait",
			// Nikon specific
			@(0x8010) : @"Auto",
			@(0x8011) : @"Portrait",
			@(0x8012) : @"Landscape",
			@(0x8013) : @"Close-up",
			@(0x8014) : @"Sports",
			@(0x8015) : @"Night Portrait",
			@(0x8016) : @"Flash Off Auto",
			@(0x8018) : @"SCENE",
			@(0x8019) : @"EFFECTS",
			@(0x8050) : @"U1",
			@(0x8051) : @"U2",
			@(0x8052) : @"U3",
		};
		_ptpWhiteBalanceModeNames = @{
			@(0x0000) : @"Undefined",
			@(0x0001) : @"Manual",
			@(0x0002) : @"Automatic",
			@(0x0003) : @"One-Push Automatic",
			@(0x0004) : @"Daylight",
			@(0x0005) : @"Flourescent",
			@(0x0006) : @"Tungsten",
			@(0x0007) : @"Flash",
			// Nikon specific
			@(0x8010) : @"Cloudy",
			@(0x8011) : @"Shade",
			@(0x8012) : @"Color Temperature",
			@(0x8013) : @"Preset",
			@(0x8014) : @"Off",
			@(0x8016) : @"Natural Light Auto",
		};

		_ptpLiveViewImageSizeNames = @{
			@(0x0000) : @"Undefined",
			@(0x0001) : @"QVGA",	// 320x240
			@(0x0002) : @"VGA",		// 640x480
			@(0x0003) : @"XGA",		// 1024x768
		};
	}
}

- (void) portDidBecomeInvalid: (NSNotification*) notification
{
	// if we lose connection to the assistant, exit, as it's crashed or the camera was disconnected -- in either case the agent is not needed any longer
	exit(0);
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
	NSArray* args = [[NSProcessInfo processInfo] arguments];
	
	self.cameraId = args[1];
	self.cameraSupportedProperties = @[];
	self.cameraProperties = @{};
	
	agentPort = [NSMachPort port];
	agentPort.delegate = self;
	[[NSRunLoop currentRunLoop] addPort: agentPort forMode: NSRunLoopCommonModes];

	assistantPort = [[NSMachBootstrapServer sharedInstance] portForName: args[2]];
	assistantPort.delegate = self;
	
	[[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(portDidBecomeInvalid:) name: NSPortDidBecomeInvalidNotification object: assistantPort];
	
//	[[NSRunLoop currentRunLoop] addPort: assistantPort forMode: NSRunLoopCommonModes];
	
	if (!assistantPort)
	{
		PtpLog(@"Agent could not open port to assistant on port %@.", args[2]);
		exit(-1);
	}
	
	[self connectToAssistantService];
	
//	// LaunchServices automatically registers a mach service of the same
//	// name as our bundle identifier.
//	NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
//	NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName:bundleId];
//
//	// Create the delegate of the listener.
//	PtpWebcamAgentListenerDelegate *decisionAgent = [[PtpWebcamAgentListenerDelegate alloc] init];
//	listener.delegate = decisionAgent;
//
//	// Begin accepting incoming connections.
//	// For mach service listeners, the resume method returns immediately
//	[listener resume];
}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
	// Insert code here to tear down your application
}

- (void) connectToAssistantService
{

	{
		NSPortMessage* message = [[NSPortMessage alloc] initWithSendPort: assistantPort receivePort: agentPort components: @[[self.cameraId dataUsingEncoding: NSUTF8StringEncoding]]];
		message.msgid = PTP_WEBCAM_AGENT_MSG_GET_CAMERA_INFO;
		[message sendBeforeDate: [NSDate distantFuture]];
	}
	{
		NSPortMessage* message = [[NSPortMessage alloc] initWithSendPort: assistantPort receivePort: agentPort components: @[[self.cameraId dataUsingEncoding: NSUTF8StringEncoding]]];
		message.msgid = PTP_WEBCAM_AGENT_MSG_GET_CAMERA_SUPPORTED_PROPERTIES;
		[message sendBeforeDate: [NSDate distantFuture]];
	}

}

//- (void) connectToAssistantService
//{
////	NSString* agentPath = @"/Library/CoreMediaIO/Plug-ins/DAL/PtpWebcamDalPlugin.plugin/Contents/Library/LoginItems/PtpWebcamAgent.app";
////	OSStatus err =  LSRegisterURL((__bridge CFURLRef)[NSURL fileURLWithPath: agentPath], false);
////	assert(noErr == err);
//
//	assistantConnection = [[NSXPCConnection alloc] initWithMachServiceName: @"org.ptpwebcam.PtpWebcamAssistantService" options: 0];
////	NSString* agentId = @"org.ptpwebcam.PtpWebcamAgent";
////	SMLoginItemSetEnabled((__bridge CFStringRef)agentId, true);
////	assistantConnection = [[NSXPCConnection alloc] initWithMachServiceName: @"org.ptpwebcam.PtpWebcamAgent" options: 0];
//	assistantConnection.invalidationHandler = ^{
//		NSLog(@"oops");
//	};
//	assistantConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpWebcamAssistantServiceProtocol)];
//
////	NSXPCInterface* cameraInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PtpCameraProtocol)];
//	NSXPCInterface* exportedInterface = [NSXPCInterface interfaceWithProtocol: @protocol(PtpWebcamAssistantDelegateProtocol)];
////	[exportedInterface setInterface: cameraInterface forSelector: @selector(cameraConnected:) argumentIndex: 0 ofReply: NO];
//
//	assistantConnection.exportedObject = self;
//	assistantConnection.exportedInterface = exportedInterface;
//
//	[assistantConnection resume];
//
//	// send message to get the service started by launchd
//	[[assistantConnection remoteObjectProxy] pingService:^{
//		PtpLog(@"pong received.");
//	}];
//
//}

- (void) handlePortMessage: (NSPortMessage*) message
{
	switch (message.msgid)
	{
		case PTP_WEBCAM_AGENT_MSG_CAMERA_INFO:
		{
			NSData* infoData = message.components[1];

			NSDictionary* cameraInfo = [NSKeyedUnarchiver unarchiveObjectWithData: infoData];
			
			@synchronized (self) {
				self.cameraInfo = cameraInfo;
			}
			
			break;
		}
		case PTP_WEBCAM_AGENT_MSG_CAMERA_SUPPORTED_PROPERTIES:
		{
			NSArray* supportedProperties = [NSKeyedUnarchiver unarchiveObjectWithData: message.components[1]];

			@synchronized (self) {
				self.cameraSupportedProperties = supportedProperties;
			}

			[self queryAllCameraProperties];

			break;
		}
		case PTP_WEBCAM_AGENT_MSG_CAMERA_PROPERTIES:
		{
//			NSData* cameraIdData = message.components[0];
//			id cameraId = [[NSString alloc] initWithData: cameraIdData encoding: NSUTF8StringEncoding];
			
			id propertiesData = message.components[1];
			
			NSDictionary* properties = [NSKeyedUnarchiver unarchiveObjectWithData: propertiesData];
			
			PtpLog(@"%@", properties);

			@synchronized (self) {
				self.cameraProperties = properties;
			}
			
			dispatch_async(dispatch_get_main_queue(), ^{
				[self rebuildStatusItem];
			});
			
			break;
		}
		case PTP_WEBCAM_AGENT_MSG_CAMERA_PROPERTY:
		{
			id propertyIdData = message.components[1];
			id propertyData = message.components[2];
			NSNumber* propertyId = [NSKeyedUnarchiver unarchiveObjectWithData: propertyIdData];
			NSDictionary* property = [NSKeyedUnarchiver unarchiveObjectWithData: propertyData];
			
			
			
			@synchronized (self) {
				NSMutableDictionary* properties = self.cameraProperties.mutableCopy;
				properties[propertyId] = property;
				self.cameraProperties = properties;
			}

			dispatch_async(dispatch_get_main_queue(), ^{
				[self rebuildStatusItem];
			});

			break;
		}
		default:
		{
			PtpLog(@"camera received unknown message with id %d", message.msgid);
			break;
		}
	}
}


// MARK: User Interface

- (void) queryAllCameraProperties
{
	for (id propertyId in _ptpPropertyNames)
	{
		if ([self.cameraSupportedProperties containsObject: propertyId])
			[self queryCameraProperty: propertyId];
	}

}

- (void) queryCameraProperty: (NSNumber*) propertyId
{
	{
		NSArray* components = @[
			[self.cameraId dataUsingEncoding: NSUTF8StringEncoding],
			[NSKeyedArchiver archivedDataWithRootObject: propertyId],
		];
		NSPortMessage* message = [[NSPortMessage alloc] initWithSendPort: assistantPort receivePort: agentPort components: components];
		message.msgid = PTP_WEBCAM_AGENT_MSG_QUERY_PROPERTY;
		[message sendBeforeDate: [NSDate distantFuture]];
	}

}

- (void) createStatusItem
{
	// do not create status item if stream isn't running to avoid duplicates for apps with multiple processes accessing DAL plugins

	if (!statusItem)
		statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength: NSVariableStatusItemLength];

	// The text that will be shown in the menu bar
	statusItem.button.title = self.cameraInfo[@"name"];
	
	// we could set an image, but the text somehow makes more sense
//	NSBundle *otherBundle = [NSBundle bundleWithIdentifier: @"net.monkeyinthejungle.ptpwebcamdalplugin"];
//	NSImage *image = [otherBundle imageForResource: @"ptpwebcam-logo-22x22"];
//	statusItem.button.image = image;

	// The image that will be shown in the menu bar, a 16x16 black png works best
//	_statusItem.image = [NSImage imageNamed:@"feedbin-logo"];

	// The highlighted image, use a white version of the normal image
//	_statusItem.alternateImage = [NSImage imageNamed:@"feedbin-logo-alt"];

	// The image gets a blue background when the item is selected
//	statusItem.highlightMode = YES;

}

- (void) removeStatusItem
{
	
	[[NSStatusBar systemStatusBar] removeStatusItem: statusItem];
	statusItem = nil;
	
}

- (NSString*) formatValue: (id) value ofType: (int) dataType
{
	NSString* valueString = [NSString stringWithFormat:@"%@", value];
	
	switch (dataType)
	{
		case PTP_PROP_BATTERYLEVEL:
			valueString = [NSString stringWithFormat: @"%.0f %%", [value doubleValue]];
			break;
		case PTP_PROP_FNUM:
			valueString = [NSString stringWithFormat: @"%.1f", 0.01*[value doubleValue]];
			break;
		case PTP_PROP_FOCUSDISTANCE:
			valueString = [NSString stringWithFormat: @"%.0f mm", [value doubleValue]];
			break;
		case PTP_PROP_EXPOSUREBIAS:
			valueString = [NSString stringWithFormat: @"%.3f", 0.001*[value doubleValue]];
			break;
		case PTP_PROP_FLEN:
			valueString = [NSString stringWithFormat: @"%.2f mm", 0.01*[value doubleValue]];
			break;
		case PTP_PROP_EXPOSURETIME:
		{
			double exposureTime = 0.0001*[value doubleValue];
			// FIXME: exposure times like 1/10000 vs. 1/8000 cannot be distinguished do to PTP property resolution of 0.0001s
			if (exposureTime < 1.0)
			{
				valueString = [NSString stringWithFormat: @"1/%.0f s", 1.0/exposureTime];
			}
			else
			{
				valueString = [NSString stringWithFormat: @"%.1f s", exposureTime];
			}
			break;
		}
		case PTP_PROP_EXPOSUREPM:
		{
			NSString* name = [_ptpProgramModeNames objectForKey: value];
			if (!name)
				name =  [NSString stringWithFormat:@"0x%04X", [value unsignedIntValue]];
			
			valueString = name;
			break;
		}
		case PTP_PROP_WHITEBALANCE:
		{
			NSString* name = [_ptpWhiteBalanceModeNames objectForKey: value];
			if (!name)
				name =  [NSString stringWithFormat:@"0x%04X", [value unsignedIntValue]];
			
			valueString = name;
			break;
		}
		case PTP_PROP_NIKON_LV_IMAGESIZE:
		{
			NSString* name = [_ptpLiveViewImageSizeNames objectForKey: value];
			if (!name)
				name =  [NSString stringWithFormat:@"0x%04X", [value unsignedIntValue]];
			
			valueString = name;
			break;
		}
		case PTP_PROP_NIKON_LV_STATUS:
		case PTP_PROP_NIKON_LV_EXPOSURE_PREVIEW:
		{
			valueString = [value boolValue] ? @"On" : @"Off";
			break;
		}
	}

	return valueString;
}

- (void) rebuildStatusItem
{
	if (!statusItem)
	{
		[self createStatusItem];
	}
	
	
	NSMenu* menu = [[NSMenu alloc] init];
	
	for (NSNumber* propertyId in [self.cameraProperties.allKeys sortedArrayUsingSelector: @selector(compare:)])
	{
		NSString* name = _ptpPropertyNames[propertyId];
		NSDictionary* property = self.cameraProperties[propertyId];

		id value = property[@"value"];
		NSString* valueString = [self formatValue: value ofType: propertyId.intValue];
		
		
				
		NSMenuItem* menuItem = [[NSMenuItem alloc] init];
		[menuItem setTitle: [NSString stringWithFormat: @"%@ (%@)", name, valueString]];
		
		// add submenus for writable items
		if ([property[@"rw"] boolValue])
		{
			if ([property[@"range"] isKindOfClass: [NSArray class]])
			{
				NSMenu* submenu = [[NSMenu alloc] init];
				NSArray* values = property[@"range"];
				
				for (id enumVal in values)
				{
					NSString* valStr = [self formatValue: enumVal ofType: propertyId.intValue];

					NSMenuItem* subItem = [[NSMenuItem alloc] init];
					subItem.title =  valStr;
					subItem.target = self;
					subItem.action =  @selector(changeCameraPropertyAction:);
					subItem.tag = propertyId.integerValue;
					
					subItem.representedObject = enumVal;
					
					if ([value isEqual: enumVal])
						subItem.state = NSControlStateValueOn;
					
					[submenu addItem: subItem];

				}
				
				menuItem.submenu = submenu;

			}

		}

		
		[menu addItem: menuItem];
	}
	
	// add autofocus command
	if ([self.cameraInfo[@"canAutofocus"] boolValue])
	{
		[menu addItem: [NSMenuItem separatorItem]];
		NSMenuItem* item = [[NSMenuItem alloc] init];
		item.title =  @"Autofocus…";
		item.target = self;
		item.action =  @selector(autofocusAction:);
		[menu addItem: item];
	}
	
	
	statusItem.menu = menu;

}
- (IBAction) autofocusAction:(NSMenuItem*)sender
{
	NSPortMessage* message = [[NSPortMessage alloc] initWithSendPort: assistantPort receivePort: agentPort components: @[[self.cameraId dataUsingEncoding: NSUTF8StringEncoding]]];
	message.msgid = PTP_WEBCAM_AGENT_MSG_AUTOFOCUS;
	[message sendBeforeDate: [NSDate distantFuture]];

}

- (IBAction) changeCameraPropertyAction:(NSMenuItem*)sender
{
	uint32_t propertyId = (uint32_t)sender.tag;

	{
		NSArray* components = @[
			[self.cameraId dataUsingEncoding: NSUTF8StringEncoding],
			[NSKeyedArchiver archivedDataWithRootObject: @(propertyId)],
			[NSKeyedArchiver archivedDataWithRootObject: sender.representedObject]
		];
		NSPortMessage* message = [[NSPortMessage alloc] initWithSendPort: assistantPort receivePort: agentPort components: components];
		message.msgid = PTP_WEBCAM_AGENT_MSG_SET_PROPERTY_VALUE;
		[message sendBeforeDate: [NSDate distantFuture]];
	}

	[self queryAllCameraProperties];
}


@end

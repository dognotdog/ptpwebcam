//
//  PtpCameraMachAssistant.m
//  PtpWebcamAssistantService
//
//  Created by Dömötör Gulyás on 27.07.2020.
//  Copyright © 2020 InRobCo. All rights reserved.
//

#import "PtpCameraMachAssistant.h"
#import "PtpWebcamAlerts.h"
#import "PtpWebcamAssistantServiceProtocol.h"
#import "PtpWebcamAssistantService.h"
#import "PtpWebcamPtp.h"

@implementation PtpCameraMachAssistant
{
	NSTask* uiAgent;
	NSPort* assistantPort;
	NSPort* agentPort;
	NSString* agentPortName;

}

- (instancetype) init
{
	if (!(self = [super init]))
		return nil;
	
	// setup UI agent plumbing
	// for naming see https://mattrajca.com/2016/09/12/designing-shared-services-for-the-mac-app-sandbox.html
	
	agentPortName = [NSString stringWithFormat: @"ZYF8X9Z6M2.org.ptpwebcam.%@", [[NSUUID UUID] UUIDString]];

	assistantPort = [[NSMachBootstrapServer sharedInstance] servicePortWithName: agentPortName];

	if (!assistantPort)
	{
		PtpWebcamShowCatastrophicAlert(@"Assistant Service Could not create UI agent Mach port with name %@.", agentPortName);
		return nil;
	}
	
	assistantPort.delegate = self;
	[[NSRunLoop currentRunLoop] addPort: assistantPort forMode: NSRunLoopCommonModes];

	return self;
}

- (void) receivedCameraProperty:(NSDictionary *)propertyInfo oldProperty: (NSDictionary*) oldInfo withId:(NSNumber *)propertyId fromCamera:(PtpCamera *)camera
{
	// finally send off message to UI agent
	if (agentPort)
	{
		NSArray* components = @[
			[camera.cameraId dataUsingEncoding: NSUTF8StringEncoding],
			[NSKeyedArchiver archivedDataWithRootObject: propertyId],
			[NSKeyedArchiver archivedDataWithRootObject: propertyInfo],
		];
		NSPortMessage* message = [[NSPortMessage alloc] initWithSendPort: agentPort receivePort: assistantPort components: components];
		message.msgid = PTP_WEBCAM_AGENT_MSG_CAMERA_PROPERTY;
		[message sendBeforeDate: [NSDate distantFuture]];

	}

}

- (void) receivedLiveViewJpegImage: (NSData*) jpegData withInfo: (NSDictionary*) info fromCamera: (PtpCamera*) camera
{
	[self.service camera: camera didReceiveLiveViewJpegImage: jpegData withInfo: info];

}


- (void) launchUserInterfaceAgent
{
	NSLog(@"%@", NSStringFromSelector(_cmd));
	
	// launch agent
	NSString* agentPath = @"/Library/CoreMediaIO/Plug-Ins/DAL/PTPWebcamDALPlugin.plugin/Contents/Resources/PtpWebcamAgent.app";
	
	NSBundle* agentBundle = [NSBundle bundleWithPath: agentPath];
	
//	int pid = [[NSProcessInfo processInfo] processIdentifier];
	
	uiAgent = [[NSTask alloc] init];
	
	uiAgent.arguments = @[self.camera.cameraId, agentPortName];
	
	uiAgent.terminationHandler = ^(NSTask * agentTask) {
		self->uiAgent = nil;
	};

	if (@available(macOS 10.13, *))
	{
		uiAgent.executableURL = agentBundle.executableURL;
		NSError* error;
		if (![uiAgent launchAndReturnError: &error])
		{
			NSLog(@"Launching Camera UI Agent Task failed with error: %@", error);
		}
	}
	else
	{
		uiAgent.launchPath = agentBundle.executablePath;
		[uiAgent launch];
	}
}

- (void) terminateUserInterfaceAgent
{
	[uiAgent terminate];
	uiAgent = nil;
}

- (void) handlePortMessage: (NSPortMessage*) message
{
	// we can send to the agent after we received its first message with the correct port
	if (message.sendPort)
	{
		agentPort = message.sendPort;
	}
	
	NSData* cameraIdData = message.components[0];

	switch (message.msgid)
	{
		case PTP_WEBCAM_AGENT_MSG_GET_CAMERA_INFO:
		{
			BOOL canAutofocus = [self.camera isPtpOperationSupported: PTP_CMD_NIKON_AFDRIVE];
			NSDictionary* cameraInfo = @{
				@"canAutofocus" : @(canAutofocus),
				@"name" : self.camera.model,
			};
			
			NSArray* components = @[
				cameraIdData,
				[NSKeyedArchiver archivedDataWithRootObject: cameraInfo],
			];
			
			NSPortMessage* response = [[NSPortMessage alloc] initWithSendPort: message.sendPort receivePort: assistantPort components: components];
			response.msgid = PTP_WEBCAM_AGENT_MSG_CAMERA_INFO;
			
			[response sendBeforeDate: [NSDate distantFuture]];
			break;
		}
		case PTP_WEBCAM_AGENT_MSG_GET_CAMERA_SUPPORTED_PROPERTIES:
		{
			NSArray* components = @[
				cameraIdData,
				[NSKeyedArchiver archivedDataWithRootObject: self.camera.ptpDeviceInfo[@"properties"]],
			];
			
			NSPortMessage* response = [[NSPortMessage alloc] initWithSendPort: message.sendPort receivePort: assistantPort components: components];
			response.msgid = PTP_WEBCAM_AGENT_MSG_CAMERA_SUPPORTED_PROPERTIES;
			
			[response sendBeforeDate: [NSDate distantFuture]];

			break;
		}
		case PTP_WEBCAM_AGENT_MSG_GET_CAMERA_PROPERTIES:
		{
//			id cameraId = [[NSString alloc] initWithData: cameraIdData encoding: NSUTF8StringEncoding];
			
//			PtpCamera* camera = self.devices[cameraId];
			
			NSDictionary* infos = self.camera.ptpPropertyInfos;
			NSData* infoData = [NSKeyedArchiver archivedDataWithRootObject: infos];
			
			NSPortMessage* response = [[NSPortMessage alloc] initWithSendPort: message.sendPort receivePort: assistantPort components: @[cameraIdData, infoData]];
			response.msgid = PTP_WEBCAM_AGENT_MSG_CAMERA_PROPERTIES;
			
			[response sendBeforeDate: [NSDate distantFuture]];
			
			break;
		}
		case PTP_WEBCAM_AGENT_MSG_SET_PROPERTY_VALUE:
		{
			NSNumber* propertyId = [NSKeyedUnarchiver unarchiveObjectWithData: message.components[1]];
			id propertyValue = [NSKeyedUnarchiver unarchiveObjectWithData: message.components[2]];

			[self.camera ptpSetProperty: [propertyId unsignedIntValue] toValue: propertyValue];

			[self.camera ptpQueryKnownDeviceProperties];

			break;
		}
		case PTP_WEBCAM_AGENT_MSG_QUERY_PROPERTY:
		{
			NSNumber* propertyId = [NSKeyedUnarchiver unarchiveObjectWithData: message.components[1]];
			[self.camera ptpGetPropertyDescription: [propertyId unsignedIntValue]];
			break;
		}
		case PTP_WEBCAM_AGENT_MSG_AUTOFOCUS:
		{
			[self.camera requestSendPtpCommandWithCode: PTP_CMD_NIKON_AFDRIVE];
			break;
		}
		default:
		{
			PtpLog(@"camera received unknown message with id %d", message.msgid);
			break;
		}
	}
}

- (void) cameraDidBecomeReadyForUse: (PtpCamera*) camera
{
	[self.service cameraReady: camera];
	[self launchUserInterfaceAgent];
}

- (void) cameraDidBecomeReadyForLiveViewStreaming: (PtpCamera*) camera
{
	[self.service cameraLiveViewReady: camera];
}


- (void) cameraWasRemoved: (PtpCamera*) camera
{
	[self terminateUserInterfaceAgent];
}

- (void)cameraFailedToStartLiveView:(nonnull PtpCamera *)camera {
	
}


- (void)cameraLiveViewStreamDidBecomeInterrupted:(nonnull PtpCamera *)camera {
	
}



@end

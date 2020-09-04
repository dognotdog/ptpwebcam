//
//  PtpWebcamAssistantServiceProtocol.h
//  PtpWebcamAssistantService
//
//  Created by Dömötör Gulyás on 22.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef enum {
	PTP_WEBCAM_AGENT_MSG_INVALID = 0,
	PTP_WEBCAM_AGENT_MSG_GET_CAMERA_INFO,
	PTP_WEBCAM_AGENT_MSG_CAMERA_INFO,
	PTP_WEBCAM_AGENT_MSG_GET_CAMERA_PROPERTIES,
	PTP_WEBCAM_AGENT_MSG_CAMERA_PROPERTIES,
	PTP_WEBCAM_AGENT_MSG_GET_CAMERA_SUPPORTED_PROPERTIES,
	PTP_WEBCAM_AGENT_MSG_CAMERA_SUPPORTED_PROPERTIES,
	PTP_WEBCAM_AGENT_MSG_CAMERA_PROPERTY,
	PTP_WEBCAM_AGENT_MSG_AUTOFOCUS,
	PTP_WEBCAM_AGENT_MSG_SET_PROPERTY_VALUE,
	PTP_WEBCAM_AGENT_MSG_QUERY_PROPERTY,
//	PTP_WEBCAM_AGENT_MSG_ERR_CAMERA_INVALID,
} ptpWebcamAgentMessageId_t;

@protocol PtpWebcamAssistantDelegateXpcProtocol

- (void) setAgentEndpoint: (NSXPCListenerEndpoint*) endpoint;

@end

@protocol PtpWebcamAssistantXpcProtocol <PtpWebcamAssistantDelegateXpcProtocol>

- (void) ping: (NSString*) pingMessage withCallback: (void (^)(NSString* pongMessage)) pongCallback;

@end


// The protocol that this service will vend as its API. This header file will also need to be visible to the process hosting the service.
@protocol PtpWebcamCameraXpcProtocol

- (void) ping: (NSString*) pingMessage withCallback: (void (^)(NSString* pongMessage)) pongCallback;

- (void) startLiveViewForCamera: (id) cameraId;
- (void) stopLiveViewForCamera: (id) cameraId;

- (void) requestLiveViewImageForCamera: (id) cameraId;

@end

@protocol PtpWebcamCameraDelegateXpcProtocol <PtpWebcamAssistantDelegateXpcProtocol, PtpWebcamAssistantXpcProtocol>

- (void) cameraConnected: (id) cameraId withInfo: (NSDictionary*) info;
- (void) cameraDisconnected: (id) cameraId;

- (void) propertyChanged: (NSDictionary*) property forCameraWithId: (id) cameraId;

- (void) liveViewReadyforCameraWithId: (id) cameraId;

- (void) receivedLiveViewJpegImageData: (NSData*) jpegData withInfo: (NSDictionary*) info forCameraWithId: (id) cameraId;

@end



/*
 To use the service from an application or other process, use NSXPCConnection to establish a connection to the service by doing something like this:

     _connectionToService = [[NSXPCConnection alloc] initWithServiceName:@"org.ptpwebcam.PtpWebcamAssistantService"];
     _connectionToService.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(PtpWebcamAssistantServiceProtocol)];
     [_connectionToService resume];

Once you have a connection to the service, you can use it like this:

     [[_connectionToService remoteObjectProxy] upperCaseString:@"hello" withReply:^(NSString *aString) {
         // We have received a response. Update our text field, but do it on the main thread.
         NSLog(@"Result string was: %@", aString);
     }];

 And, when you are finished with the service, clean up the connection like this:

     [_connectionToService invalidate];
*/

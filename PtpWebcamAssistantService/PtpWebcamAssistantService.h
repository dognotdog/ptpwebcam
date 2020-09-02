//
//  PtpWebcamAssistantService.h
//  PtpWebcamAssistantService
//
//  Created by Dömötör Gulyás on 22.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "PtpWebcamAssistantServiceProtocol.h"
#import "PtpCameraMachAssistant.h"

#import <ImageCaptureCore/ICDeviceBrowser.h>


void PtpWebcamShowCatastrophicAlert(NSString* format, ...);

@class PtpCamera;


// This object implements the protocol which we have defined. It provides the actual behavior for the service. It is 'exported' by the service to make it available to the process hosting the service over an NSXPCConnection.
@interface PtpWebcamAssistantService : NSObject <PtpWebcamMachAssistantDaemonProtocol, PtpWebcamAssistantServiceProtocol, ICDeviceBrowserDelegate, ICDeviceDelegate, NSXPCListenerDelegate>

@property NSDictionary* devices;

@property NSArray* connections; // XPC conncetions

- (void) cameraReady: (PtpCamera*) camera;
//- (void) camera: (PtpCamera*) camera propertyChanged: (NSDictionary*) propertyInfo;
- (void) camera: (PtpCamera*) camera didReceiveLiveViewJpegImage: (NSData*) jpegData withInfo: (NSDictionary*) info;
- (void) cameraLiveViewReady: (PtpCamera*) camera;

@end

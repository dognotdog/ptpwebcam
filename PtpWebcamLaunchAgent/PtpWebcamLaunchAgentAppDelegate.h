//
//  PtpWebcamLaunchAgentAppDelegate.h
//  PtpWebcamLaunchAgent
//
//  Created by Dömötör Gulyás on 02.09.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "../PtpWebcamAssistantService/PtpWebcamAssistantServiceProtocol.h"
#import "../PtpWebcamDalPlugin/PtpCamera.h"

#import <ImageCaptureCore/ICDeviceBrowser.h>

@class PtpWebcamStreamView;

@interface PtpWebcamLaunchAgentAppDelegate : NSObject <NSApplicationDelegate, NSXPCListenerDelegate, ICDeviceBrowserDelegate,  ICDeviceDelegate, PtpWebcamCameraXpcProtocol, PtpCameraLiveViewDelegate>

@property NSArray<NSDictionary*>* connections;
@property NSDictionary* devices;

@property IBOutlet PtpWebcamStreamView* streamView;
@property IBOutlet NSWindow* streamWindow;

@end


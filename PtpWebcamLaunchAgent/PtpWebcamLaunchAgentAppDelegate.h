//
//  PtpWebcamLaunchAgentAppDelegate.h
//  PtpWebcamLaunchAgent
//
//  Created by Dömötör Gulyás on 02.09.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "../PtpWebcamAssistantService/PtpWebcamAssistantServiceProtocol.h"
#import "../PtpWebcamDalPlugin/PtpWebcamAlerts.h"
#import "../PtpWebcamDalPlugin/FoundationExtensions.h"

@interface PtpWebcamLaunchAgentAppDelegate : NSObject <NSApplicationDelegate,NSXPCListenerDelegate, PtpWebcamAssistantServiceProtocol>

@property NSArray* connections;
@property NSDictionary* devices;

@end


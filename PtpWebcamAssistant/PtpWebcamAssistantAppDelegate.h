//
//  AppDelegate.h
//  PtpWebcamAssistant
//
//  Created by Dömötör Gulyás on 27.07.2020.
//  Copyright © 2020 InRobCo. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "../PtpWebcamAssistantService/PtpWebcamAssistantServiceProtocol.h"

@interface PtpWebcamAssistantAppDelegate : NSObject <NSApplicationDelegate, NSXPCListenerDelegate, PtpWebcamAssistantServiceProtocol>


@end


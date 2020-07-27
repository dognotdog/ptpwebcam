//
//  PtpWebcamAgentAppDelegate.h
//  PtpWebcamAgent
//
//  Created by Dömötör Gulyás on 23.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface PtpWebcamAgentAppDelegate : NSObject <NSApplicationDelegate, NSPortDelegate>

@property id cameraId;

@property NSDictionary* cameraInfo;
@property NSArray* cameraSupportedProperties;
@property NSDictionary* cameraProperties;

@end


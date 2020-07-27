//
//  main.m
//  PtpWebcamAssistantService
//
//  Created by Dömötör Gulyás on 22.07.2020.
//  Copyright © 2020 InRobCo. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "PtpWebcamAssistantService.h"
#import "PtpWebcamAlerts.h"

int main(int argc, const char *argv[])
{
//	assert(NSApplicationLoad());
    // Create the delegate for the service.
    PtpWebcamAssistantService *delegate = [[PtpWebcamAssistantService alloc] init];
    
    // Set up the one NSXPCListener for this service. It will handle all incoming connections.
    NSXPCListener *listener = [NSXPCListener serviceListener];
    listener.delegate = delegate;
    
    // Resuming the serviceListener starts this service. This method does not return.
    [listener resume];
    return 0;
}

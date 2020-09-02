//
//  PtpWebcamAssistantDaemon.h
//  PtpWebcamSimpleAssistant
//
//  Created by Dömötör Gulyás on 01.09.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "../PtpWebcamDalPlugin/PtpWebcamAlerts.h"
#import "../PtpWebcamDalPlugin/FoundationExtensions.h"
#import "../PtpWebcamAssistantService/PtpWebcamAssistantServiceProtocol.h"
#import "../PtpWebcamAssistantService/PtpCameraMachAssistant.h"

#import <Foundation/Foundation.h>

#import <ImageCaptureCore/ICDeviceBrowser.h>


NS_ASSUME_NONNULL_BEGIN

@interface PtpWebcamAssistantDaemon : NSObject <NSXPCListenerDelegate, ICDeviceBrowserDelegate, ICDeviceDelegate, PtpWebcamAssistantServiceProtocol, PtpWebcamMachAssistantDaemonProtocol>

@property NSArray* connections;
@property NSDictionary* devices;

- (void) startListening;

@end

NS_ASSUME_NONNULL_END

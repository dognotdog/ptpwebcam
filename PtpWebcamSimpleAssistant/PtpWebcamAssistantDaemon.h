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

#import <Foundation/Foundation.h>


NS_ASSUME_NONNULL_BEGIN

@interface PtpWebcamAssistantDaemon : NSObject <NSXPCListenerDelegate, PtpWebcamAssistantXpcProtocol>

@property NSArray* connections;

- (void) startListening;

@end

NS_ASSUME_NONNULL_END

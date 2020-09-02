//
//  main.m
//  PtpWebcamSimpleAssistant
//
//  Created by Dömötör Gulyás on 01.09.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamAssistantDaemon.h"

#import <Foundation/Foundation.h>

int main(int argc, const char * argv[]) {
	@autoreleasepool {
	    NSLog(@"Hello, World!");

		
		PtpWebcamAssistantDaemon* listener = [[PtpWebcamAssistantDaemon alloc] init];
		
		[listener startListening];
		
		[[NSRunLoop currentRunLoop] run];
		
		NSLog(@"Bye, World!");
	}
	return 0;
}

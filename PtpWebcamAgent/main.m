//
//  main.m
//  PtpWebcamAgent
//
//  Created by Dömötör Gulyás on 23.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Cocoa/Cocoa.h>

int main(int argc, const char * argv[])
{
	@autoreleasepool {
		// we expect the cameraId and parentProcessPid to be in the argument list
		if (argc < 3)
			return -1;
	}
	return NSApplicationMain(argc, argv);
}

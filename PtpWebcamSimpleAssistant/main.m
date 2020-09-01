//
//  main.m
//  PtpWebcamSimpleAssistant
//
//  Created by Dömötör Gulyás on 01.09.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Foundation/Foundation.h>

#include <servers/bootstrap.h>

boolean_t MessagesAndNotifications(mach_msg_header_t* request, mach_msg_header_t* reply)
{
	return true;
}

int main(int argc, const char * argv[]) {
	@autoreleasepool {
	    // insert code here...
	    NSLog(@"Hello, World!");

		// Check in with the bootstrap port under the agreed upon name to get the servicePort with receive rights
		mach_port_t servicePort;
		name_t serviceName = "org.ptpwebcam.PtpWebcamAssistant";
		kern_return_t err = bootstrap_check_in(bootstrap_port, serviceName, &servicePort);
		if (BOOTSTRAP_SUCCESS != err)
		{
			NSLog(@"bootstrap_check_in() failed: 0x%x", err);
			exit(43);
		}
	
		#if 0
			// Wait forever until the Debugger can attach to the Assistant process
			bool waiting = true;
			while (waiting)
			{
				sleep(1);
			}
		#endif

		// Add the service port to the Assistant's port set
		mach_port_t portSet = MACH_PORT_NULL;
		// Create a port set to hold the service port, and each client's port
		err = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_PORT_SET, &portSet);

		err = mach_port_move_member(mach_task_self(), servicePort, portSet);
		if (KERN_SUCCESS != err)
		{
			NSLog(@"Unable to add service port to port set: 0x%x", err);
			exit(2);
		}

		// Service incoming messages from the clients and notifications which were signed up for
		NSLog(@"Entering Service Loop!");
		while (true)
		{
			(void) mach_msg_server(MessagesAndNotifications, 8192, portSet, MACH_MSG_OPTION_NONE);
		}
		NSLog(@"Bye, World!");
	}
	return 0;
}

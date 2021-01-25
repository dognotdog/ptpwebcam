//
//  PtpWebcamObject.m
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 04.06.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamObject.h"

@interface PtpWebcamObject ()
{
	NSMutableDictionary* listeners;
}
@end

@implementation PtpWebcamObject

@synthesize objectId;

- (instancetype) initWithPluginInterface: (CMIOHardwarePlugInRef)pluginInterfaceRef
{
	if (!(self = [super init]))
		return nil;
	
	self.pluginInterfaceRef = pluginInterfaceRef;
	listeners = [NSMutableDictionary dictionary];
	
	return self;
}

- (BOOL) hasPropertyWithAddress: (CMIOObjectPropertyAddress) address
{
	switch(address.mSelector)
	{
		case kCMIOObjectPropertyListenerAdded:
		case kCMIOObjectPropertyListenerRemoved:
			return YES;
		case kCMIOObjectPropertyOwnedObjects:
			// just so this unknown property doesn't get logged through default:, as it happens a lot
			return NO;
		default:
			NSLog(@"%@ hasPropertyWithAddress unknown: %@", [self class], [PtpWebcamObject cmioPropertyIdToString: address.mSelector]);
			return NO;
	}
}

- (NSData * _Nullable)getPropertyDataForAddress:(CMIOObjectPropertyAddress)address qualifierData:(nonnull NSData *)qualifierData
{
	switch(address.mSelector)
	{
		default:
			NSLog(@"%@ getPropertyDataForAddress unknown: %@", [self class], [PtpWebcamObject cmioPropertyIdToString: address.mSelector]);
			return nil;
	}
}


- (uint32_t)getPropertyDataSizeForAddress:(CMIOObjectPropertyAddress)address qualifierData:(NSData * _Nullable)qualifierData
{
	switch(address.mSelector)
	{
		case kCMIOObjectPropertyListenerAdded:
		case kCMIOObjectPropertyListenerRemoved:
			return sizeof(CMIOObjectPropertyAddress);
		default:
			NSLog(@"%@ getPropertyDataSizeForAddress unknown: %@", [self class], [PtpWebcamObject cmioPropertyIdToString: address.mSelector]);
			return 0;
	}
}


- (BOOL)isPropertySettable:(CMIOObjectPropertyAddress)address
{
	switch(address.mSelector)
	{
		case kCMIOObjectPropertyListenerAdded:
		case kCMIOObjectPropertyListenerRemoved:
			return YES;
		default:
			NSLog(@"%@ isPropertySettable unknown: %@", [self class], [PtpWebcamObject cmioPropertyIdToString: address.mSelector]);
			return NO;
	}
}


- (OSStatus)setPropertyDataForAddress:(CMIOObjectPropertyAddress)address qualifierData:(NSData * _Nullable)qualifierData data:(nonnull NSData *)data
{
	switch(address.mSelector)
	{
		case kCMIOObjectPropertyListenerAdded:
		{
			[listeners setObject: data forKey: data];
			return kCMIOHardwareNoError;
		}
		case kCMIOObjectPropertyListenerRemoved:
		{
			[listeners removeObjectForKey: data];
			return kCMIOHardwareNoError;
		}
		default:
			NSLog(@"%@ setPropertyDataForAddress unknown: %@", [self class], [PtpWebcamObject cmioPropertyIdToString: address.mSelector]);
			return kCMIOHardwareUnsupportedOperationError;
	}
}


@end

//
//  PtpWebcamObject.h
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 04.06.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <CoreMediaIO/CMIOHardwarePlugIn.h>

#include <stdbool.h>

NS_ASSUME_NONNULL_BEGIN

@protocol PtpWebcamObject <NSObject>


@optional

- (uint32_t) numStreams;

@end


@interface PtpWebcamObject : NSObject

- (instancetype) initWithPluginInterface: (_Nonnull CMIOHardwarePlugInRef) pluginInterface;

- (BOOL) hasPropertyWithAddress: (CMIOObjectPropertyAddress) address;
- (BOOL) isPropertySettable: (CMIOObjectPropertyAddress) address;
- (uint32_t) getPropertyDataSizeForAddress: (CMIOObjectPropertyAddress) address qualifierData: (NSData* __nullable) qualifierData;
- (NSData* __nullable) getPropertyDataForAddress: (CMIOObjectPropertyAddress) address qualifierData: (NSData*) qualifierData;
- (OSStatus) setPropertyDataForAddress: (CMIOObjectPropertyAddress) address qualifierData: (NSData* __nullable) qualifierData data: (NSData*) data;

@property CMIOObjectID objectId;

@property _Nonnull CMIOHardwarePlugInRef pluginInterfaceRef;

@end

@interface PtpWebcamObject (CMIOObject)
+ (id) objectWithId: (CMIOObjectID) objectId;
+ (void) registerObject: (PtpWebcamObject*) obj;
+ (NSString*) cmioPropertyIdToString: (uint32_t) property;
@end


NS_ASSUME_NONNULL_END

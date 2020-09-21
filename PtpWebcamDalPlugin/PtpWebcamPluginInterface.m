//
//  PtpWebcamPluginInterface.m
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 29.05.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

/**
 lldb breakpoint for looking at stack trace of exception
b __cxa_throw
break command add -s python -o "return any('SafeGetElement' in f.name for f in frame.thread)"
 */

#import <Foundation/Foundation.h>

#import <CoreMediaIO/CMIOHardwarePlugIn.h>

#import "PtpWebcamPlugin.h"
#import "PtpWebcamDevice.h"
#import "PtpWebcamStream.h"
#import "PtpWebcamAlerts.h"

#include <objc/runtime.h>
#include <stdarg.h>

static NSMutableDictionary* _objectMap = nil;


@implementation PtpWebcamObject (CMIOObject)

+ (id) objectWithId: (CMIOObjectID) objectId
{
	@synchronized (_objectMap) {
		return _objectMap[@(objectId)];
	}
}
+ (void) registerObject: (PtpWebcamObject *) obj
{
	@synchronized (_objectMap) {
		_objectMap[@(obj.objectId)] = obj;
	}
}

+ (NSString*) cmioPropertyIdToString: (uint32_t) property
{
	/**
	 find: (kCMIO\w+Property\w+)(.+)
	 replace: case $1: return @"$1";
	 */
	switch(property)
	{
			case kCMIOObjectPropertyClass: return @"kCMIOObjectPropertyClass";
			case kCMIOObjectPropertyOwner: return @"kCMIOObjectPropertyOwner";
			case kCMIOObjectPropertyCreator: return @"kCMIOObjectPropertyCreator";
			case kCMIOObjectPropertyName: return @"kCMIOObjectPropertyName";
			case kCMIOObjectPropertyManufacturer: return @"kCMIOObjectPropertyManufacturer";
			case kCMIOObjectPropertyElementName: return @"kCMIOObjectPropertyElementName";
			case kCMIOObjectPropertyElementCategoryName: return @"kCMIOObjectPropertyElementCategoryName";
			case kCMIOObjectPropertyElementNumberName: return @"kCMIOObjectPropertyElementNumberName";
			case kCMIOObjectPropertyOwnedObjects: return @"kCMIOObjectPropertyOwnedObjects";
			case kCMIOObjectPropertyListenerAdded: return @"kCMIOObjectPropertyListenerAdded";
			case kCMIOObjectPropertyListenerRemoved: return @"kCMIOObjectPropertyListenerRemoved";
			case kCMIODevicePropertyPlugIn: return @"kCMIODevicePropertyPlugIn";
			case kCMIODevicePropertyDeviceUID: return @"kCMIODevicePropertyDeviceUID";
			case kCMIODevicePropertyModelUID: return @"kCMIODevicePropertyModelUID";
			case kCMIODevicePropertyTransportType: return @"kCMIODevicePropertyTransportType";
			case kCMIODevicePropertyDeviceIsAlive: return @"kCMIODevicePropertyDeviceIsAlive";
			case kCMIODevicePropertyDeviceHasChanged: return @"kCMIODevicePropertyDeviceHasChanged";
			case kCMIODevicePropertyDeviceIsRunning: return @"kCMIODevicePropertyDeviceIsRunning";
			case kCMIODevicePropertyDeviceIsRunningSomewhere: return @"kCMIODevicePropertyDeviceIsRunningSomewhere";
			case kCMIODevicePropertyDeviceCanBeDefaultDevice: return @"kCMIODevicePropertyDeviceCanBeDefaultDevice";
			case kCMIODevicePropertyHogMode: return @"kCMIODevicePropertyHogMode";
			case kCMIODevicePropertyLatency: return @"kCMIO(Stream|Device)PropertyLatency";
			case kCMIODevicePropertyStreams: return @"kCMIODevicePropertyStreams";
			case kCMIODevicePropertyStreamConfiguration: return @"kCMIODevicePropertyStreamConfiguration";
			case kCMIODevicePropertyDeviceMaster: return @"kCMIODevicePropertyDeviceMaster";
			case kCMIODevicePropertyExcludeNonDALAccess: return @"kCMIODevicePropertyExcludeNonDALAccess";
			case kCMIODevicePropertyClientSyncDiscontinuity: return @"kCMIODevicePropertyClientSyncDiscontinuity";
			case kCMIODevicePropertySMPTETimeCallback: return @"kCMIODevicePropertySMPTETimeCallback";
			case kCMIODevicePropertyCanProcessAVCCommand: return @"kCMIODevicePropertyCanProcessAVCCommand";
			case kCMIODevicePropertyAVCDeviceType: return @"kCMIODevicePropertyAVCDeviceType";
			case kCMIODevicePropertyAVCDeviceSignalMode: return @"kCMIODevicePropertyAVCDeviceSignalMode";
			case kCMIODevicePropertyCanProcessRS422Command: return @"kCMIODevicePropertyCanProcessRS422Command";
			case kCMIODevicePropertyLinkedCoreAudioDeviceUID: return @"kCMIODevicePropertyLinkedCoreAudioDeviceUID";
			case kCMIODevicePropertyVideoDigitizerComponents: return @"kCMIODevicePropertyVideoDigitizerComponents";
			case kCMIODevicePropertySuspendedByUser: return @"kCMIODevicePropertySuspendedByUser";
			case kCMIODevicePropertyLinkedAndSyncedCoreAudioDeviceUID: return @"kCMIODevicePropertyLinkedAndSyncedCoreAudioDeviceUID";
			case kCMIODevicePropertyIIDCInitialUnitSpace: return @"kCMIODevicePropertyIIDCInitialUnitSpace";
			case kCMIODevicePropertyIIDCCSRData: return @"kCMIODevicePropertyIIDCCSRData";
			case kCMIODevicePropertyCanSwitchFrameRatesWithoutFrameDrops: return @"kCMIODevicePropertyCanSwitchFrameRatesWithoutFrameDrops";
			case kCMIODevicePropertyLocation: return @"kCMIODevicePropertyLocation";
			case kCMIODevicePropertyDeviceHasStreamingError: return @"kCMIODevicePropertyDeviceHasStreamingError";
			case kCMIOStreamPropertyDirection: return @"kCMIOStreamPropertyDirection";
			case kCMIOStreamPropertyTerminalType: return @"kCMIOStreamPropertyTerminalType";
			case kCMIOStreamPropertyStartingChannel: return @"kCMIOStreamPropertyStartingChannel";
//			case kCMIOStreamPropertyLatency: return @"kCMIOStreamPropertyLatency";
			case kCMIOStreamPropertyFormatDescription: return @"kCMIOStreamPropertyFormatDescription";
			case kCMIOStreamPropertyFormatDescriptions: return @"kCMIOStreamPropertyFormatDescriptions";
			case kCMIOStreamPropertyStillImage: return @"kCMIOStreamPropertyStillImage";
			case kCMIOStreamPropertyStillImageFormatDescriptions: return @"kCMIOStreamPropertyStillImageFormatDescriptions";
			case kCMIOStreamPropertyFrameRate: return @"kCMIOStreamPropertyFrameRate";
			case kCMIOStreamPropertyMinimumFrameRate: return @"kCMIOStreamPropertyMinimumFrameRate";
			case kCMIOStreamPropertyFrameRates: return @"kCMIOStreamPropertyFrameRates";
			case kCMIOStreamPropertyFrameRateRanges: return @"kCMIOStreamPropertyFrameRateRanges";
			case kCMIOStreamPropertyNoDataTimeoutInMSec: return @"kCMIOStreamPropertyNoDataTimeoutInMSec";
			case kCMIOStreamPropertyDeviceSyncTimeoutInMSec: return @"kCMIOStreamPropertyDeviceSyncTimeoutInMSec";
			case kCMIOStreamPropertyNoDataEventCount: return @"kCMIOStreamPropertyNoDataEventCount";
			case kCMIOStreamPropertyOutputBufferUnderrunCount: return @"kCMIOStreamPropertyOutputBufferUnderrunCount";
			case kCMIOStreamPropertyOutputBufferRepeatCount: return @"kCMIOStreamPropertyOutputBufferRepeatCount";
			case kCMIOStreamPropertyOutputBufferQueueSize: return @"kCMIOStreamPropertyOutputBufferQueueSize";
			case kCMIOStreamPropertyOutputBuffersRequiredForStartup: return @"kCMIOStreamPropertyOutputBuffersRequiredForStartup";
			case kCMIOStreamPropertyOutputBuffersNeededForThrottledPlayback: return @"kCMIOStreamPropertyOutputBuffersNeededForThrottledPlayback";
			case kCMIOStreamPropertyFirstOutputPresentationTimeStamp: return @"kCMIOStreamPropertyFirstOutputPresentationTimeStamp";
			case kCMIOStreamPropertyEndOfData: return @"kCMIOStreamPropertyEndOfData";
			case kCMIOStreamPropertyClock: return @"kCMIOStreamPropertyClock";
			case kCMIOStreamPropertyCanProcessDeckCommand: return @"kCMIOStreamPropertyCanProcessDeckCommand";
			case kCMIOStreamPropertyDeck: return @"kCMIOStreamPropertyDeck";
			case kCMIOStreamPropertyDeckFrameNumber: return @"kCMIOStreamPropertyDeckFrameNumber";
			case kCMIOStreamPropertyDeckDropness: return @"kCMIOStreamPropertyDeckDropness";
			case kCMIOStreamPropertyDeckThreaded: return @"kCMIOStreamPropertyDeckThreaded";
			case kCMIOStreamPropertyDeckLocal: return @"kCMIOStreamPropertyDeckLocal";
			case kCMIOStreamPropertyDeckCueing: return @"kCMIOStreamPropertyDeckCueing";
			case kCMIOStreamPropertyInitialPresentationTimeStampForLinkedAndSyncedAudio: return @"kCMIOStreamPropertyInitialPresentationTimeStampForLinkedAndSyncedAudio";
			case kCMIOStreamPropertyScheduledOutputNotificationProc: return @"kCMIOStreamPropertyScheduledOutputNotificationProc";
			case kCMIOStreamPropertyPreferredFormatDescription: return @"kCMIOStreamPropertyPreferredFormatDescription";
			case kCMIOStreamPropertyPreferredFrameRate: return @"kCMIOStreamPropertyPreferredFrameRate";

		default:
			return [NSString stringWithFormat:@"'%c%c%c%c'",
					(property >> 24) & 0xFF,
					(property >> 16) & 0xFF,
					(property >> 8) & 0xFF,
					(property >> 0) & 0xFF];
	}
}


@end

@implementation PtpWebcamPlugin (Factory)

static PtpWebcamPlugin* _refToObj(void* interfaceRef)
{
	Ivar ivar = class_getInstanceVariable([PtpWebcamPlugin class], "_pluginInterface");
	if (ivar)
	{
		ptrdiff_t offs = ivar_getOffset(ivar);
		PtpWebcamPlugin* obj = (__bridge PtpWebcamPlugin*)(void*)((uint8_t*)interfaceRef - offs);
		return obj;

	}
	else
	{
		PtpWebcamShowCatastrophicAlert(@"_refToObj(%p) could not determine \"_pluginInterface\" offset.", interfaceRef);
		return nil;
	}
}

static uint32_t _retain(void* interfaceRef)
{
	PtpWebcamPlugin* self = _refToObj(interfaceRef);
	@synchronized (self) {
		CFRetain((__bridge void*)self);
		return (uint32_t)CFGetRetainCount((__bridge void*)self);
	}
}

static uint32_t _release(void* interfaceRef)
{
	PtpWebcamPlugin* self = _refToObj(interfaceRef);
	@synchronized (self) {
		uint32_t retainCount = (uint32_t)CFGetRetainCount((__bridge void*)self);
		CFRelease((__bridge void*)self);
		return retainCount-1;
	}
}

static HRESULT _queryInterface(void* interfaceRef, REFIID uuidBytes, void** interface)
{
	*interface = NULL;
	
	if (!interfaceRef)
		return kCMIOHardwareIllegalOperationError;
	if (!interface)
		return kCMIOHardwareIllegalOperationError;

	PtpWebcamPlugin* self = _refToObj(interfaceRef);

	NSUUID* uuid = (__bridge_transfer NSUUID*)CFUUIDCreateFromUUIDBytes(NULL, uuidBytes);
	
	if ([uuid isEqual: (__bridge id)kCMIOHardwarePlugInInterfaceID] || [uuid isEqual: (__bridge id)IUnknownUUID])
	{
		_retain(interfaceRef);
		*interface = &self->_pluginInterface;
	}
	else
	{
		NSLog(@"PtpWebcamPluginInterface _queryInterface(%@) unknown UUID", uuid);
		return E_NOINTERFACE;
	}
	
	return kCMIOHardwareNoError;
}

static OSStatus _initializeWithObjectId(CMIOHardwarePlugInRef interfaceRef, CMIOObjectID objectId)
{
	NSLog(@"PtpWebcamPluginInterface _initializeWithObjectId(%u)", objectId);
	if (!interfaceRef)
		return kCMIOHardwareIllegalOperationError;
	PtpWebcamPlugin* self = _refToObj(interfaceRef);

	@synchronized (_objectMap)
	{
		[_objectMap removeObjectForKey: @(self.objectId)];
		@synchronized(self)
		{
			self.objectId = objectId;
		}
		[_objectMap setObject: self forKey: @(objectId)];
	}
	
	return [self initialize];

}

static OSStatus _initialize(CMIOHardwarePlugInRef interfaceRef)
{
	return _initializeWithObjectId(interfaceRef, kCMIOObjectUnknown);
}

static OSStatus _teardown(CMIOHardwarePlugInRef interfaceRef)
{
	if (!interfaceRef)
		return kCMIOHardwareIllegalOperationError;
	PtpWebcamPlugin* self = _refToObj(interfaceRef);
	@synchronized (self)
	{
		return [self teardown];
	}
}

static void _objectShow(CMIOHardwarePlugInRef interfaceRef, CMIOObjectID objectId)
{
	NSLog(@"_objectShow");
	if (!interfaceRef)
		return;
	@synchronized (_objectMap) {
		PtpWebcamPlugin* self = _objectMap[@(objectId)];
		NSLog(@"CMIOObjectID:0x%X = %@", objectId, self);
	}
}

static Boolean _objectHasProperty(CMIOHardwarePlugInRef interfaceRef, CMIOObjectID objectId, const CMIOObjectPropertyAddress* address)
{
//	NSLog(@"_objectHasProperty(%u, %@)", objectId, [PtpWebcamObject cmioPropertyIdToString: address->mSelector]);
	if (!interfaceRef)
		return false;
	if (!address)
		return false;
	@synchronized(_objectMap)
	{
		PtpWebcamObject* self = _objectMap[@(objectId)];
		if (!self)
			return false;
		return [self hasPropertyWithAddress: *address];
	}
}

static OSStatus _objectIsPropertySettable(CMIOHardwarePlugInRef interfaceRef, CMIOObjectID objectId, const CMIOObjectPropertyAddress* address, Boolean* isSettable)
{
//	NSLog(@"_objectIsPropertySettable(%u, %@)", objectId, [PtpWebcamObject cmioPropertyIdToString: address->mSelector]);
	if (!interfaceRef)
		return kCMIOHardwareIllegalOperationError;
	if (!address)
		return kCMIOHardwareIllegalOperationError;
	if (!isSettable)
		return kCMIOHardwareIllegalOperationError;

	id self = nil;
	@synchronized (_objectMap) {
		self = _objectMap[@(objectId)];
	}
	
	if (!self)
		return kCMIOHardwareBadObjectError;
	
	@synchronized (self) {
		*isSettable = [self isPropertySettable: *address];
	}
	
	return kCMIOHardwareNoError;
}

static OSStatus _objectGetPropertyDataSize(CMIOHardwarePlugInRef interfaceRef, CMIOObjectID objectId, const CMIOObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32* dataSize)
{
	if (!interfaceRef)
		return kCMIOHardwareIllegalOperationError;
	if (!address)
		return kCMIOHardwareIllegalOperationError;
	if (qualifierDataSize && !qualifierData)
		return kCMIOHardwareIllegalOperationError;
	if (!dataSize)
		return kCMIOHardwareIllegalOperationError;

	id self = nil;
	@synchronized (_objectMap) {
		self = _objectMap[@(objectId)];
	}
	
	if (!self)
		return kCMIOHardwareBadObjectError;
	
	@synchronized (self) {
		*dataSize = [self getPropertyDataSizeForAddress: *address qualifierData: [NSData dataWithBytes: qualifierData length: qualifierDataSize]];
	}

	return kCMIOHardwareNoError;
}

static OSStatus _objectGetPropertyData(CMIOHardwarePlugInRef interfaceRef, CMIOObjectID objectId, const CMIOObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 dataSize, UInt32* dataUsed, void* data)
{
//	NSLog(@"_objectGetPropertyData(%u, %@)", objectId, [PtpWebcamObject cmioPropertyIdToString: address->mSelector]);

	if (!interfaceRef)
		return kCMIOHardwareIllegalOperationError;
	if (!address)
		return kCMIOHardwareIllegalOperationError;
	if (qualifierDataSize && !qualifierData)
		return kCMIOHardwareIllegalOperationError;
	if (!dataUsed)
		return kCMIOHardwareIllegalOperationError;
	if (dataSize && !data)
		return kCMIOHardwareIllegalOperationError;

	id self = nil;
	@synchronized (_objectMap) {
		self = _objectMap[@(objectId)];
	}
	
	if (!self)
		return kCMIOHardwareBadObjectError;
	
	@synchronized (self) {
		NSData* objData = [self getPropertyDataForAddress: *address qualifierData: [NSData dataWithBytes: qualifierData length: qualifierDataSize]];
		if (dataSize < objData.length)
		{
			PtpWebcamShowCatastrophicAlert(@"_objectGetPropertyData(%u, 0x%08X) actual data size (%zu) larger than allocated storage (%u).", objectId, address->mSelector, objData.length, dataSize);
			return kCMIOHardwareBadPropertySizeError;
		}
		memcpy(data, objData.bytes, objData.length);
		*dataUsed = (uint32_t)objData.length;
	}

	return kCMIOHardwareNoError;
}

static OSStatus _objectSetPropertyData(CMIOHardwarePlugInRef interfaceRef, CMIOObjectID objectId, const CMIOObjectPropertyAddress* address, UInt32 qualifierDataSize, const void* qualifierData, UInt32 dataSize, const void* data)
{
//	NSLog(@"_objectSetPropertyData(%@)", [PtpWebcamObject cmioPropertyIdToString: address->mSelector]);
	
	if (!interfaceRef)
		return kCMIOHardwareIllegalOperationError;
	if (!address)
		return kCMIOHardwareIllegalOperationError;
	if (qualifierDataSize && !qualifierData)
		return kCMIOHardwareIllegalOperationError;
	if (dataSize && !data)
		return kCMIOHardwareIllegalOperationError;

	id self = nil;
	@synchronized (_objectMap) {
		self = _objectMap[@(objectId)];
	}
	
	if (!self)
		return kCMIOHardwareBadObjectError;
	
	@synchronized (self) {
		OSStatus err = [self setPropertyDataForAddress: *address qualifierData: [NSData dataWithBytes: qualifierData length: qualifierDataSize] data: [NSData dataWithBytes: data length: dataSize]];
		if (err != kCMIOHardwareNoError)
		{
			return err;
		}
	}

	return kCMIOHardwareNoError;
}

static OSStatus _deviceStartStream(CMIOHardwarePlugInRef interfaceRef, CMIODeviceID deviceId, CMIOStreamID streamId)
{
	NSLog(@"_deviceStartStream()");
	if (!interfaceRef)
		return kCMIOHardwareIllegalOperationError;

	PtpWebcamDevice* device = nil;
	@synchronized (_objectMap) {
		device = _objectMap[@(deviceId)];
	}
	if (!device)
		return kCMIOHardwareBadDeviceError;
	
	return [device startStream: streamId];
}

static OSStatus _deviceSuspend(CMIOHardwarePlugInRef interfaceRef, CMIODeviceID deviceId)
{
	NSLog(@"_deviceSuspend()");
	if (!interfaceRef)
		return kCMIOHardwareIllegalOperationError;

	PtpWebcamDevice* device = nil;
	@synchronized (_objectMap) {
		device = _objectMap[@(deviceId)];
	}
	if (!device)
		return kCMIOHardwareBadDeviceError;
	
	return [device suspend];
}

static OSStatus _deviceResume(CMIOHardwarePlugInRef interfaceRef, CMIODeviceID deviceId)
{
	NSLog(@"_deviceResume()");
	if (!interfaceRef)
		return kCMIOHardwareIllegalOperationError;

	PtpWebcamDevice* device = nil;
	@synchronized (_objectMap) {
		device = _objectMap[@(deviceId)];
	}
	if (!device)
		return kCMIOHardwareBadDeviceError;
	
	return [device resume];
}

static OSStatus _deviceStopStream(CMIOHardwarePlugInRef interfaceRef, CMIODeviceID deviceId, CMIOStreamID streamId)
{
	if (!interfaceRef)
		return kCMIOHardwareIllegalOperationError;

	PtpWebcamDevice* device = nil;
	@synchronized (_objectMap) {
		device = _objectMap[@(deviceId)];
	}
	if (!device)
		return kCMIOHardwareBadDeviceError;
	
	return [device stopStream: streamId];
}

static OSStatus _deviceProcessAvcCommand(CMIOHardwarePlugInRef interfaceRef, CMIODeviceID deviceId, CMIODeviceAVCCommand* ioAvcCommand)
{
	if (!interfaceRef)
		return kCMIOHardwareIllegalOperationError;

	return kCMIOHardwareNoError;
}

static OSStatus _deviceProcessRS422Command(CMIOHardwarePlugInRef interfaceRef, CMIODeviceID deviceId, CMIODeviceRS422Command* ioRS422Command)
{
	if (!interfaceRef)
		return kCMIOHardwareIllegalOperationError;

	return kCMIOHardwareNoError;
}

static OSStatus _streamDeckPlay(CMIOHardwarePlugInRef self, CMIOStreamID streamID)
{
	NSLog(@"_streamDeckPlay()");
	return kCMIOHardwareIllegalOperationError;
}

static OSStatus _streamDeckStop(CMIOHardwarePlugInRef self, CMIOStreamID streamID)
{
	return kCMIOHardwareIllegalOperationError;
}

static OSStatus _streamDeckJog(CMIOHardwarePlugInRef self, CMIOStreamID streamID, SInt32 speed)
{
	return kCMIOHardwareIllegalOperationError;
}

static OSStatus _streamDeckCueTo(CMIOHardwarePlugInRef self, CMIOStreamID streamID, Float64 requestedTimecode, Boolean	playOnCue)
{
	return kCMIOHardwareIllegalOperationError;
}

static OSStatus _streamCopyBufferQueue(CMIOHardwarePlugInRef interfaceRef, CMIOStreamID streamId, CMIODeviceStreamQueueAlteredProc queueAlteredProc, void* queueAlteredRefCon, CMSimpleQueueRef* queue)
{
	NSLog(@"_streamCopyBufferQueue()");
	if (!interfaceRef)
		return kCMIOHardwareIllegalOperationError;
	if (!queue)
		return kCMIOHardwareIllegalOperationError;

	PtpWebcamStream* stream = nil;
	@synchronized (_objectMap) {
		stream = _objectMap[@(streamId)];
	}
	if (!streamId)
		return kCMIOHardwareBadStreamError;

	*queue = [stream copyBufferQueueWithAlteredProc: queueAlteredProc refCon: queueAlteredRefCon];

	return kCMIOHardwareNoError;
}


static CMIOHardwarePlugInInterface _gPluginInterface = {
	._reserved = NULL,
	.QueryInterface = _queryInterface,
	.AddRef = _retain,
	.Release = _release,
	.Initialize = _initialize,
	.InitializeWithObjectID = _initializeWithObjectId,
	.Teardown = _teardown,
	.ObjectShow = _objectShow,
	.ObjectHasProperty = _objectHasProperty,
	.ObjectIsPropertySettable = _objectIsPropertySettable,
	.ObjectGetPropertyDataSize = _objectGetPropertyDataSize,
	.ObjectGetPropertyData = _objectGetPropertyData,
	.ObjectSetPropertyData = _objectSetPropertyData,
	.DeviceStartStream = _deviceStartStream,
	.DeviceSuspend = _deviceSuspend,
	.DeviceResume = _deviceResume,
	.DeviceStopStream = _deviceStopStream,
	.DeviceProcessAVCCommand = _deviceProcessAvcCommand,
	.DeviceProcessRS422Command = _deviceProcessRS422Command,
	.StreamDeckPlay = _streamDeckPlay,
	.StreamDeckStop = _streamDeckStop,
	.StreamDeckJog = _streamDeckJog,
	.StreamDeckCueTo = _streamDeckCueTo,
	.StreamCopyBufferQueue = _streamCopyBufferQueue,
};


void* PtpWebcamPluginFactory(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID)
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		_objectMap = [NSMutableDictionary dictionary];
	});

	
	PtpWebcamPlugin* self = [[PtpWebcamPlugin alloc] init];
	
	self.pluginInterface = &_gPluginInterface;
	self.pluginInterfaceRef = &self->_pluginInterface;
	
	// add a retain as we're leaving ARC domain
	CFRetain((__bridge void*)self);

	// return a CMIOHardwarePlugInRef, which is a CMIOHardwarePlugInInterface**
	return &self->_pluginInterface;
	
}

@end

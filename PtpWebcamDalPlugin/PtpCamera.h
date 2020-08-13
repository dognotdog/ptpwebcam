//
//  PtpCamera.h
//  PtpWebcamAssistantService
//
//  Created by Dömötör Gulyás on 25.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <ImageCaptureCore/ImageCaptureCore.h>

#import "PtpWebcamPtp.h"

NS_ASSUME_NONNULL_BEGIN

@protocol PtpCameraDelegate;

@interface PtpCamera : NSObject <ICCameraDeviceDelegate, NSPortDelegate>

@property(weak) id <PtpCameraDelegate> delegate;

@property ICCameraDevice* icCamera;
@property id cameraId;

@property NSString* make;
@property NSString* model;

@property NSDictionary* ptpDeviceInfo;
@property NSDictionary* ptpPropertyInfos;
@property NSArray* uiPtpProperties; // which properties to show in the UI
@property NSDictionary* uiPtpSubProperties; // UI submenu

@property size_t liveViewHeaderLength;

+ (void) registerSupportedCameras: (NSDictionary*) supportedCameras byClass: (Class) aClass;

+ (nullable NSDictionary*) isDeviceSupported: (ICDevice*) device;

//+ (NSDictionary*) ptpStandardProgramModeNames;
//+ (NSDictionary*) ptpStandardWhiteBalanceModeNames;
+ (NSDictionary*) ptpStandardPropertyValueNames;
+ (NSDictionary*) ptpStandardPropertyNames;
+ (NSDictionary*) ptpStandardOperationNames;

//- (NSDictionary*) ptpProgramModeNames;
//- (NSDictionary*) ptpWhiteBalanceModeNames;
//- (NSDictionary*) ptpLiveViewImageSizeNames;
- (NSDictionary*) ptpPropertyValueNames;
- (NSDictionary*) ptpPropertyNames;
- (NSDictionary*) ptpOperationNames;

+ (NSDictionary*) mergePropertyValueDictionary: (NSDictionary*) dict0 withDictionary: (NSDictionary*) dict1;


+ (instancetype) cameraWithIcCamera: (ICCameraDevice*) camera delegate: (id <PtpCameraDelegate>) delegate;

- (instancetype) initWithIcCamera: (ICCameraDevice*) camera delegate: (id <PtpCameraDelegate>) delegate cameraInfo: (NSDictionary*) cameraInfo; // override in subclasses only, use +cameraWithIcCamera... instead to instantiate camera

- (BOOL) isPtpOperationSupported: (uint16_t) opId;
- (BOOL) isPtpPropertySupported: (uint16_t) opId;
- (void) ptpGetPropertyDescription: (uint32_t) property;
- (void) ptpSetProperty: (uint32_t) property toValue: (id) value;
- (ptpDataType_t) getPtpPropertyType: (uint32_t) propertyId; // use in subclasses only
- (NSData*) encodePtpProperty: (uint32_t) propertyId fromValue: (id) value;
- (NSArray*) parsePtpItem: (NSData*) data ofType: (int) dataType remainingData: (NSData*_Nullable* _Nullable) remainingData;

- (void) ptpQueryKnownDeviceProperties;
- (void) requestSendPtpCommandWithCode: (int) code;
- (NSData*) ptpCommandWithType: (uint16_t) type code: (uint16_t) code transactionId: (uint32_t) transId parameters: (nullable NSData*) paramData;
- (void) sendPtpCommand: (NSData*) command withData: (NSData*) data;

- (void) didSendPTPCommand:(NSData*)command inData:(NSData*)data response:(NSData*)response error:(NSError*)error contextInfo:(void*)contextInfo; // override in subclasses, do not call otherwise
- (void) receivedProperty: (NSDictionary*) propertyInfo oldProperty: (NSDictionary*) oldProperty withId: (NSNumber*) propertyId; // for subclasses that want to be notified about having received property descriptions

- (NSString*) formatPtpPropertyValue: (id) value ofProperty: (int) propertyId withDefaultValue: (id) defaultValue;

- (BOOL) startLiveView;
- (void) stopLiveView;
- (void) liveViewInterrupted; // called by subclass to indicate temporary problem with video stream, pendant to -cameraDidBecomeReadyForLiveViewStreaming
- (void) requestLiveViewImage;
- (NSSize) currenLiveViewImageSize;
- (NSArray*) liveViewImageSizes;


- (void) cameraDidBecomeReadyForUse; // call from subclasses only
- (void) cameraDidBecomeReadyForLiveViewStreaming; // call from subclasses only


- (uint32_t) nextTransactionId;

- (NSString*) cameraPropertyReport;

@end

@protocol PtpCameraDelegate <NSObject>

- (void) receivedCameraProperty: (NSDictionary*) propertyInfo oldProperty: (NSDictionary*) oldInfo withId: (NSNumber*) propertyId fromCamera: (PtpCamera*) camera;
- (void) receivedLiveViewJpegImage: (NSData*) jpegData withInfo: (NSDictionary*) info fromCamera: (PtpCamera*) camera;

- (void) cameraDidBecomeReadyForUse: (PtpCamera*) camera;
- (void) cameraDidBecomeReadyForLiveViewStreaming: (PtpCamera*) camera;
- (void) cameraLiveViewStreamDidBecomeInterrupted: (PtpCamera*) camera;
- (void) cameraFailedToStartLiveView: (PtpCamera*) camera;
- (void) cameraWasRemoved: (PtpCamera*) camera;

@end

NS_ASSUME_NONNULL_END

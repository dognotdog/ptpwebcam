//
//  PtpCamera.h
//  PtpWebcamAssistantService
//
//  Created by Dömötör Gulyás on 25.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <ImageCaptureCore/ImageCaptureCore.h>

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

@property size_t liveViewHeaderLength;

+ (void) registerSupportedCameras: (NSDictionary*) supportedCameras byClass: (Class) aClass;

+ (nullable NSDictionary*) isDeviceSupported: (ICDevice*) device;

//+ (NSDictionary*) ptpStandardProgramModeNames;
//+ (NSDictionary*) ptpStandardWhiteBalanceModeNames;
+ (NSDictionary*) ptpStandardPropertyValueNames;
+ (NSDictionary*) ptpStandardPropertyNames;

//- (NSDictionary*) ptpProgramModeNames;
//- (NSDictionary*) ptpWhiteBalanceModeNames;
//- (NSDictionary*) ptpLiveViewImageSizeNames;
- (NSDictionary*) ptpPropertyValueNames;
- (NSDictionary*) ptpPropertyNames;

+ (NSDictionary*) mergePropertyValueDictionary: (NSDictionary*) dict0 withDictionary: (NSDictionary*) dict1;


+ (instancetype) cameraWithIcCamera: (ICCameraDevice*) camera delegate: (id <PtpCameraDelegate>) delegate;

//- (instancetype) initWithIcCamera: (ICCameraDevice*) camera delegate: (id <PtpCameraDelegate>) delegate;

- (BOOL) isPtpOperationSupported: (uint16_t) opId;
- (void) ptpGetPropertyDescription: (uint32_t) property;
- (void) ptpSetProperty: (uint32_t) property toValue: (id) value;
- (void) ptpQueryKnownDeviceProperties;
- (void) requestSendPtpCommandWithCode: (int) code;

- (void) startLiveView;
- (void) stopLiveView;
- (void) requestLiveViewImage;

- (uint32_t) nextTransactionId;

@end

@protocol PtpCameraDelegate <NSObject>

- (void) receivedCameraProperty: (NSDictionary*) propertyInfo withId: (NSNumber*) propertyId fromCamera: (PtpCamera*) camera;
- (void) receivedLiveViewJpegImage: (NSData*) jpegData withInfo: (NSDictionary*) info fromCamera: (PtpCamera*) camera;

- (void) cameraDidBecomeReadyForUse: (PtpCamera*) camera;
- (void) cameraDidBecomeReadyForLiveViewStreaming: (PtpCamera*) camera;
- (void) cameraWasRemoved: (PtpCamera*) camera;

@end

NS_ASSUME_NONNULL_END

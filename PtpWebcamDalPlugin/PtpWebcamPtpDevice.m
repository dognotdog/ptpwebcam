//
//  PtpWebcamPtpDevice.m
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 06.06.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamPtpDevice.h"
#import "PtpWebcamPtpStream.h"
#import "PtpWebcamAlerts.h"
#import "PtpWebcamPtp.h"

#import "PtpGridTuneView.h"
#import "PtpCameraSettingsController.h"

@interface PtpWebcamPtpDevice ()
{
	uint32_t transactionId;
	PtpCameraSettingsController* settingsController;
}
@end

@implementation PtpWebcamPtpDevice


- (instancetype) initWithCamera: (PtpCamera*) camera pluginInterface: (_Nonnull CMIOHardwarePlugInRef) pluginInterface
{
	if (!(self = [super initWithPluginInterface: pluginInterface]))
		return nil;
		
	self.camera = camera;
	camera.delegate = self;
	
	settingsController = [[PtpCameraSettingsController alloc] initWithCamera: camera];
		
	self.name = camera.model;
	self.manufacturer = camera.make;
	self.elementNumberName = @"1";
	self.elementCategoryName = @"DSLR Webcam";
	self.deviceUid = camera.cameraId;
	self.modelUid = [NSString stringWithFormat: @"ptp-webcam-plugin-model-%@", camera.model];

//	isPropertyExplorerEnabled = [[NSProcessInfo processInfo].environment[@"PTPWebcamPropertyExplorerEnabled"] isEqualToString: @"YES"];
//	propertyMenuItemLookupTable = [NSMutableDictionary dictionary];

	// camera has been ready for use at this point
//	[self queryAllCameraProperties];
	
	// build the status item
//	[self rebuildStatusItem];
	
	return self;
}

- (PtpWebcamPtpStream*) ptpStream
{
	return (id)self.stream;
}


// MARK: PTP Camera Delegate

- (void) cameraDidBecomeReadyForUse: (PtpCamera*) camera
{
	dispatch_async(dispatch_get_main_queue(), ^{
//		[self rebuildStatusItem];
	});
}

- (void) cameraDidBecomeReadyForLiveViewStreaming: (PtpCamera *) camera
{
	[self.ptpStream cameraDidBecomeReadyForLiveViewStreaming];
}

- (void) cameraLiveViewStreamDidBecomeInterrupted: (PtpCamera *) camera
{
	[self.ptpStream cameraLiveViewStreamDidBecomeInterrupted];
}


- (void) cameraFailedToStartLiveView: (PtpCamera*) camera;
{
	[self.ptpStream cameraFailedToStartLiveView];
}

- (void) receivedLiveViewJpegImage:(NSData *)jpegData withInfo:(NSDictionary *)info fromCamera:(PtpCamera *)camera
{
	[self.ptpStream receivedLiveViewJpegImageData: jpegData withInfo: info];
}

- (void) receivedCameraProperty:(NSDictionary *)propertyInfo oldProperty: (NSDictionary*) oldInfo withId:(NSNumber *)propertyId fromCamera:(PtpCamera *)camera
{
	[settingsController receivedCameraProperty: propertyInfo oldProperty: oldInfo withId: propertyId fromCamera: camera];
}

- (void) cameraAutofocusCapabilityChanged: (PtpCamera*) camera
{
	[settingsController cameraAutofocusCapabilityChanged: camera];
}

- (void) cameraWasRemoved:(PtpCamera *)camera
{
	[self unplugDevice];
}


- (void) unplugDevice
{
	[self.stream unplugDevice];

	[settingsController removeStatusItem];

	[self deleteCmioDevice];
	
}

// MARK: User Interface


@end

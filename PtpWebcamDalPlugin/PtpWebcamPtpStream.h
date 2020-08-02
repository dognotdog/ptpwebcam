//
//  PtpWebcamPtpStream.h
//  PtpWebcamDalPlugin
//
//  Created by Dömötör Gulyás on 06.06.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamStream.h"

NS_ASSUME_NONNULL_BEGIN

@class PtpWebcamPtpDevice;

@interface PtpWebcamPtpStream : PtpWebcamStream

@property(weak) PtpWebcamPtpDevice* ptpDevice;

- (void) cameraDidBecomeReadyForLiveViewStreaming;
- (void) cameraFailedToStartLiveView;
- (void) receivedLiveViewJpegImageData: (NSData*) jpegData withInfo: (NSDictionary*) info;

@end

NS_ASSUME_NONNULL_END

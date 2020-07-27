//
//  PtpWebcamXpcStream.h
//  PTPWebcamDALPlugin
//
//  Created by Dömötör Gulyás on 26.07.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamStream.h"

@class PtpWebcamXpcDevice;

NS_ASSUME_NONNULL_BEGIN

@interface PtpWebcamXpcStream : PtpWebcamStream

@property PtpWebcamXpcDevice* xpcDevice;

- (void) receivedLiveViewJpegImageData: (NSData*) jpegData withInfo: (NSDictionary*) info;
- (void) liveViewStreamReady;

@end

NS_ASSUME_NONNULL_END

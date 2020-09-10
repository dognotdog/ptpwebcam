//
//  PtpWebcamStreamView.h
//  PtpWebcamLaunchAgent
//
//  Created by Dömötör Gulyás on 10.09.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface PtpWebcamStreamView : NSView

- (void) setImage: (NSImage*) image;
- (void) setJpegData: (NSData*) jpegData;

@end

NS_ASSUME_NONNULL_END

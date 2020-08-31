//
//  PtpGridTuneView.h
//  PTP Webcam
//
//  Created by Dömötör Gulyás on 31.08.2020.
//  Copyright © 2020 InRobCo. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface PtpGridTuneView : NSView

@property NSDictionary* range;
@property NSInteger gridSize;
@property id representedObject;
@property(readwrite) NSInteger tag;

@property(nullable) SEL action;
@property(nullable) id target;


- (void) updateSize;

@end

NS_ASSUME_NONNULL_END

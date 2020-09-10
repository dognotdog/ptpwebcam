//
//  PtpWebcamStreamView.m
//  PtpWebcamLaunchAgent
//
//  Created by Dömötör Gulyás on 10.09.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamStreamView.h"
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>

@implementation PtpWebcamStreamView

- (instancetype) initWithFrame:(NSRect)frameRect
{
	if (!(self = [super initWithFrame: frameRect]))
		return nil;
	
	self.layer = [CALayer layer];
	self.wantsLayer = YES;
	
	return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    // Drawing code here.
}

//- (void) setFrame:(NSRect)frame
//{
//	[super setFrame: frame];
//
//	CIFilter* histogramFilter = [CIFilter filterWithName:@"CIAreaHistogram"];
//	[histogramFilter setValue:
//		[CIVector vectorWithX:0.0
//							Y:0.0
//							Z:self.frame.size.width
//							W:self.frame.size.height]
//					   forKey: kCIInputExtentKey];
//	[histogramFilter setValue: @(256)
//					   forKey:@"inputCount"];
//	[histogramFilter setValue: @(2)
//					   forKey: kCIInputScaleKey];
//
//	CIFilter* displayFilter = [CIFilter filterWithName:@"CIHistogramDisplayFilter"];
//	[displayFilter setValue: @(100.0)
//					 forKey: @"inputHeight"];
//
//	NSAffineTransform* scaleTransform = [NSAffineTransform transform];
//	[scaleTransform scaleXBy: self.frame.size.width/256.0 yBy: self.frame.size.height/100.0];
//
//	CIFilter* scaleFilter = [CIFilter filterWithName: @"CIAffineTransform"];
//	[scaleFilter setValue: scaleTransform
//				   forKey: @"inputTransform"];
//
////	[CATransaction begin];
////	[CATransaction setValue: @(YES) forKey: kCATransactionDisableActions];
//
//	self.layer.filters = @[histogramFilter, displayFilter, scaleFilter];
////	self.layer.transform = CATransform3DMakeScale(self.frame.size.width/256.0, self.frame.size.height/100.0, 1.0);
//
////	[CATransaction commit];
//
//
//}

- (void) setImage: (NSImage*) image
{
	if (!image)
		return;

	if (!CGSizeEqualToSize(image.size, self.window.contentAspectRatio))
	{
		double aspectRatio = image.size.height/image.size.width;
		self.window.contentAspectRatio = image.size;
		[self.window setContentSize: CGSizeMake(self.window.contentView.frame.size.width, self.window.contentView.frame.size.width*aspectRatio)];
	}

	self.layer.contents = image;
	[self setNeedsDisplay: YES];
}

- (void) setJpegData: (NSData*) jpegData
{
	NSImage* image = [[NSImage alloc] initWithData: jpegData];
	
	[self setImage: image];
}

@end

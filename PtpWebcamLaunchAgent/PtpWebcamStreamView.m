//
//  PtpWebcamStreamView.m
//  PtpWebcamLaunchAgent
//
//  Created by Dömötör Gulyás on 10.09.2020.
//  Copyright © 2020 Doemoetoer Gulyas. All rights reserved.
//

#import "PtpWebcamStreamView.h"

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

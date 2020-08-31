//
//  PtpGridTuneView.m
//  PTP Webcam
//
//  Created by Dömötör Gulyás on 31.08.2020.
//  Copyright © 2020 InRobCo. All rights reserved.
//

#import "PtpGridTuneView.h"

#define CELL_SIZE	16.0

@implementation PtpGridTuneView

@synthesize tag=_tag;

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
	[[NSColor blackColor] set];
	[[NSBezierPath bezierPathWithRect: self.frame] fill];
	
	int x = 0, y = 0;
	int rmin = [self.range[@"min"] intValue];
	int rmax = [self.range[@"max"] intValue];
	int rstep = [self.range[@"step"] intValue];
	for (int i = rmin; i <= rmax; i += rstep)
	{
		CGPoint origin = CGPointMake(1 + x*(CELL_SIZE+1), 1 + y*(CELL_SIZE+1));
		CGSize size = CGSizeMake(CELL_SIZE, CELL_SIZE);
		
		double xt = (double)x/_gridSize;
		double yt = (double)y/_gridSize;

		if (i == [_representedObject intValue])
			[[NSColor whiteColor] set];
		else
			[[NSColor colorWithRed: 0.333 + 0.333*(xt)     + 0.333*(yt)
							 green: 0.333 + 0.333*(xt)     + 0.333*(1.0-yt)
							  blue: 0.333 + 0.333*(1.0-xt) + 0.333*(yt)
							 alpha: 1.0] set];
		[[NSBezierPath bezierPathWithRect: CGRectMake(origin.x, origin.y, size.width, size.height)] fill];

		y = y + (x+1)/_gridSize;
		x = (x+1) % _gridSize;
	}

}

- (int) intValue
{
	return [self.representedObject intValue];
}

#define CLAMP(x,a,b) (MIN(MAX((x), (a)), (b)))

//
- (void) selectCellAtPoint:(CGPoint) point
{
	long x = CLAMP(point.x - 1.0, 0, _gridSize*(CELL_SIZE+1)) / (CELL_SIZE+1);
	long y = CLAMP(point.y - 1.0, 0, _gridSize*(CELL_SIZE+1)) / (CELL_SIZE+1);
	
	long val = x + y * _gridSize;
	
	self.representedObject = @(val);
	
	[self setNeedsDisplay: YES];

}

- (void) mouseDown:(NSEvent *)event
{
	CGPoint point = [self convertPoint: [event locationInWindow] fromView: nil];
	[self selectCellAtPoint: point];

}

- (void) mouseDragged:(NSEvent *)event
{
	CGPoint point = [self convertPoint: [event locationInWindow] fromView: nil];
	[self selectCellAtPoint: point];

}

- (void) mouseUp:(NSEvent *)event
{
	CGPoint point = [self convertPoint: [event locationInWindow] fromView: nil];
	[self selectCellAtPoint: point];
	
	if (self.action && self.target)
		((void (*)(id, SEL, id))[self.target methodForSelector: self.action])(self.target, self.action, self);

}

- (void) updateSize
{
	if (_gridSize > 0)
	{
		CGFloat size = _gridSize*CELL_SIZE + (_gridSize + 1);
		self.frameSize = CGSizeMake(size, size);
	}
}

@end

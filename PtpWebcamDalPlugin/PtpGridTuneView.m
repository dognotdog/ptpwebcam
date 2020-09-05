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
{
	id highlightedValue;
	NSTrackingArea* trackingArea;
}

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

		if (highlightedValue && (i == [highlightedValue intValue]))
		{
			[[NSColor whiteColor] set];
			[[NSBezierPath bezierPathWithRect: CGRectMake(origin.x, origin.y, size.width, size.height)] stroke];
		}

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

- (void) highlightCellAtPoint:(CGPoint) point
{
	long x = CLAMP(point.x - 1.0, 0, _gridSize*(CELL_SIZE+1)) / (CELL_SIZE+1);
	long y = CLAMP(point.y - 1.0, 0, _gridSize*(CELL_SIZE+1)) / (CELL_SIZE+1);
	
	long val = x + y * _gridSize;
	
	highlightedValue = @(val);
	
	[self setNeedsDisplay: YES];

}

- (BOOL)acceptsFirstMouse:(NSEvent *)theEvent
{
    return YES;
}

- (void) mouseDown:(NSEvent *)event
{
	CGPoint point = [self convertPoint: [event locationInWindow] fromView: nil];
	[self highlightCellAtPoint: point];
}

- (void) mouseDragged:(NSEvent *)event
{
	CGPoint point = [self convertPoint: [event locationInWindow] fromView: nil];

	bool mouseInRect = CGRectContainsPoint( self.bounds, point);

	if (mouseInRect)
	{
		[self highlightCellAtPoint: point];
	}
	else
	{
		highlightedValue = nil;
		[self setNeedsDisplay: YES];
	}

}

- (void) mouseUp:(NSEvent *)event
{
	CGPoint point = [self convertPoint: [event locationInWindow] fromView: nil];
	[self highlightCellAtPoint: point];
	
	bool mouseUpInRect = CGRectContainsPoint( self.bounds, point);
	if (mouseUpInRect)
	{
		self.representedObject = highlightedValue;
		highlightedValue = nil;
		[self setNeedsDisplay: YES];
		if (self.action && self.target)
			((void (*)(id, SEL, id))[self.target methodForSelector: self.action])(self.target, self.action, self);
	}
	else
	{
		highlightedValue = nil;;
		[self setNeedsDisplay: YES];
	}
}

- (void) updateTrackingAreas
{
	[super updateTrackingAreas];

	if (!trackingArea)
	{
		trackingArea = [[NSTrackingArea alloc] initWithRect: self.bounds options: NSTrackingMouseEnteredAndExited | NSTrackingEnabledDuringMouseDrag | NSTrackingActiveAlways owner: self userInfo: nil];
		[self addTrackingArea: trackingArea];
	}

}

- (void) mouseExited:(NSEvent *)event
{
	highlightedValue = nil;;
	[self setNeedsDisplay: YES];
}

- (void) mouseEntered:(NSEvent *)event
{
	[self mouseMoved: event];
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

//
//  PtpGridTuneView.m
//  PTP Webcam
//
//  Created by Dömötör Gulyás on 31.08.2020.
//  Copyright © 2020 InRobCo. All rights reserved.
//

#import "PtpGridTuneView.h"
#import "PtpWebcamAlerts.h"

#define CELL_SIZE	16.0

@implementation PtpGridTuneView
{
	long highlightedX, highlightedY;
	NSTrackingArea* trackingArea;
}

@synthesize tag=_tag;

- (instancetype)initWithFrame:(NSRect)frameRect {
	self = [super initWithFrame:frameRect];
	highlightedX = -1;
	highlightedY = -1;
	return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
	[[NSColor blackColor] set];
	[[NSBezierPath bezierPathWithRect: self.frame] fill];
	
	NSDictionary* range = self.representedProperty[@"range"];
	
	int x = 0, y = 0;
	//
	for (int i = 0; i <= _gridSize*_gridSize; ++i)
	{
		CGPoint origin = CGPointMake(1 + x*(CELL_SIZE+1), 1 + (_gridSize - y - 1)*(CELL_SIZE+1));
		CGSize size = CGSizeMake(CELL_SIZE, CELL_SIZE);
		
		double xt = (double)x/_gridSize;
		double yt = (double)y/_gridSize;

		if ([self valueFromX: x y: y] == [_representedProperty[@"value"] intValue])
			[[NSColor whiteColor] set];
		else
		{
			NSColor* green = [NSColor greenColor];
			NSColor* blue = [NSColor blueColor];
			NSColor* magenta = [NSColor magentaColor];
			NSColor* amber = [NSColor orangeColor];
			NSColor* xy = [blue blendedColorWithFraction: 0.5 ofColor: green];
			NSColor* xY = [blue blendedColorWithFraction: 0.5 ofColor: magenta];
			NSColor* Xy = [amber blendedColorWithFraction: 0.5 ofColor: green];
			NSColor* XY = [amber blendedColorWithFraction: 0.5 ofColor: magenta];
			NSColor* xc = [xy blendedColorWithFraction: xt ofColor: Xy];
			NSColor* Xc = [xY blendedColorWithFraction: xt ofColor: XY];
			NSColor* xyc = [xc blendedColorWithFraction: yt ofColor: Xc];
			[xyc set];
		}
		[[NSBezierPath bezierPathWithRect: CGRectMake(origin.x, origin.y, size.width, size.height)] fill];

		if ((x == highlightedX) && (y == highlightedY))
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
	return [self.representedProperty[@"value"] intValue];
}

#define CLAMP(x,a,b) (MIN(MAX((x), (a)), (b)))

//
- (void) selectCellAtPoint:(CGPoint) point
{
	long x = CLAMP(point.x - 1.0, 0, _gridSize*(CELL_SIZE+1)) / (CELL_SIZE+1);
	long y = CLAMP(point.y - 1.0, 0, _gridSize*(CELL_SIZE+1)) / (CELL_SIZE+1);
	
	long val = x + (_gridSize - y - 1) * _gridSize;
	
	self.representedProperty[@"value"] = @(val);
	
	[self setNeedsDisplay: YES];

}

- (long) valueFromX:(long) x y: (long) y
{
	// grid size of 168 from Nikon is a simple grid
	// grid size of 1224 is a BCD encoded weirdness (12 across y, 24 across x)
	long rmin = [self.representedProperty[@"range"][@"min"] longValue];
	long rmax = [self.representedProperty[@"range"][@"max"] longValue];
	if ((rmin == 0) && (rmax == 168) && (_gridSize == 13))
	{
		return x + y*_gridSize;
	}
	else if ((rmin == 0) && (rmax == 1224) && (_gridSize == 13))
	{
		return x*2 + y*100;
	}
	else
	{
		// else oops
		PtpLog(@"unknown grid format for property %@", self.representedProperty);
		return 0;
	}
}

- (long) highlightedValue
{
	return [self valueFromX: highlightedX y: highlightedY];
}

- (void) highlightCellAtPoint:(CGPoint) point
{
	long x = CLAMP(point.x - 1.0, 0, _gridSize*(CELL_SIZE+1)) / (CELL_SIZE+1);
	long y = CLAMP(point.y - 1.0, 0, _gridSize*(CELL_SIZE+1)) / (CELL_SIZE+1);
	highlightedX = x;
	highlightedY = _gridSize - y - 1;
	
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
		highlightedX = -1;
		highlightedY = -1;
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
		self.representedProperty[@"value"] = @([self highlightedValue]);
		highlightedX = -1;
		highlightedY = -1;
		[self setNeedsDisplay: YES];
		if (self.action && self.target)
			((void (*)(id, SEL, id))[self.target methodForSelector: self.action])(self.target, self.action, self);
	}
	else
	{
		highlightedX = -1;
		highlightedY = -1;
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
	highlightedX = -1;
	highlightedY = -1;
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

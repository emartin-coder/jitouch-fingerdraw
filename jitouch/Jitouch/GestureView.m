//
//  GestureView.m
//  Jitouch
//
//  Copyright 2021 Supasorn Suwajanakorn and Sukolsak Sakshuwong. All rights reserved.
//

#import "GestureView.h"

@implementation GestureView

- (id)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        points = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor clearColor] set];
    NSRectFill([self frame]);

    CGContextRef context = [[NSGraphicsContext currentContext]graphicsPort];

    if ([points count] > 0) {
        NSPoint currentPoint;
        CGContextSetLineWidth(context, 12.0);

        currentPoint = [[points objectAtIndex:0] pointValue];
        CGContextSetRGBStrokeColor(context, 0.7, 0, 0, 0.6);
        CGContextStrokeEllipseInRect(context, CGRectMake(currentPoint.x-15, currentPoint.y-15, 30, 30));

        CGContextSetRGBStrokeColor(context, 1, 1, 1, 0.3);
        CGContextSetLineCap(context, kCGLineCapRound);
        CGContextSetLineJoin(context, kCGLineJoinRound);

        NSPoint startPoint = [[points objectAtIndex:0] pointValue];
        CGContextMoveToPoint(context, startPoint.x, startPoint.y);
        float minX = 10000, minY = 10000;
        BOOL penUp = NO;
        for (NSUInteger i = 1; i < [points count]; i++) {
            currentPoint = [[points objectAtIndex:i] pointValue];
            if (isnan(currentPoint.x)) { penUp = YES; continue; }
            if (penUp) CGContextMoveToPoint(context, currentPoint.x, currentPoint.y);
            else CGContextAddLineToPoint(context, currentPoint.x, currentPoint.y);
            penUp = NO;
            if (currentPoint.x < minX)
                minX = currentPoint.x;
            if (currentPoint.y < minY)
                minY = currentPoint.y;
        }
        CGContextStrokePath(context);

        CGContextSetLineWidth(context, 10.0);
        CGContextSetRGBStrokeColor(context, 0, 0, 0, 0.6);
        CGContextMoveToPoint(context, startPoint.x, startPoint.y);
        penUp = NO;
        for (NSUInteger i = 1; i < [points count]; i++) {
            currentPoint = [[points objectAtIndex:i] pointValue];
            if (isnan(currentPoint.x)) { penUp = YES; continue; }
            if (penUp) CGContextMoveToPoint(context, currentPoint.x, currentPoint.y);
            else CGContextAddLineToPoint(context, currentPoint.x, currentPoint.y);
            penUp = NO;
        }
        CGContextStrokePath(context);

        // Where your finger is now (or just landed for the next stroke), so you can aim the next stroke.
        for (NSInteger i = (NSInteger)[points count] - 1; i >= 0; i--) {
            NSPoint p = [[points objectAtIndex:i] pointValue];
            if (isnan(p.x)) continue;
            CGContextSetRGBFillColor(context, 1, 0.55, 0.2, 0.85);
            CGContextFillEllipseInRect(context, CGRectMake(p.x - 9, p.y - 9, 18, 18));
            CGContextSetLineWidth(context, 3.0);
            CGContextSetRGBStrokeColor(context, 1, 1, 1, 0.9);
            CGContextStrokeEllipseInRect(context, CGRectMake(p.x - 9, p.y - 9, 18, 18));
            break;
        }

        [[NSString stringWithUTF8String:hintText]
         drawAtPoint:CGPointMake(minX, minY - 70.0)
         withAttributes:@{
                          NSFontAttributeName: [NSFont systemFontOfSize:40.0],
                          NSForegroundColorAttributeName: [NSColor colorWithRed:0.7 green:0.0 blue:0.0 alpha:0.5]
                          }];
    }
}

- (void)addPointX:(float)x Y:(float)y {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    CGFloat width = [self frame].size.width - 30 - 150;
    CGFloat height = [self frame].size.height - 30 - 100;

    NSValue *point = [NSValue valueWithPoint:NSMakePoint(x*width + 15, y*height + 15 + 100)];
    [points addObject:point];
    [pool release];

    [self setNeedsDisplay:YES];
}

- (void)addRelativePointX:(float)x Y:(float)y {
    CGFloat width = [self frame].size.width;
    CGFloat height = [self frame].size.height;

    NSValue *point = [NSValue valueWithPoint:NSMakePoint(width/2 + x, height/2 + y)];
    [points addObject:point];
    [self setNeedsDisplay:YES];
}

- (void)breakStroke { // pen lift between strokes of a multi-stroke letter
    [points addObject:[NSValue valueWithPoint:NSMakePoint(NAN, NAN)]];
}
- (void)clear {
    [points removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (void)setHintText:(const char*)str {
    strcpy(hintText, str);
}

- (void)dealloc {
    [points release];
    [super dealloc];
}

@end

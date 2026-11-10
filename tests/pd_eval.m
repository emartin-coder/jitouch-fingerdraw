// Scores one sample against the trained handwriting in $JITOUCH_LETTERS, using the app's own $P code.
// Usage: JITOUCH_LETTERS=others.txt build/pd_eval "LETTER x,y,s x,y,s ..."   -> prints "best score"
#import <Foundation/Foundation.h>
#include <float.h>
#include "../jitouch/Jitouch/PDollar.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        NSArray *parts = [[NSString stringWithUTF8String:argv[1]] componentsSeparatedByString:@" "];
        PDPoint pts[4096];
        int n = 0;
        for (NSUInteger i = 1; i < [parts count] && n < 4096; i++) {
            NSArray *xys = [[parts objectAtIndex:i] componentsSeparatedByString:@","];
            if ([xys count] == 3)
                pts[n++] = (PDPoint){[[xys objectAtIndex:0] floatValue], [[xys objectAtIndex:1] floatValue], [[xys objectAtIndex:2] intValue]};
        }
        float score;
        const char *best = pdollarRecognize(pts, n, FLT_MAX, &score, 1);
        printf("%s %.3f\n", best ? best : "-", score);
    }
    return 0;
}

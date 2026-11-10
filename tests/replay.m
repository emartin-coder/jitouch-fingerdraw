// Replays a touch_probe recording through magicMouseFingerRecognizer and prints each state change and result.
// Run: tests/replay.sh <recording.log>
#import <Cocoa/Cocoa.h>
static NSString *jtTestRecognized;
#define JITOUCH_TEST 1
#define JITOUCH_TRACE 1
#include "../jitouch/Jitouch/Gesture.m"

int main(int argc, char **argv) {
    @autoreleasepool {
        initNormPdf();
        initChars();
        clickSpeed = 0.25f;
        enCharRegMM = 1;
        FILE *in = fopen(argv[1], "r");
        if (!in) { perror(argv[1]); return 2; }
        char line[8192];
        while (fgets(line, sizeof line, in)) {
            double ts; int n;
            if (sscanf(line, "%lf n=%d", &ts, &n) != 2) continue;
            Finger d[16];
            int k = 0;
            for (char *p = strstr(line, "[id="); p && k < 16; p = strstr(p + 1, "[id=")) {
                memset(&d[k], 0, sizeof(Finger));
                sscanf(p, "[id=%d st=%d x=%f y=%f sz=%f]", &d[k].identifier, (int *)&d[k].state, &d[k].px, &d[k].py, &d[k].size);
                k++;
            }
            const char *b = strstr(line, "btn=");
            jtTestButtonDown = b ? atoi(b + 4) : 0; // recordings made before 2026-11-10 12:30 have no button column
            magicMouseFingerRecognizer(d, k, ts);
            if (jtTestRecognized) {
                printf("%.3f RECOGNIZED \"%s\"\n", ts, [jtTestRecognized UTF8String]);
                [jtTestRecognized release];
                jtTestRecognized = nil;
            }
        }
    }
    return 0;
}

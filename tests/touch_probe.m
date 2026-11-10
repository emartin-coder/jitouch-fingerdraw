// Hardware check: prints Magic Mouse touch frames for N seconds (default 15) via MultitouchSupport.
// Build+run: tests/probe.sh [seconds]. Touch the mouse while it runs; "frames with touches" > 0 means the OS delivers data.
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTReadout;
typedef struct {
    int frame; double timestamp; int identifier, state, fingerId, handId;
    MTReadout normalized; float size; int zero1; float angle, majorAxis, minorAxis;
    MTReadout mm; int zero2[2]; float zDensity;
} Finger;
typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef, Finger *, int, double, int);
CFMutableArrayRef MTDeviceCreateList(void);
void MTDeviceGetFamilyID(MTDeviceRef, int *);
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTDeviceStart(MTDeviceRef, int);

static int frames, touchFrames;
static int callback(MTDeviceRef dev, Finger *f, int n, double ts, int frame) {
    frames++;
    if (n > 0) touchFrames++;
    int btn = CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft) ||
              CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonRight);
    printf("%.3f n=%d btn=%d", ts, n, btn);
    for (int i = 0; i < n; i++)
        printf("  [id=%d st=%d x=%.3f y=%.3f sz=%.2f]", f[i].identifier, f[i].state, f[i].normalized.pos.x, f[i].normalized.pos.y, f[i].size);
    printf("\n");
    fflush(stdout);
    return 0;
}

int main(int argc, char **argv) {
    double secs = argc > 1 ? atof(argv[1]) : 15;
    CFArrayRef devs = MTDeviceCreateList();
    int mice = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(devs); i++) {
        MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(devs, i);
        int fam = 0;
        MTDeviceGetFamilyID(d, &fam);
        printf("device %ld family %d%s\n", (long)i, fam, fam == 112 ? " (Magic Mouse)" : "");
        if (fam == 112) { MTRegisterContactFrameCallback(d, callback); MTDeviceStart(d, 0); mice++; }
    }
    if (!mice) { printf("NO MAGIC MOUSE FOUND\n"); return 2; }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, secs, false);
    printf("frames=%d  frames with touches=%d\n", frames, touchFrames);
    return touchFrames > 0 ? 0 : 1;
}

//
//  Gesture.m
//  Jitouch
//
//  Copyright 2021 Supasorn Suwajanakorn and Sukolsak Sakshuwong. All rights reserved.
//  Modified work Copyright 2021 Aaron Kollasch. All rights reserved.
//

#import "Gesture.h"
#import "PDollar.h"
#include <pthread.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <mach/mach_time.h>
#include <libproc.h>
#import <math.h>
#import <unistd.h>
#import <CoreFoundation/CoreFoundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

#import "Settings.h"
#import "JitouchAppDelegate.h"
#import "CursorWindow.h"
#import "CursorView.h"
#import "GestureWindow.h"
#import "SizeHistory.h"
#import "KeyUtility.h"

#define TRACKPAD 0
#define MAGICMOUSE 1
#define CHARRECOGNITION 2
static const NSString* deviceTypeName[] = {@"trackpad", @"magicmouse", @"charrec"};

static const int builtinTrackpadFamilyIDs[] = {
    98, 99, 100, // built-in trackpad
    101, // retina mbp
    102, // retina macbook with the Force Touch trackpad (2015)
    103, // retina mbp 13" with the Force Touch trackpad (2015)
    104,
    105, // macbook with touch bar, m1 pro mbp
    113, // m2 mbp with touch bar
};
static const int magicMouseFamilyIDs[] = {
    112, // magic mouse & magic mouse 2
};
static const int magicTrackpadFamilyIDs[] = {
    128, // magic trackpad
    129, // magic trackpad 2
    130, // magic trackpad 3?
};
#define MINFAMILYID 98

#define px normalized.pos.x
#define py normalized.pos.y
#define HS(a)  ((a * 7907 + 7883) % 4493)
#define CFSafeRelease(a) if (a)CFRelease(a);

#define MIDDLEBUTTONDOWN 1
#define LEFTBUTTONDOWN 2
#define RIGHTBUTTONDOWN 3
#define COMMANDANDLEFTBUTTONDOWN 4
//#define COMMANDDOWN 5
#define IGNOREMOUSE 6
#define IGNOREKEY 7

#define PI 3.1415926535897932384626433832795028841971

// to suppress "'CGPostKeyboardEvent' is deprecated" warnings
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

#ifndef DEBUG
#define DEBUG FALSE
#endif

@implementation Gesture

// Based on the code at http://steike.com/code/multitouch
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTReadout;

enum {
    MTTouchStateNotTracking = 0,
    MTTouchStateStartInRange = 1,
    MTTouchStateHoverInRange = 2,
    MTTouchStateMakeTouch = 3,
    MTTouchStateTouching = 4,
    MTTouchStateBreakTouch = 5,
    MTTouchStateLingerInRange = 6,
    MTTouchStateOutOfRange = 7
};
typedef uint32_t MTTouchState;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    MTTouchState state;
    int fingerId, handId;
    MTReadout normalized;
    float size;
    int zero1;
    float angle, majorAxis, minorAxis; // ellipsoid
    MTReadout mm;
    int zero2[2];
    float zDensity;
} Finger;

typedef CFTypeRef *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef, Finger*, int, double, int);

MTDeviceRef MTDeviceCreateDefault(void);
CFMutableArrayRef MTDeviceCreateList(void);
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTDeviceStart(MTDeviceRef, int);
void MTUnregisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTDeviceStop(MTDeviceRef);
void MTDeviceRelease(MTDeviceRef);
bool MTDeviceIsRunning(MTDeviceRef);
void MTDeviceGetFamilyID(MTDeviceRef, int*);
OSStatus MTDeviceGetDeviceID(MTDeviceRef, uint64_t*) __attribute__ ((weak_import));    // no 10.5

void CoreDockSendNotification(NSString *notificationName);

static AXUIElementRef systemWideElement = NULL;


static CFMachPortRef eventTap;
static BOOL recreatingEventTap;

static int quickTabSwitching;

static int middleClickFlag, magicMouseThreeFingerFlag;
static int trackpadNFingers, trackpadClicked;
static int autoScrollFlag;
static int moveResizeFlag, shouldExitMoveResize;

// distance between two fingers to suppress left click in next/prev tab gesture
static float twoFingersDistance = 100.0f;
static BOOL trackpadHasTwoFingers;
static NSDate *lastTwoFingerDate;
static NSDate *lastThreeFingerDate;

// suppress four-finger tap if pinky-to-index or index-to-pinky gestures were triggered
static BOOL trackpadTab4Triggered = FALSE;
static int trackpadTab4Step[2] = {0, 0};
static BOOL fourFingerTapTriggered = FALSE;

static int trigger = 0;

static int disableHorizontalScroll;

static GestureWindow *gestureWindow;

static Gesture *me;

static int simulating, simulatingByDevice;

static NSMutableDictionary *sizeHistoryDict;

static KeyUtility *keyUtil;

/* Character Recognizer Begin */
typedef struct {
    float deg, span;
    int type;
} DegreeSpan;
typedef struct {
    DegreeSpan ds[10];
    const char *ch;
    int step;
    float score;
} Character;
static Character chars[100];
static int nChars;

static float normPdf[201];
static float normIPdf[201];
static void trackpadRecognizerTwo(const Finger *data, int nFingers, double timestamp);
static void trackpadRecognizerOne(const Finger *data, int nFingers, double timestamp);
static int mouseRecognizer(float x, float y, int step);
static void magicMouseFingerRecognizer(const Finger *data, int nFingers, double timestamp);
static void initChars(void);
static void initNormPdf(void);
static int isTrackpadRecognizing, isMouseRecognizing, isMMFingerRecognizing;
// Set by the event tap: when the system last scrolled (including momentum) and when a mouse button went down.
// A Magic Mouse click and a scroll flick both start with a touch, so these tell a deliberate tap apart from them.
static volatile double mmLastScrollWall, mmLastClickWall;
static const int64_t mmSynthMark = 0x4A54464E; // tags clicks we post, so they don't count as you clicking
static volatile int mmDragging; // 1: dragging, pointer moves become drags. 2: finger just lifted, item held still
static volatile double mmLastMoveWall; // last time the pointer moved on its own (not while we drag)
static volatile double mmLastFrameWall, mmLastReleaseWall; // last touch frame; last drag release
static volatile int mmHwPress; // a real button press during our drag: it owns the button now
static CGPoint mmLiftPtr; // where the pointer was on the frame the finger lifted
void mmForceRelease(void);
static void mmLogLine(const char *line);
// Drag smoothness probe: how long each pointer move waited before the event tap (on the main thread) saw it.
static volatile uint64_t mmLatN, mmLatSumUp, mmLatMaxUp; static volatile int64_t mmLatMach0;
#ifdef JITOUCH_TEST
static int jtTestButtonDown; // tests stand in for the physical button
#endif
static int cancelRecognition;
/* Character Recognizer End */


static double lenSqr(double x1, double y1, double x2, double y2) {
    return (x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2);
}

static double lenSqrF(const Finger *data, int a, int b) {
    return lenSqr(data[a].px, data[a].py, data[b].px, data[b].py);
}

static float cosineBetweenVectors(float v0x, float v0y, float v1x, float v1y) {
    return (v0x*v1x + v0y*v1y) / sqrtf((v0x*v0x + v0y*v0y) * (v1x*v1x + v1y*v1y));
}

static bool familyIsBuiltinTrackpad(int familyID) {
    for (int i = 0; i < sizeof(builtinTrackpadFamilyIDs) / sizeof(builtinTrackpadFamilyIDs[0]); i++) {
        if(builtinTrackpadFamilyIDs[i] == familyID)
            return TRUE;
    }
    return FALSE;
}

static bool familyIsMagicMouse(int familyID) {
    for (int i = 0; i < sizeof(magicMouseFamilyIDs) / sizeof(magicMouseFamilyIDs[0]); i++) {
        if(magicMouseFamilyIDs[i] == familyID)
            return TRUE;
    }
    return FALSE;
}

static bool familyIsMagicTrackpad(int familyID) {
    for (int i = 0; i < sizeof(magicTrackpadFamilyIDs) / sizeof(magicTrackpadFamilyIDs[0]); i++) {
        if(magicTrackpadFamilyIDs[i] == familyID)
            return TRUE;
    }
    return FALSE;
}

static void turnOffTrackpad() {
    trackpadNFingers = 0;
}

static void turnOffMagicMouse() {
    middleClickFlag = 0;
    magicMouseThreeFingerFlag = 0;
    simulating = 0;
    disableHorizontalScroll = 0;
    quickTabSwitching = 0;
    // The touch thread calls this too, and AppKit crashes on window changes off the main thread (crash 2026-11-10).
    dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow orderOut:nil]; });
}

static void turnOffCharacters() {
    dispatch_async(dispatch_get_main_queue(), ^{ // may be called off the main thread, like turnOffMagicMouse
        [gestureWindow clear];
        [gestureWindow orderOut:nil];
    });
    isTrackpadRecognizing = 0;
    isMouseRecognizing = 0;
    isMMFingerRecognizing = 0;
}

void turnOffGestures() {
    mmForceRelease();
    turnOffTrackpad();
    turnOffMagicMouse();
    turnOffCharacters();
}

static void mouseClick(int a, CGFloat x, CGFloat y) {
    CGPoint location = CGPointMake(x, y);

    if (a & 4) {
        CGEventRef eventRef = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDragged, location, kCGMouseButtonLeft);
        CGEventPost(kCGSessionEventTap, eventRef);
        CFRelease(eventRef);
    }
    if (a & 8) {
        CGEventRef eventRef = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, location, kCGMouseButtonLeft);
        CGEventPost(kCGSessionEventTap, eventRef);
        CFRelease(eventRef);
    }
    if (a & 1) {
        CGEventRef eventRef = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, location, kCGMouseButtonLeft);
        CGEventPost(kCGSessionEventTap, eventRef);
        CFRelease(eventRef);
    }
    if (a & 2) {
        CGEventRef eventRef = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, location, kCGMouseButtonLeft);
        CGEventPost(kCGSessionEventTap, eventRef);
        CFRelease(eventRef);
    }
}

static void getMousePosition(CGFloat *x, CGFloat *y) {
    CGEventRef ourEvent = CGEventCreate(NULL);
    CGPoint ourLoc = CGEventGetLocation(ourEvent);
    CFRelease(ourEvent);
    *x = ourLoc.x;
    *y = ourLoc.y;
}

static CFTypeRef getForemostApp() {
    CFTypeRef focusedAppRef;
    if (systemWideElement && AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedApplicationAttribute, &focusedAppRef) != kAXErrorSuccess) {
        NSRunningApplication *frontmostApplication = [[NSWorkspace sharedWorkspace] frontmostApplication];
        focusedAppRef = AXUIElementCreateApplication([frontmostApplication processIdentifier]);
        if (focusedAppRef == NULL) {
            return NULL;
        }
    }
    CFTypeRef focusedWindowRef;

    // does this code belong here?
    CFTypeRef titleRef;
    if (AXUIElementCopyAttributeValue(focusedAppRef, kAXTitleAttribute, &titleRef) == kAXErrorSuccess) {
        if (
            [(NSString*)titleRef isEqualToString:@"Notification Center"] ||
            [(NSString*)titleRef isEqualToString:@"Control Center"]
        ) {
            CFRelease(titleRef);
            return NULL;
        }
        CFRelease(titleRef);
    }

    if (AXUIElementCopyAttributeValue(focusedAppRef, kAXFocusedWindowAttribute, &focusedWindowRef) == kAXErrorSuccess) {
        CFRelease(focusedAppRef);
        return focusedWindowRef;
    }
    CFRelease(focusedAppRef);
    return NULL;
}

static void getWindowPos(CFTypeRef winRef, CGFloat *x, CGFloat *y) {
    CFTypeRef positionRef;
    if (winRef && AXUIElementCopyAttributeValue(winRef, kAXPositionAttribute, &positionRef) == kAXErrorSuccess) {
        CGPoint pos;
        AXValueGetValue((AXValueRef)positionRef, kAXValueCGPointType, &pos);
        *x = pos.x;
        *y = pos.y;
        CFRelease(positionRef);
    }
}

static void getWindowSize(CFTypeRef winRef, CGFloat *w, CGFloat *h) {
    CFTypeRef sizeRef;
    if (winRef && AXUIElementCopyAttributeValue(winRef, kAXSizeAttribute, &sizeRef) == kAXErrorSuccess) {
        CGSize size;
        AXValueGetValue((AXValueRef)sizeRef, kAXValueCGSizeType, &size);
        *w = size.width;
        *h = size.height;
        CFRelease(sizeRef);
    }
}

static void setWindowPos(CFTypeRef window, CGFloat x, CGFloat y) {
    CGPoint t1 = CGPointMake(x, y);
    CFTypeRef newLocRef = AXValueCreate(kAXValueCGPointType, (void *)&t1);
    if (newLocRef) {
        if (window)
            AXUIElementSetAttributeValue(window, kAXPositionAttribute, newLocRef);
        CFRelease(newLocRef);
    }
}

static int setWindowSize(CFTypeRef window, CGFloat w, CGFloat h) {
    CGSize t2 = CGSizeMake(w, h);
    CFTypeRef newSizeRef = AXValueCreate(kAXValueCGSizeType, (void *)&t2);
    if (newSizeRef) {
        if (window && AXUIElementSetAttributeValue(window, kAXSizeAttribute, newSizeRef) != kAXErrorSuccess) {
            CFRelease(newSizeRef);
            return 0;
        }
        CFRelease(newSizeRef);
    }
    return 1;
}
static void setWindowPos2(CFTypeRef window, CGFloat x, CGFloat y, CGFloat baseX, CGFloat baseY, CGFloat appX, CGFloat appY) {
    setWindowPos(window, appX+x-baseX, appY+y-baseY);
}
static int setWindowSize2(CFTypeRef window, CGFloat x, CGFloat y, CGFloat baseX, CGFloat baseY) {
    CGFloat appW, appH;
    getWindowSize(window, &appW, &appH);
    return setWindowSize(window, appW+x-baseX, appH+y-baseY);
}
static void maximizeForemostWindow() {
    CFTypeRef winRef = getForemostApp();
    if (winRef) {
        CFTypeRef zoomButton;
        if (AXUIElementCopyAttributeValue(winRef, kAXZoomButtonAttribute, &zoomButton) == kAXErrorSuccess) {
            AXUIElementPerformAction(zoomButton, kAXPressAction);
            CFRelease(zoomButton);
        }
        CFRelease(winRef);
    }
}
static void minimizeForemostWindow() {
    CFTypeRef winRef = getForemostApp();
    if (winRef) {
        CFTypeRef minButton;
        if (AXUIElementCopyAttributeValue(winRef, kAXMinimizeButtonAttribute, &minButton) == kAXErrorSuccess) {
            AXUIElementPerformAction(minButton, kAXPressAction);
            CFRelease(minButton);
        }
        CFRelease(winRef);
    }
}
static void maximizeWindow(CFTypeRef window, int pos) {
    if (!window) return;

    NSArray *screens = [NSScreen screens];
    CGEventRef ourEvent = CGEventCreate(NULL);
    CGPoint location = CGEventGetUnflippedLocation(ourEvent);
    CFRelease(ourEvent);

    NSUInteger isIn = 0;
    for (NSUInteger i = 0; i < [screens count]; i++) {
        NSRect scr = [[screens objectAtIndex:i] frame];
        NSPoint origin = scr.origin;
        NSSize size = scr.size;

        if (location.x >= origin.x && location.x <= origin.x + size.width &&
           location.y >= origin.y && location.y <= origin.y + size.height) {
            isIn = i;
            break;
        }
    }
    NSRect scr = [[screens objectAtIndex:isIn] visibleFrame];
    NSPoint origin = scr.origin;
    NSSize size = scr.size;

    CGFloat appW, appH, appX, appY;
    getWindowSize(window, &appW, &appH);
    getWindowPos(window, &appX, &appY);
    SizeHistoryKey *key = [[SizeHistoryKey alloc] initWithKey:window];
    SizeHistory *sh = [sizeHistoryDict objectForKey:key];
    if (pos == 0) {
        if (sh) {
            if (appX == sh.curRect.origin.x && appY == sh.curRect.origin.y && appW == sh.curRect.size.width && appH == sh.curRect.size.height) {
                setWindowPos(window, sh.savRect.origin.x, sh.savRect.origin.y);
                setWindowSize(window, sh.savRect.size.width, sh.savRect.size.height);
            }
            [sizeHistoryDict removeObjectForKey:key];
        }
    } else {
        if (pos == 1) {
            setWindowPos(window, origin.x, [[screens objectAtIndex:0] frame].size.height - origin.y - size.height);
            setWindowSize(window, size.width, size.height);
        } else if (pos == 2) {
            setWindowPos(window, origin.x, [[screens objectAtIndex:0] frame].size.height - origin.y - size.height);
            setWindowSize(window, size.width / 2, size.height);
        }  else if (pos == 3) {
            setWindowPos(window, origin.x + size.width / 2, [[screens objectAtIndex:0] frame].size.height - origin.y - size.height);
            setWindowSize(window, size.width / 2, size.height);
         }
        CGFloat appW2, appH2, appX2, appY2;
        getWindowSize(window, &appW2, &appH2);
        getWindowPos(window, &appX2, &appY2);

        if (!sh || sh.curRect.size.width != appW || sh.curRect.size.height != appH || sh.curRect.origin.x != appX || sh.curRect.origin.y != appY) {
            SizeHistory *newSH = [[SizeHistory alloc] initWithCurRect:NSMakeRect(appX2, appY2, appW2, appH2) SaveRect:NSMakeRect(appX, appY, appW, appH)];
            [sizeHistoryDict setObject:(id)newSH forKey:key];
            [newSH release];
        } else if (sh) {
            SizeHistory *newSH = [[SizeHistory alloc] initWithCurRect:NSMakeRect(appX2, appY2, appW2, appH2) SaveRect:sh.savRect];
            [sizeHistoryDict setObject:(id)newSH forKey:key];
            [newSH release];
        }
    }
    [key release];
}

static NSString* nameOfAxui(CFTypeRef ref) {
    pid_t theTgtAppPID = 0;
    ProcessSerialNumber theTgtAppPSN = {0, 0};
    CFStringRef processName = NULL;
    if (AXUIElementGetPid(ref, &theTgtAppPID) == kAXErrorSuccess &&
        GetProcessForPID(theTgtAppPID, &theTgtAppPSN) == noErr) {
        CopyProcessName(&theTgtAppPSN, &processName);
    }
    return (NSString *)processName;
}

static CFTypeRef activateWindowAtPosition(CGFloat x, CGFloat y) {
    AXUIElementRef focusedElement;
    CFTypeRef windowRef, tmp;
    pid_t theTgtAppPID = 0;
    ProcessSerialNumber theTgtAppPSN = {0, 0};

    if (systemWideElement && AXUIElementCopyElementAtPosition(systemWideElement, x, y, &focusedElement) == kAXErrorSuccess) {
        // Catch app such as TextMate that doesn't provide accessibilty interface
        if (AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute, &tmp) != kAXErrorSuccess) {
            if (AXUIElementGetPid(focusedElement, &theTgtAppPID) == kAXErrorSuccess &&
                GetProcessForPID(theTgtAppPID, &theTgtAppPSN) == noErr &&
                SetFrontProcess(&theTgtAppPSN) == noErr) {
                CFRelease(focusedElement);
                AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedApplicationAttribute, &tmp);
                if (tmp && AXUIElementCopyAttributeValue(tmp, kAXFocusedWindowAttribute, &windowRef) == kAXErrorSuccess) {
                    CFRelease(tmp);
                    return windowRef;
                }
                CFSafeRelease(tmp);
                return NULL;
            }
            CFRelease(focusedElement);
        } else {
            CFRelease(tmp);
            if (AXUIElementCopyAttributeValue(focusedElement, kAXWindowAttribute, &windowRef) != kAXErrorSuccess) {
                windowRef = focusedElement;
            }
            AXUIElementPerformAction(windowRef, kAXRaiseAction);
            if (AXUIElementGetPid(windowRef, &theTgtAppPID) == kAXErrorSuccess &&
                GetProcessForPID(theTgtAppPID, &theTgtAppPSN) == noErr &&
                SetFrontProcessWithOptions(&theTgtAppPSN, kSetFrontProcessFrontWindowOnly) == noErr) {
            }
            if (windowRef != focusedElement)
                CFRelease(focusedElement);
            return windowRef;
        }
    }
    return nil;
}

static CGFloat findTabGroup_lx;
static void findTabGroup2(CFTypeRef windowRef, float cx, float cy) {
    CFTypeRef tmp, tmp2;
    float tabY = 0.0;
    int flag = 1;

    // windowRef = AXWindow of Safari
    if (windowRef && AXUIElementCopyAttributeValue(windowRef, kAXChildrenAttribute, &tmp) == kAXErrorSuccess) {
        CFIndex nCh = CFArrayGetCount((CFArrayRef)tmp);
        for (CFIndex i = 0; i < nCh && flag; i++) {
            CFTypeRef menuTitle = nil;
            CFTypeRef theMenu = (CFStringRef)CFArrayGetValueAtIndex(tmp, i);
            if (theMenu && AXUIElementCopyAttributeValue((AXUIElementRef)theMenu, kAXRoleAttribute, (CFTypeRef *)&menuTitle) == kAXErrorSuccess
               && menuTitle && ((CFStringCompare(menuTitle, CFSTR("AXTabGroup"), 0) == kCFCompareEqualTo))) {

                // Now theMenu = AXGroup
                if (AXUIElementCopyAttributeValue(theMenu, kAXTabsAttribute, &tmp2) == kAXErrorSuccess) {
                    CFIndex nCh = CFArrayGetCount((CFArrayRef)tmp2);
                    for (CFIndex i = 0; i < nCh && flag; i++) {
                        CFTypeRef theMenu = (CFStringRef)CFArrayGetValueAtIndex(tmp2, i);

                        CGFloat x, y, w, h;
                        getWindowPos(theMenu, &x, &y);
                        getWindowSize(theMenu, &w, &h);
                        tabY = y;
                        if (cx >= x && cx < x+w) {
                            if (fabs(findTabGroup_lx - x) > 10) {
                                AXUIElementPerformAction(theMenu, kAXPressAction);
                                flag = 0;
                            }
                            findTabGroup_lx = x;
                        }
                    }
                    CFRelease(tmp2);
                }
            }
            CFSafeRelease(menuTitle);
        }
        CFRelease(tmp);
    }
    NSRect scr = [[NSScreen mainScreen] frame];
    dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow setFrameOrigin:NSMakePoint(cx - 31, scr.size.height - tabY - 20)]; }); // AppKit only on the main thread
}

static int selectSafariTab() {
    CGFloat x, y;
    int ret = 0;
    getMousePosition(&x, &y);
    AXUIElementRef focusedElement;
    CFTypeRef windowRef = NULL;
    pid_t theTgtAppPID = 0;
    ProcessSerialNumber theTgtAppPSN = {0, 0};

    if (systemWideElement && AXUIElementCopyElementAtPosition(systemWideElement, x, y, &focusedElement) == kAXErrorSuccess) {
        if (AXUIElementGetPid(focusedElement, &theTgtAppPID) == kAXErrorSuccess &&
            GetProcessForPID(theTgtAppPID, &theTgtAppPSN) == noErr) {

            CFStringRef processName = NULL;
            CopyProcessName(&theTgtAppPSN, &processName);
            if (CFStringCompare(processName, CFSTR("Safari"), 0) == kCFCompareEqualTo) {

                if (focusedElement && AXUIElementCopyAttributeValue(focusedElement, kAXWindowAttribute, &windowRef) != kAXErrorSuccess)
                    windowRef = focusedElement;
                findTabGroup2(windowRef, x, y);
                ret = 1;
                if (windowRef != focusedElement)
                    CFSafeRelease(windowRef);
            }
            CFSafeRelease(processName);
        }
        CFRelease(focusedElement);
    }
    return ret;
}

static CFTypeRef axuiUnderMouse() {
    CGFloat x, y;
    AXUIElementRef focusedElement = nil;
    getMousePosition(&x, &y);
    if (systemWideElement)
        AXUIElementCopyElementAtPosition(systemWideElement, x, y, &focusedElement);
    return focusedElement;
}

static BOOL isMouseOnEmptySpace() {
    BOOL ret = NO;
    CFTypeRef axui = axuiUnderMouse();
    NSString *application = nameOfAxui(axui);
    if ([application isEqualToString:@"Finder"]) {
        CFTypeRef windowRef = nil;
        CFStringRef roleRef = nil;
        if (axui && AXUIElementCopyAttributeValue(axui, kAXWindowAttribute, &windowRef) == kAXErrorSuccess) {
            if (windowRef && AXUIElementCopyAttributeValue((AXUIElementRef)windowRef, kAXRoleAttribute, (CFTypeRef*)&roleRef) == kAXErrorSuccess &&
                roleRef && ((CFStringCompare(roleRef, CFSTR("AXScrollArea"), 0) == kCFCompareEqualTo))) {
                ret = YES;
            }
        }
        CFSafeRelease(roleRef);
        CFSafeRelease(windowRef);
        [application release];
    }
    CFSafeRelease(axui);
    return ret;
}

static NSString* commandForGesture(NSString *gesture, int device) {
    NSString *ret = nil;
    CFTypeRef axui = axuiUnderMouse();
    NSString *application = nameOfAxui(axui);

    NSDictionary *commandDict;
    if (device == TRACKPAD) {
        commandDict = [[trackpadMap objectForKey:application] objectForKey:gesture];
        if (!commandDict)
            commandDict = [[trackpadMap objectForKey:@"All Applications"] objectForKey:gesture];
    } else {
        commandDict = [[magicMouseMap objectForKey:application] objectForKey:gesture];
        if (!commandDict)
            commandDict = [[magicMouseMap objectForKey:@"All Applications"] objectForKey:gesture];
    }

    if (commandDict && [[commandDict objectForKey:@"Enable"] boolValue]) {
        ret = [commandDict objectForKey:@"Command"];
    }

    CFSafeRelease((CFStringRef)application);
    CFSafeRelease(axui);

    return ret;
}


// The screenshot crosshair is up exactly while /usr/sbin/screencapture runs (screencaptureui lingers after, so not that).
static int screenshotCrosshairUp(void) {
    pid_t pids[4096];
    int n = proc_listallpids(pids, sizeof pids);
    char name[64];
    for (int i = 0; i < n; i++)
        if (proc_name(pids[i], name, sizeof name) > 0 && strcmp(name, "screencapture") == 0) return 1;
    return 0;
}

static void dispatchCommand(NSString *gesture, int device) {
#ifdef JITOUCH_TEST
    jtTestRecognized = [gesture copy]; // tests/test_fingerdraw.m records the result instead of running the action
    return;
#endif
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        if (device == CHARRECOGNITION && [gesture isEqualToString:@"S"] && screenshotCrosshairUp()) {
            [keyUtil simulateKeyCode:53 ShftDown:NO CtrlDown:NO AltDown:NO CmdDown:NO]; // S again = Escape: cancel the crosshair
            return;
        }
        NSDate *start = [NSDate date];
        doCommand(gesture, device);
        NSTimeInterval timeInterval = -[start timeIntervalSinceNow];
        if (device >= 0 && device < sizeof(deviceTypeName) / sizeof(deviceTypeName[0]) && logLevel >= LOG_LEVEL_INFO) NSLog(@"Gesture \"%@\" for %@ took %f s", gesture, deviceTypeName[device], timeInterval);
    });
}


static void doCommand(NSString *gesture, int device) {
    CFTypeRef axui;
    if (device == CHARRECOGNITION) {
        axui = getForemostApp();
    } else {
        axui = axuiUnderMouse();
    }
    NSString *application = nameOfAxui(axui);

    NSDictionary *commandDict = nil;

    if (device == TRACKPAD) {
        commandDict = [[trackpadMap objectForKey:application] objectForKey:gesture];
        if (!commandDict || ![[commandDict objectForKey:@"Enable"] boolValue])
            commandDict = [[trackpadMap objectForKey:application] objectForKey:@"All Unassigned Gestures"];
        if (!commandDict || ![[commandDict objectForKey:@"Enable"] boolValue])
            commandDict = [[trackpadMap objectForKey:@"All Applications"] objectForKey:gesture];
    } else if (device == MAGICMOUSE) {
        commandDict = [[magicMouseMap objectForKey:application] objectForKey:gesture];
        if (!commandDict || ![[commandDict objectForKey:@"Enable"] boolValue])
            commandDict = [[magicMouseMap objectForKey:application] objectForKey:@"All Unassigned Gestures"];
        if (!commandDict || ![[commandDict objectForKey:@"Enable"] boolValue])
            commandDict = [[magicMouseMap objectForKey:@"All Applications"] objectForKey:gesture];
    } else if (device == CHARRECOGNITION) {
        commandDict = [[recognitionMap objectForKey:application] objectForKey:gesture];
        if (!commandDict || ![[commandDict objectForKey:@"Enable"] boolValue])
            commandDict = [[recognitionMap objectForKey:application] objectForKey:@"All Unassigned Gestures"];
        if (!commandDict || ![[commandDict objectForKey:@"Enable"] boolValue])
            commandDict = [[recognitionMap objectForKey:@"All Applications"] objectForKey:gesture];
    }

    if (commandDict && [[commandDict objectForKey:@"Enable"] boolValue]) {
        CGFloat x, y;
        getMousePosition(&x, &y);
        if ([[commandDict objectForKey:@"IsAction"] boolValue]) {
            //action
            NSString *command = [commandDict objectForKey:@"Command"];
            if (logLevel >= LOG_LEVEL_DEBUG) NSLog(@"Command \"%@\" for application \"%@\"", command, application);

            if ([command isEqualToString:@"-"]) {

            } else if ([command isEqualToString:@"Next Tab"]) {
                [keyUtil simulateKey:@"Tab" ShftDown:NO CtrlDown:YES AltDown:NO CmdDown:NO];
                //[keyUtil simulateKey:@"]" ShftDown:YES CtrlDown:NO AltDown:NO CmdDown:YES];
            } else if ([command isEqualToString:@"Previous Tab"]) {
                [keyUtil simulateKey:@"Tab" ShftDown:YES CtrlDown:YES AltDown:NO CmdDown:NO];
                //[keyUtil simulateKey:@"[" ShftDown:YES CtrlDown:NO AltDown:NO CmdDown:YES];
            } else if ([command isEqualToString:@"Open Link in New Tab"]) {
                CGEventRef ourEvent = CGEventCreate(NULL);
                CGPoint ourLoc = CGEventGetLocation(ourEvent);
                CFRelease(ourEvent);

                CGEventRef ev = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, ourLoc, kCGMouseButtonLeft);
                CGEventSetFlags(ev, kCGEventFlagMaskCommand);
                CGEventPost(kCGSessionEventTap, ev);
                CFRelease(ev);
                ev = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, ourLoc, kCGMouseButtonLeft);
                CGEventSetFlags(ev, kCGEventFlagMaskCommand);
                CGEventPost(kCGSessionEventTap, ev);
                CFRelease(ev);
            } else if ([command isEqualToString:@"Select Tab Above Cursor"]) {
                findTabGroup_lx = -99999;
                selectSafariTab();
            } else if ([command isEqualToString:@"Full Screen"]) {
                CFTypeRef tmpRef = nil;
                if (device != CHARRECOGNITION)
                    tmpRef = activateWindowAtPosition(x, y);
                if ([application isEqualToString:@"Terminal"]) {
                    [keyUtil simulateKey:@"F" ShftDown:NO CtrlDown:NO AltDown:YES CmdDown:YES];
                } else if ([application isEqualToString:@"Finder"]) {
                } else {
                    [keyUtil simulateKey:@"F" ShftDown:NO CtrlDown:YES AltDown:NO CmdDown:YES];
                }
                CFSafeRelease(tmpRef);
            } else if ([command isEqualToString:@"Open Recently Closed Tab"]) {
                if (![application isEqualToString:@"Safari"]) {
                    [keyUtil simulateKey:@"T" ShftDown:YES CtrlDown:NO AltDown:NO CmdDown:YES];
                } else {
                    [keyUtil simulateKey:@"Z" ShftDown:NO CtrlDown:NO AltDown:NO CmdDown:YES];
                }
            } else if ([command isEqualToString:@"Close / Close Tab"]) {
                CFTypeRef tmpRef = nil;
                if (device != CHARRECOGNITION)
                    tmpRef = activateWindowAtPosition(x, y);
                [keyUtil simulateKey:@"W" ShftDown:NO CtrlDown:NO AltDown:NO CmdDown:YES];
                CFSafeRelease(tmpRef);
            } else if ([command isEqualToString:@"Quit"]) {
                //if the user's using VMware/RDC, should we send cmd+q or alt+f4 ?
                if (![application isEqualToString:@"Finder"]) {
                    CFTypeRef tmpRef = nil;
                    if (device != CHARRECOGNITION)
                        tmpRef = activateWindowAtPosition(x, y);
                    [keyUtil simulateKey:@"Q" ShftDown:NO CtrlDown:NO AltDown:NO CmdDown:YES];
                    CFSafeRelease(tmpRef);
                } else {
                    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
                    NSDictionary *errorInfo;
                    NSAppleScript *appleScript = [[NSAppleScript alloc] initWithSource:@"tell application \"Finder\" to close every window"];
                    [appleScript executeAndReturnError:&errorInfo];
                    [appleScript release];
                    [pool release];
                }
            } else if ([command isEqualToString:@"Hide"]) {
                CFTypeRef tmpRef = nil;
                if (device != CHARRECOGNITION)
                    tmpRef = activateWindowAtPosition(x, y);
                [keyUtil simulateKey:@"H" ShftDown:NO CtrlDown:NO AltDown:NO CmdDown:YES];
                CFSafeRelease(tmpRef);
            } else if ([command isEqualToString:@"Minimize"]) {
                CFTypeRef tmpRef = nil;
                if (device != CHARRECOGNITION)
                    tmpRef = activateWindowAtPosition(x, y);
                minimizeForemostWindow();
                CFSafeRelease(tmpRef);
            } else if ([command isEqualToString:@"Zoom"]) {
                CFTypeRef tmpRef = nil;
                if (device != CHARRECOGNITION)
                    tmpRef = activateWindowAtPosition(x, y);
                maximizeForemostWindow();
                CFSafeRelease(tmpRef);
            } else if ([command isEqualToString:@"Un-Maximize"]) {
                CFTypeRef tmpRef = getForemostApp();
                maximizeWindow(tmpRef, 0);
                CFSafeRelease(tmpRef);
            } else if ([command isEqualToString:@"Maximize"]) {
                CFTypeRef tmpRef = getForemostApp();
                maximizeWindow(tmpRef, 1);
                CFSafeRelease(tmpRef);
            } else if ([command isEqualToString:@"Maximize Left"]) {
                CFTypeRef tmpRef = getForemostApp();
                maximizeWindow(tmpRef, 2);
                CFSafeRelease(tmpRef);
            } else if ([command isEqualToString:@"Maximize Right"]) {
                CFTypeRef tmpRef = getForemostApp();
                maximizeWindow(tmpRef, 3);
                CFSafeRelease(tmpRef);
            } else if ([command isEqualToString:@"Copy"]) {
                [keyUtil simulateKey:@"C" ShftDown:NO CtrlDown:NO AltDown:NO CmdDown:YES];
            } else if ([command isEqualToString:@"Paste"]) {
                [keyUtil simulateKey:@"V" ShftDown:NO CtrlDown:NO AltDown:NO CmdDown:YES];
            } else if ([command isEqualToString:@"New"]) {
                [keyUtil simulateKey:@"N" ShftDown:NO CtrlDown:NO AltDown:NO CmdDown:YES];
            } else if ([command isEqualToString:@"New Tab"]) {
                [keyUtil simulateKey:@"T" ShftDown:NO CtrlDown:NO AltDown:NO CmdDown:YES];
            } else if ([command isEqualToString:@"Open"]) {
                [keyUtil simulateKey:@"O" ShftDown:NO CtrlDown:NO AltDown:NO CmdDown:YES];
            } else if ([command isEqualToString:@"Save"]) {
                [keyUtil simulateKey:@"S" ShftDown:NO CtrlDown:NO AltDown:NO CmdDown:YES];
            } else if ([command isEqualToString:@"Launch Finder"]) {
                NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
                [[NSWorkspace sharedWorkspace] launchApplication:@"Finder"];
                [pool release];
            } else if ([command isEqualToString:@"Launch Browser"]) {
                NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
                CFStringRef tmp = LSCopyDefaultHandlerForURLScheme(CFSTR("http"));
                if (tmp) {
                    NSString *defaultBrowser = (NSString*)tmp;
                    if (![[NSWorkspace sharedWorkspace] launchAppWithBundleIdentifier:defaultBrowser
                                                                              options:NSWorkspaceLaunchDefault
                                                       additionalEventParamDescriptor:nil
                                                                     launchIdentifier:NULL]) {
                        [[NSWorkspace sharedWorkspace] launchApplication:@"Safari"];
                    }
                    CFRelease(tmp);
                } else {
                    [[NSWorkspace sharedWorkspace] launchApplication:@"Safari"];
                }
                [pool release];
            } else if ([command isEqualToString:@"Middle Click"]) {
                CGEventRef eventRef;

                CGEventRef ourEvent = CGEventCreate(NULL);
                CGPoint location = CGEventGetLocation(ourEvent);
                CFRelease(ourEvent);

                eventRef = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseDown, location, kCGMouseButtonCenter);
                CGEventSetIntegerValueField(eventRef, kCGMouseEventButtonNumber, 2);
                CGEventPost(kCGSessionEventTap, eventRef);
                CFRelease(eventRef);

                eventRef = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseUp, location, kCGMouseButtonCenter);
                //CGEventSetIntegerValueField(eventRef, kCGMouseEventButtonNumber, 2);
                CGEventPost(kCGSessionEventTap, eventRef);
                CFRelease(eventRef);
            } else if ([command isEqualToString:@"Show Desktop"]) {
                CoreDockSendNotification(@"com.apple.showdesktop.awake");
            } /*else if ([command isEqualToString:@"Spaces"]) {
                CoreDockSendNotification(@"com.apple.workspaces.awake");
            } */
            else if ([command isEqualToString:@"Application Windows"]) {
                CoreDockSendNotification(@"com.apple.expose.front.awake");
            } else if ([command isEqualToString:@"Mission Control"]) {
                CoreDockSendNotification(@"com.apple.expose.awake");
            } else if ([command isEqualToString:@"Launchpad"]) {
                CoreDockSendNotification(@"com.apple.launchpad.toggle");
            } else if ([command isEqualToString:@"Dashboard"]) {
                NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
                [[NSWorkspace sharedWorkspace] launchApplication:@"Dashboard"];
                [pool release];
            } else if ([command isEqualToString:@"Left Click"]) {
                CGEventRef eventRef;

                CGEventRef ourEvent = CGEventCreate(NULL);
                CGPoint location = CGEventGetLocation(ourEvent);
                CFRelease(ourEvent);

                eventRef = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, location, kCGMouseButtonLeft);
                CGEventSetIntegerValueField(eventRef, kCGMouseEventButtonNumber, 0);
                CGEventPost(kCGSessionEventTap, eventRef);
                CFRelease(eventRef);

                eventRef = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, location, kCGMouseButtonLeft);
                CGEventPost(kCGSessionEventTap, eventRef);
                CFRelease(eventRef);
            } else if ([command isEqualToString:@"Right Click"]) {
                CGEventRef eventRef;

                CGEventRef ourEvent = CGEventCreate(NULL);
                CGPoint location = CGEventGetLocation(ourEvent);
                CFRelease(ourEvent);

                eventRef = CGEventCreateMouseEvent(NULL, kCGEventRightMouseDown, location, kCGMouseButtonRight);
                CGEventSetIntegerValueField(eventRef, kCGMouseEventButtonNumber, 1);
                CGEventPost(kCGSessionEventTap, eventRef);
                CFRelease(eventRef);

                eventRef = CGEventCreateMouseEvent(NULL, kCGEventRightMouseUp, location, kCGMouseButtonRight);
                CGEventPost(kCGSessionEventTap, eventRef);
                CFRelease(eventRef);
            } else if ([command isEqualToString:@"Refresh"]) {
                CFTypeRef tmpRef = nil;
                if (device != CHARRECOGNITION)
                    tmpRef = activateWindowAtPosition(x, y);
                if ([application isEqualToString:@"Mail"]) {
                    [keyUtil simulateKey:@"N" ShftDown:YES CtrlDown:NO AltDown:NO CmdDown:YES];
                } else if ([application isEqualToString:@"Preview"] || [application isEqualToString:@"iChat"]) {
                } else {
                    [keyUtil simulateKey:@"R" ShftDown:NO CtrlDown:NO AltDown:NO CmdDown:YES];
                }
                CFSafeRelease(tmpRef);
            } else if ([command isEqualToString:@"Scroll to Top"]) {
                CFTypeRef tmpRef = nil;
                if (device != CHARRECOGNITION)
                    tmpRef = activateWindowAtPosition(x, y);
                if ([application isEqualToString:@"Microsoft Word"])
                    [keyUtil simulateKey:@"Home" ShftDown:NO CtrlDown:NO AltDown:NO CmdDown:YES];
                else
                    [keyUtil simulateKey:@"Home" ShftDown:NO CtrlDown:NO AltDown:NO CmdDown:NO];
                CFSafeRelease(tmpRef);
            } else if ([command isEqualToString:@"Scroll to Bottom"]) {
                CFTypeRef tmpRef = nil;
                if (device != CHARRECOGNITION)
                    tmpRef = activateWindowAtPosition(x, y);
                if ([application isEqualToString:@"Microsoft Word"])
                    [keyUtil simulateKey:@"End" ShftDown:NO CtrlDown:NO AltDown:NO CmdDown:YES];
                else
                    [keyUtil simulateKey:@"End" ShftDown:NO CtrlDown:NO AltDown:NO CmdDown:NO];
                CFSafeRelease(tmpRef);
            } else if ([command isEqualToString:@"Application Switcher"]) {
                CoreDockSendNotification(@"com.apple.appswitcher.awake");
            } else if ([command isEqualToString:@"Play / Pause"]) {
                [keyUtil simulateSpecialKey:NX_KEYTYPE_PLAY];
            } else if ([command isEqualToString:@"Next"]) {
                [keyUtil simulateSpecialKey:NX_KEYTYPE_NEXT];
            } else if ([command isEqualToString:@"Previous"]) {
                [keyUtil simulateSpecialKey:NX_KEYTYPE_PREVIOUS];
            } else if ([command isEqualToString:@"Volume Up"]) {
                [keyUtil simulateSpecialKey:NX_KEYTYPE_SOUND_UP];
            } else if ([command isEqualToString:@"Volume Down"]) {
                [keyUtil simulateSpecialKey:NX_KEYTYPE_SOUND_DOWN];
            } else if ([command isEqualToString:@"Brightness Up"]) {
                [keyUtil simulateSpecialKey:NX_KEYTYPE_BRIGHTNESS_UP];
            } else if ([command isEqualToString:@"Brightness Down"]) {
                [keyUtil simulateSpecialKey:NX_KEYTYPE_BRIGHTNESS_DOWN];
            } else {
                if ([commandDict objectForKey:@"OpenFilePath"]) {
                    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
                    NSString *openFilePath = [commandDict objectForKey:@"OpenFilePath"];
                    if ([[NSFileManager defaultManager] fileExistsAtPath:openFilePath]) {
                        NSString *extension = [openFilePath pathExtension];
                        if ([extension isEqualToString:@"scpt"] || [extension isEqualToString:@"scptd"]) {
                            NSString *script = [NSString stringWithFormat:@"osascript \"%@\"", [openFilePath stringByStandardizingPath]];
                            NSArray *shArgs = [NSArray arrayWithObjects:@"-c", script, @"", nil];
                            [NSTask launchedTaskWithLaunchPath:@"/bin/sh" arguments:shArgs];
                        } else {
                               [[NSWorkspace sharedWorkspace] openFile:openFilePath];
                           }
                    } else {
                        NSAlert *alert = [[NSAlert alloc] init];
                        [alert setMessageText:[NSString stringWithFormat:@"Can't open the file \"%@\"", openFilePath]];
                        //[alert setInformativeText:@""];
                        [alert setAlertStyle:NSWarningAlertStyle];
                        [NSApp activateIgnoringOtherApps:YES];
                        //[alert runModal];
                        [alert beginSheetModalForWindow:[(JitouchAppDelegate*)[NSApp delegate] window] completionHandler:nil]; //use non-modal
                        [alert release];
                    }
                    [pool release];
                } else if ([commandDict objectForKey:@"OpenURL"]) {
                    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
                    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[commandDict objectForKey:@"OpenURL"]]];
                    [pool release];
                }
            }
        } else {
            // shortcut
            CFTypeRef tmpRef = nil;
            if (device != CHARRECOGNITION)
                tmpRef = activateWindowAtPosition(x, y);

            NSUInteger modifierFlags = [[commandDict objectForKey:@"ModifierFlags"] unsignedIntegerValue];
            if (logLevel >= LOG_LEVEL_DEBUG) NSLog(@"Key \"%@%@%@%@%@\" for application \"%@\"",
                                                   (modifierFlags & kCGEventFlagMaskShift)? @"⇧" : @"",
                                                   (modifierFlags & kCGEventFlagMaskControl)? @"⌃" : @"",
                                                   (modifierFlags & kCGEventFlagMaskAlternate)? @"⌥ " : @"",
                                                   (modifierFlags & kCGEventFlagMaskCommand)? @"⌘ " : @"",
                                                   [KeyUtility codeToChar:(CGKeyCode)[[commandDict objectForKey:@"KeyCode"] unsignedIntValue]],
                                                   application);
            [keyUtil simulateKeyCode:[[commandDict objectForKey:@"KeyCode"] unsignedShortValue]
                            ShftDown:(modifierFlags & kCGEventFlagMaskShift) != 0
                            CtrlDown:(modifierFlags & kCGEventFlagMaskControl) != 0
                             AltDown:(modifierFlags & kCGEventFlagMaskAlternate) != 0
                             CmdDown:(modifierFlags & kCGEventFlagMaskCommand) != 0];
            CFSafeRelease(tmpRef);

        }
    }

    CFSafeRelease((CFStringRef)application);
    CFSafeRelease(axui);
}

static void setCursorWindowAtMouse() {
    CGEventRef ourEvent = CGEventCreate(NULL);
    CGPoint location = CGEventGetUnflippedLocation(ourEvent);
    CFRelease(ourEvent);
    dispatch_async(dispatch_get_main_queue(), ^{ // called from touch threads; AppKit only on the main thread
        [cursorWindow setFrameOrigin:NSMakePoint(location.x - 31, location.y - 29)];
    });
}


#pragma mark - Trackpad

static void gestureTrackpadChangeSpace(const Finger *data, int nFingers) {
    static int step = 0;
    static float fing[3][2];
    // Min id
    static int mini;
    static int move = 0;
    static float last[2];
    if (step == 0 && nFingers == 2) {
        if (lenSqrF(data, 0, 1) < 0.1) {
            step = 1;
        }
    } else if (step == 1) {
        if (nFingers == 2 && lenSqrF(data, 0, 1) >= 0.1) {
            step = 0;
        } else if (nFingers == 3) {
            mini = 0;
            for (int i = 0; i < 3; i++) {
                fing[i][0] = data[i].px;
                fing[i][1] = data[i].py;
                if (fing[i][0] + fing[i][1] < fing[mini][0] + fing[mini][1]) {
                    mini = i;
                }
            }
            step = 2;
            move = 0;
        }
    } else if (step == 2) {
        if (nFingers != 3) {
            step = 0;
        } else {
            for (int i = 0; i < 3; i++) {
                if (i != mini && lenSqr(data[i].px, data[i].py, fing[i][0], fing[i][1]) > 0.001) {
                    step = 0;
                }
            }
            if (!move) {
                if (lenSqr(data[mini].px, data[mini].py, fing[mini][0], fing[mini][1]) > 0.001) {
                    move = 1;
                    last[0] = fing[mini][0];
                    last[1] = fing[mini][1];
                }
            } else {

                if (
                    (
                     lenSqr(data[mini].px, data[mini].py, last[0], last[1]) < 0.000001 ||
                     data[mini].state == MTTouchStateBreakTouch
                    ) &&
                    (
                     fabs(data[mini].px - fing[mini][0]) >= 0.07 * charRegIndexRingDistance / 0.33 ||
                     fabs(data[mini].py - fing[mini][1]) >= 0.08 * charRegIndexRingDistance / 0.33
                    )
                ) {
                    float dx = fabs(fing[mini][0] - data[mini].px), dy = fabs(fing[mini][1] - data[mini].py);
                    if (dx > dy) {
                        if (fing[mini][0] < data[mini].px)
                            dispatchCommand(@"Two-Fix One-Slide-Right", TRACKPAD);
                        else
                            dispatchCommand(@"Two-Fix One-Slide-Left", TRACKPAD);
                    } else {
                        if (fing[mini][1] < data[mini].py)
                            dispatchCommand(@"Two-Fix One-Slide-Up", TRACKPAD);
                        else
                            dispatchCommand(@"Two-Fix One-Slide-Down", TRACKPAD);
                    }
                    move = 0;
                    fing[mini][0] = data[mini].px;
                    fing[mini][1] = data[mini].py;
                }
                last[0] = data[mini].px;
                last[1] = data[mini].py;
            }

        }
    }
}


static void gestureTrackpadTab4(const Finger *data, int nFingers, double timestamp, int dir) {
    static double sttime[2] = {-1, -1};
    static int lastNFingers[2] = {0};
    static float avgX[2], avgY[2];
    float avgX2, avgY2;
    static int step[2];
    if (fourFingerTapTriggered)
        step[dir] = 0;
    if (step[dir] == 0) {
        if (nFingers == 1) {
            sttime[dir] = timestamp;
            step[dir] = 1;
            avgX[dir] = data[0].px;
            avgY[dir] = data[0].py;
            lastNFingers[dir] = 1;
        }
    } else if (step[dir] == 4) {
        if (timestamp - sttime[dir] > clickSpeed)
            step[dir] = 0;
        if (nFingers == 4) {
            avgX2 = avgY2 = 0;
            for (int i = 0; i < nFingers; i++) {
                avgX2 += data[i].px;
                avgY2 += data[i].py;
            }
            avgX2 /= nFingers;
            avgY2 /= nFingers;
            if (fabs(avgX2+avgY2 - avgX[dir] - avgY[dir]) > 0.1)
                step[dir] = 0;
        } else if (nFingers > 4)
            step[dir] = 0;
        else if (nFingers == 0) {
            trackpadTab4Triggered = TRUE;
            if (dir == 1) {
                dispatchCommand(@"Pinky-To-Index", TRACKPAD);
            } else{
                dispatchCommand(@"Index-To-Pinky", TRACKPAD);
            }
            step[dir] = 0;
        }

    } else if (step[dir] >= 1) {
        if (timestamp - sttime[dir] > clickSpeed) // decreased
            step[dir] = 0;
        if (nFingers == lastNFingers[dir] + 1) {
            avgX2 = avgY2 = 0;
            for (int i = 0; i < nFingers; i++) {
                avgX2 += data[i].px;
                avgY2 += data[i].py;
            }
            avgX2 /= nFingers;
            avgY2 /= nFingers;
            if (dir ^ (avgX2 + avgY2 > avgX[dir] + avgY[dir])) {
                step[dir]++;
                avgX[dir] = avgX2;
                avgY[dir] = avgY2;
                sttime[dir] = timestamp;
            }
        } else if (nFingers < lastNFingers[dir])
            step[dir] = 0;
        lastNFingers[dir] = nFingers;
    }
    trackpadTab4Step[dir] = step[dir];
}


static void gestureTrackpadFourFingerTap(const Finger *data, int nFingers, double timestamp) {
    static double sttime = -1;
    static int step = 0;
    static double fing[4][2];
    static double fourFingerTapTime;
    fourFingerTapTriggered = FALSE;
    if (nFingers > 4)
        step = 2;
    else if (trackpadTab4Triggered) {
        step = 0;
        sttime = -1;
    }
    else if (step == 0 && nFingers == 4) {
        if (sttime == -1) {
            sttime = timestamp;
            step = 1;
            trackpadClicked = 0;
            for (int i = 0; i < 4; i++) {
                fing[i][0] = data[i].px;
                fing[i][1] = data[i].py;
            }
        }
    } else if (step == 1) {
        if (nFingers <= 1) {
            if (sttime != -1 && timestamp-sttime <= clickSpeed) {
                if (trackpadTab4Step[0] == 4 || trackpadTab4Step[1] == 4) {
                    // dispatch only if TrackpadTab4 is not triggered from the same gesture
                    fourFingerTapTime = timestamp;
                    step = 3;
                }
                else if (!trackpadClicked) {
                    dispatchCommand(@"Four-Finger Tap", TRACKPAD);
                    step = 0;
                    sttime = -1;
                }
            } else {
                step = 0;
                sttime = -1;
            }
        } else if (nFingers == 4) {
            if (lenSqr(fing[0][0], fing[0][1], data[0].px, data[0].py) > 0.001 ||
               lenSqr(fing[1][0], fing[1][1], data[1].px, data[1].py) > 0.001 ||
               lenSqr(fing[2][0], fing[2][1], data[2].px, data[2].py) > 0.001 ||
               lenSqr(fing[3][0], fing[3][1], data[3].px, data[3].py) > 0.001 ) {
                step = 2;
            }
        }
    } else if (step == 2 && nFingers <= 1) {
        step = 0;
        sttime  = -1;
    } else if (step == 3) {
        if ((trackpadTab4Step[0] != 4 && trackpadTab4Step[1] != 4) ||
            timestamp-fourFingerTapTime > clickSpeed/2) {
            if (!trackpadClicked)
                dispatchCommand(@"Four-Finger Tap", TRACKPAD);
            fourFingerTapTriggered = TRUE;
            step = 0;
            sttime = -1;
        }
    }
}


// TODO: clicking (not just tapping) should return to the normal mode
static int gestureTrackpadMoveResize(const Finger *data, int nFingers, double timestamp) {
    static int step = 0, step2, min;
    static float fing[2][2], fing2[2][2];
    static double sttime = -1;
    static int type = 0;
    static CFTypeRef cWindow = nil;
    static CGFloat baseX, baseY, appX, appY;
    static char firstTime;

    if (type) {
        if (step2 == 0) {
            if (firstTime) {
                getMousePosition(&baseX, &baseY);
                dispatch_async(dispatch_get_main_queue(), ^{
                    @autoreleasepool {
                        dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow orderOut:nil]; }); // AppKit only on the main thread
                    }
                });
                if (cWindow == nil)
                    cWindow = activateWindowAtPosition(baseX, baseY);

                if (cWindow == NULL) {
                    type = 0;
                } else {
                    getWindowPos(cWindow, &appX, &appY);

                    cursorImageType = type - 1;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @autoreleasepool {
                            dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow display]; }); // AppKit only on the main thread
                            dispatch_async(dispatch_get_main_queue(), ^{ [[cursorWindow contentView] setNeedsDisplay:YES]; }); // AppKit only on the main thread
                            setCursorWindowAtMouse();
                            dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow setLevel:NSScreenSaverWindowLevel]; }); // AppKit only on the main thread
                            dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow makeKeyAndOrderFront:nil]; }); // AppKit only on the main thread
                        }
                    });

                    moveResizeFlag = 1;
                }
            }
            firstTime = 0;
            if (nFingers == 1) {
                sttime = -1;
                step2 = 1;
            }
        } else if (step2 == 1) {
            if (nFingers == 1 && !shouldExitMoveResize) {
                CGFloat x, y;
                getMousePosition(&x, &y);
                dispatch_async(dispatch_get_main_queue(), ^{
                    @autoreleasepool {
                        setCursorWindowAtMouse();
                    }
                });
                if (type == 1) {
                    setWindowPos2(cWindow, x, y, baseX, baseY, appX, appY);
                } else if (type == 2) {
                    if (!setWindowSize2(cWindow, x, y, baseX, baseY)) {
                        type = 0;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            @autoreleasepool {
                                dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow orderOut:nil]; }); // AppKit only on the main thread
                            }
                        });
                        CFSafeRelease(cWindow);
                        cWindow = nil;

                        moveResizeFlag = 0;
                        //CGEventTapEnable(eventClick, false);
                    } else {
                        float nx = x, ny = y;
                        if (x >= appX + 3)
                            baseX = x;
                        else
                            nx = appX + 3;
                        if (y >= appY + 3)
                            baseY = y;
                        else
                            ny = appY + 3;
                        if (nx != x || ny != y) {
                            mouseClick(8, nx, ny);
                        }
                    }
                }
                if (sttime == -1) {
                    sttime = timestamp;
                    fing[0][0] = data[0].px;
                    fing[0][1] = data[0].py;
                }
                if (fing[0][0] != -1 && lenSqr(fing[0][0], fing[0][1], data[0].px, data[0].py) >= 0.001)
                    sttime = 0;

            } else if (nFingers == 2 && data[0].size >= 0.1 && data[1].size >= 0.1) {
                sttime = timestamp;
                step2 = 2;
                fing2[0][0] = data[0].px;
                fing2[0][1] = data[0].py;
                fing2[1][0] = data[1].px;
                fing2[1][1] = data[1].py;

            } else if ((nFingers == 0 && timestamp-sttime <= clickSpeed) || shouldExitMoveResize) { // tap or click to exit
                type = 0;
                CFSafeRelease(cWindow);
                cWindow = nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    @autoreleasepool {
                        dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow orderOut:nil]; }); // AppKit only on the main thread
                    }
                });

                moveResizeFlag = 0;
                //CGEventTapEnable(eventClick, false);

                shouldExitMoveResize = 0;
            } else if (nFingers == 0)
                sttime = -1;
        } else if (step2 == 2) {
            if (nFingers >= 3 ||
               timestamp - sttime > clickSpeed ||
               lenSqr(fing2[0][0], fing2[0][1], data[0].px, data[0].py) > 0.001 ||
               lenSqr(fing2[1][0], fing2[1][1], data[1].px, data[1].py) > 0.001
               ) {
                step2 = 3;
            }
            if (nFingers == 1) {
                firstTime = 1;
                step2 = 0;
                type = (type == 1) ? 2 : 1;
            }
        } else if (step2 == 3 && nFingers == 1) {
            step2 = 0;
        }
    }
    if (step == 0 && nFingers == 1) {
        step = 1;
    } else if (step == 1) {
        if (nFingers == 2) {
            if (lenSqr(data[0].px, data[0].py, data[1].px, data[1].py) > 0.2)
                step = 0;
            else {
                min = 0;
                if (data[1].px+data[1].py<data[min].px+data[min].py)
                    min = 1;
                fing[0][0] = data[min].px;
                fing[0][1] = data[min].py;
                fing[1][0] = data[!min].px;
                fing[1][1] = data[!min].py;
                step = 2;
                sttime = timestamp;
            }
        } else if (nFingers == 3)
            step = 0;
    } else if (step == 2) {
        if (nFingers != 2 || timestamp- sttime > clickSpeed * 2)
            step = 0;
        else {
            if (lenSqr(fing[0][0], fing[0][1], data[min].px, data[min].py) > 0.0001
               || CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft)) {
                step = 0;
            }

            if (data[!min].px > data[min].px && lenSqr(data[!min].px, data[!min].py, fing[1][0], fing[1][1]) >= 0.012) {

                // Intensive calculation - please keep to minimum :p
                float v[3][2], tmp;

                v[1][0] = data[!min].px - fing[1][0];
                v[1][1] = data[!min].py - fing[1][1];
                tmp = sqrt(v[1][0]*v[1][0] + v[1][1]*v[1][1]);
                if (tmp == 0) tmp = 1e-10;
                v[1][0] /= tmp;
                v[1][1] /= tmp;

                v[2][0] = data[!min].px - fing[0][0];
                v[2][1] = data[!min].py - fing[0][1];
                tmp = sqrt(v[2][0]*v[2][0] + v[2][1]*v[2][1]);
                if (tmp == 0) tmp = 1e-10;
                v[2][0] /= tmp;
                v[2][1] /= tmp;

                // Dot product
                if (fabs(v[2][0]*v[1][0] + v[2][1]*v[1][1]) <= 0.8) {
                    sttime = timestamp;
                    step2 = step = 0;
                    firstTime = 1;

                    if (type) {
                        type = 0;
                        CFSafeRelease(cWindow);
                        cWindow = nil;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            @autoreleasepool {
                                dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow orderOut:nil]; }); // AppKit only on the main thread
                            }
                        });

                        moveResizeFlag = 0;
                    } else if (data[!min].py < fing[1][1]) {
                        if ([commandForGesture(@"One-Fix One-Slide", TRACKPAD) isEqualToString:@"Move / Resize"] && !isMouseOnEmptySpace())
                            type = 1;
                    } else {
                        if ([commandForGesture(@"One-Fix One-Slide", TRACKPAD) isEqualToString:@"Move / Resize"] && !isMouseOnEmptySpace())
                            type = 2;
                    }
                } else
                    step = 0;
            }
        }
    }

    return type || step >= 3;
}


static void gestureTrackpadOneFixTwoSlide(const Finger *data, int nFingers, double timestamp) {
    static int ena = 0, min;
    static int find[3], findc;
    static float avgy, avgx;
    static double waitFor4;
    static int reset = 0;
    static int lastNFingers;
    static CGFloat fixX, fixY;
    static float fing[3][2];
    if (!reset && (nFingers >= 3 && nFingers <= 4)) {
        if (lastNFingers != nFingers)
            ena = 0;
        if (!ena) {
            min = 0;
            for (int i = 0; i < nFingers; i++) {
                if (data[i].px+data[i].py<data[min].px+data[min].py)
                    min = i;
            }
            fixX = data[min].px;
            fixY = data[min].py;
            findc = 0;
            avgy = 0;
            avgx = 0;
            for (int i = 0; i < nFingers; i++)
                if (min != i) {
                    fing[findc][0] = data[i].px;
                    fing[findc][1] = data[i].py;
                    find[findc++] = i;
                    avgx += data[i].px;
                    avgy += data[i].py;
                }
            avgx /= findc;
            avgy /= findc;
            if (nFingers == 3) {
                if (fabs(fixX - avgx) >= 0.35)
                    waitFor4 = timestamp;
                else
                    waitFor4 = -1;
            } else if (nFingers == 4) {
                if (fabs(fixX - avgx) >= 0.45)
                    reset = 1;
                else
                    waitFor4 = -1;
            }
            ena = 1;
        } else {
            if (waitFor4 != -1 && timestamp - waitFor4 > clickSpeed)
                reset = 1;
            double avgx2 = 0, avgy2 = 0;
            for (int i = 0; i < findc; i++) {
                avgx2 += data[find[i]].px;
                avgy2 += data[find[i]].py;
            }
            avgx2 /= findc;
            avgy2 /= findc;

            if (lenSqr(fixX, fixY, data[min].px, data[min].py) > 0.001) {
                reset = 1;
            } else {
                // Reuse variables
                if (nFingers == 3 && waitFor4 == -1 &&
                   lenSqr(avgx, avgy, avgx2, avgy2) >= 0.018 &&
                   lenSqr(data[find[0]].px, data[find[0]].py, fing[0][0], fing[0][1]) >= 0.01 &&
                   lenSqr(data[find[1]].px, data[find[1]].py, fing[1][0], fing[1][1]) >= 0.01) {
                    getMousePosition(&fixX, &fixY);
                    CFTypeRef tmpRef = activateWindowAtPosition(fixX, fixY);
                    CFSafeRelease(tmpRef);

                    if (CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft)) {
                        if (avgy2 > avgy) { //one fix two slide up
                            dispatchCommand(@"One-Fix-Press Two-Slide-Up", TRACKPAD);
                        } else { //one fix two slide down
                            dispatchCommand(@"One-Fix-Press Two-Slide-Down", TRACKPAD);
                        }

                        CGEventRef eventRef;

                        CGEventRef ourEvent = CGEventCreate(NULL);
                        CGPoint location = CGEventGetLocation(ourEvent);
                        CFRelease(ourEvent);

                        eventRef = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, location, kCGMouseButtonLeft);
                        CGEventSetIntegerValueField(eventRef, kCGMouseEventButtonNumber, 0);
                        CGEventPost(kCGSessionEventTap, eventRef);
                        CFRelease(eventRef);
                    } else {
                        if (avgy2 > avgy) { //one fix two slide up
                            dispatchCommand(@"One-Fix Two-Slide-Up", TRACKPAD);
                        } else { //one fix two slide down
                            dispatchCommand(@"One-Fix Two-Slide-Down", TRACKPAD);
                        }
                    }

                    reset = 1;
                }

                //No longer works in Snow Leopard
                /*
                if (nFingers == 4 && //one fix three slide
                   lenSqr(avgx, avgy, avgx2, avgy2) >= 0.013) {
                    dispatchCommand(@"One-Fix Three-Slide", TRACKPAD);
                    reset = 1;
                }
                 */
            }
        }
        lastNFingers = nFingers;
    } else if (nFingers <= 1 || nFingers > 4) {
        ena = 0;
        reset = 0;
        lastNFingers = nFingers;
    }
}

static void gestureTrackpadThreeFingerTap(const Finger *data, int nFingers, double timestamp) {
    static double sttime = -1;
    static int step = 0;
    static double fing[3][2];
    static int idf[3];
    if (nFingers > 3)
        step = 2;
    else if (step == 0 && nFingers == 3) {
        if (sttime == -1) {
            sttime = timestamp;
            step = 1;
            trackpadClicked = 0;
            for (int i = 0; i < 3; i++) {
                fing[i][0] = data[i].px;
                fing[i][1] = data[i].py;
            }
            idf[0] = 0;
            idf[2] = 2;
            for (int i = 0; i < 3; i++) {
                if (data[i].px + data[i].py < data[idf[0]].px + data[idf[0]].py)
                    idf[0] = i;
                if (data[i].px + data[i].py > data[idf[2]].px + data[idf[2]].py)
                    idf[2] = i;
            }
            idf[1] = 3 - idf[0] - idf[2];
            for (int i = 0; i < 3; i++)
                idf[i] = data[idf[i]].identifier;
        }
    } else if (step == 1) {
        if (nFingers <= 1) {
            if (sttime != -1 && timestamp-sttime <= clickSpeed) {
                if (!trackpadClicked)
                    dispatchCommand(@"Three-Finger Tap", TRACKPAD);
            }
            step = 0;
            sttime = -1;
        } else if (nFingers == 3) {
            if (lenSqr(fing[0][0], fing[0][1], data[0].px, data[0].py) > 0.001 ||
               lenSqr(fing[1][0], fing[1][1], data[1].px, data[1].py) > 0.001 ||
               lenSqr(fing[2][0], fing[2][1], data[2].px, data[2].py) > 0.001) {
                step = 2;
            }
        }
    } else if (step == 2 && nFingers <= 1) {
        step = 0;
        sttime  = -1;
    }
}


static void gestureTrackpadOneFixOneTap(const Finger *data, int nFingers, double timestamp) {
    static double sttime = -1;
    static float fing[2][2];
    static int step = 0;
    static double restTime = -1;
    static int fixId;
    static float avgx, avgy;

    if (nFingers == 0) {
        restTime = -1;
    }

    if (step == 0 && nFingers == 1) {
        step = 1;
        fixId = data[0].identifier;
        sttime = -1;
        if (restTime < 0)
            restTime = timestamp;
    } else if (step == 1) {
        if (nFingers == 2) {
            if (timestamp - restTime >= 0.06 && (!enCharRegTP || fabs(data[0].px - data[1].px) <= charRegIndexRingDistance) &&
                lenSqr(data[0].px, data[0].py, data[1].px, data[1].py) < 0.15) {
                if (sttime < 0)
                    sttime = timestamp;
                if ((data[0].identifier == fixId || data[0].size > stvt / 10) &&
                   (data[1].identifier == fixId || data[1].size > stvt / 10)) {
                    step = 2;
                    avgx = (data[0].px + data[1].px) / 2;
                    avgy = (data[0].py + data[1].py) / 2;
                    fing[0][0] = data[0].px;
                    fing[0][1] = data[0].py;
                    fing[1][0] = data[1].px;
                    fing[1][1] = data[1].py;
                }
            } else
                step = 0;
        } else if (nFingers == 1) {
            sttime = -1;
            fixId = data[0].identifier;
        } else
            step = 0;
    } else if (step == 2) {
        if (nFingers == 1) {
            if (timestamp - sttime > clickSpeed) {
                step = 0;
            } else {
                if (data[0].identifier == fixId) {
                    if (enHanded ^ (avgy - data[0].py < data[0].px - avgx))
                        dispatchCommand(@"One-Fix Left-Tap", TRACKPAD);
                    else
                        dispatchCommand(@"One-Fix Right-Tap", TRACKPAD);
                }
            }
            step = 0;
        } else if (nFingers == 2) {
            if (lenSqr(data[0].px, data[0].py, fing[0][0], fing[0][1]) > 0.001 || lenSqr(data[1].px, data[1].py, fing[1][0], fing[1][1]) > 0.001)
                step = 0;
        } else {
            step = 0;
        }
    }
}


static void gestureTrackpadSwipeThreeFingers(const Finger *data, int nFingers) {
    static float startx[3], starty[3];
    static int lastNFingers;
    int step = 0;
    static int type = 0;
    static int l, r;

    if (lastNFingers != 3 && nFingers == 3) {
        step = 1;
    } else if (lastNFingers == 3 && nFingers == 3) {
        step = 2;
    } else if (lastNFingers == 3 && nFingers != 3) {
        step = 3;
    }

    if (step == 1) { //start three fingers
        l = 0; r = 0;
        for (int i = 0; i < nFingers; i++) {
            startx[i] = data[i].px;
            starty[i] = data[i].py;
            if (data[i].px+data[i].py < data[l].px+data[l].py) {
                l = i;
            } else if (data[i].px+data[i].py > data[r].px+data[r].py) {
                r = i;
            }
        }
        type = 0;
    } else if (step == 2) { //continue three fingers
        float sumx = 0.0f;
        float sumy = 0.0f;
        int moveDown = 0;
        int moveUp = 0;
        int moveLeft = 0;
        int moveRight = 0;
        for (int i = 0; i < nFingers; i++) {
            sumx += data[i].px - startx[i];
            sumy += data[i].py - starty[i];
            if (data[i].py - starty[i] < -0.08) moveDown++;
            else if (data[i].py - starty[i] > 0.08) moveUp++;
            if (data[i].px - startx[i] < -0.06) moveLeft++;
            else if (data[i].px - startx[i] > 0.06) moveRight++;
        }


        if (moveDown == 3 && type != 1) {
            if (sumy < -0.35) {
                type = 1;
                dispatchCommand(@"Three-Swipe-Down", TRACKPAD);
                for (int i = 0; i < nFingers; i++) {
                    startx[i] = data[i].px;
                    starty[i] = data[i].py;
                }
            }
        } else if (moveUp == 3 && type != 2) {
            if (sumy > 0.35) {
                type = 2;
                dispatchCommand(@"Three-Swipe-Up", TRACKPAD);
                for (int i = 0; i < nFingers; i++) {
                    startx[i] = data[i].px;
                    starty[i] = data[i].py;
                }
            }
        } else if (moveLeft == 3 && type != 3) {
            if (sumx < -0.30) {
                type = 3;
                // TODO: should check if the ACTIVE app is Safari or Firefox and,
                // if so, check if the mouse cursor is on its active WINDOW
                // that is, is it able to receive multi-touch events?
                CFTypeRef axui = axuiUnderMouse();
                NSString *application = nameOfAxui(axui);
                if (![application isEqualToString:@"Safari"] && ![application isEqualToString:@"Firefox"]) {
                    dispatchCommand(@"Three-Swipe-Left", TRACKPAD);
                    for (int i = 0; i < nFingers; i++) {
                        startx[i] = data[i].px;
                        starty[i] = data[i].py;
                    }
                }
            }
        } else if (moveRight == 3 && type != 4) {
            if (sumx > 0.30) {
                type = 4;
                CFTypeRef axui = axuiUnderMouse();
                NSString *application = nameOfAxui(axui);
                if (![application isEqualToString:@"Safari"] && ![application isEqualToString:@"Firefox"]) {
                    dispatchCommand(@"Three-Swipe-Right", TRACKPAD);
                    for (int i = 0; i < nFingers; i++) {
                        startx[i] = data[i].px;
                        starty[i] = data[i].py;
                    }
                }
            }
        } else {
            //3 finger pinch
            float deltalx = startx[l]-data[l].px;
            float deltaly = starty[l]-data[l].py;
            float deltarx = startx[r]-data[r].px;
            float deltary = starty[r]-data[r].py;

            float lenl = deltalx*deltalx + deltaly*deltaly;
            float lenr = deltarx*deltarx + deltary*deltary;

            float startlen = lenSqr(startx[l], starty[l], startx[r], starty[r]);
            float curlen = lenSqr(data[l].px, data[l].py, data[r].px, data[r].py);

            float deltacosine = cosineBetweenVectors(
                                                     startx[l] - data[l].px,
                                                     starty[l] - data[l].py,
                                                     startx[r] - data[r].px,
                                                     starty[r] - data[r].py
                                                     );
            if (deltacosine < 0.1 && lenl > 0.005 && lenr > 0.003) { //ring finger is harder to move
                if (curlen-startlen > 0.455 * charRegIndexRingDistance && type != 5) {
                    dispatchCommand(@"Three-Finger Pinch-Out", TRACKPAD);
                    type = 5;

                    l = 0; r = 0;
                    for (int i = 0; i < nFingers; i++) {
                        startx[i] = data[i].px;
                        starty[i] = data[i].py;
                        if (data[i].px + data[i].py < data[l].px + data[l].py) {
                            l = i;
                        } else if (data[i].px + data[i].py > data[r].px + data[r].py) {
                            r = i;
                        }
                    }
                } else if (curlen-startlen < -0.455 * charRegIndexRingDistance && type != 6) {
                    dispatchCommand(@"Three-Finger Pinch-In", TRACKPAD);
                    type = 6;

                    l = 0; r = 0;
                    for (int i = 0; i < nFingers; i++) {
                        startx[i] = data[i].px;
                        starty[i] = data[i].py;
                        if (data[i].px+data[i].py < data[l].px+data[l].py) {
                            l = i;
                        } else if (data[i].px+data[i].py > data[r].px+data[r].py) {
                            r = i;
                        }
                    }
                }
            }
        }

    } else if (step == 3) { //end three fingers
        type = 0;
    }

    lastNFingers = nFingers;
}


static void gestureTrackpadSwipeFourFingers(const Finger *data, int nFingers) {
    static float startx[4], starty[4];
    static int lastNFingers;
    int step = 0;
    static int type = 0;

    if (lastNFingers != 4 && nFingers == 4) {
        step = 1;
    } else if (lastNFingers == 4 && nFingers == 4) {
        step = 2;
    } else if (lastNFingers == 4 && nFingers != 4) {
        step = 3;
    }

    if (step == 1) { //start four fingers
        for (int i = 0; i < nFingers; i++) {
            startx[i] = data[i].px;
            starty[i] = data[i].py;
        }
        type = 0;
    } else if (step == 2) { //continue four fingers
        float sumx = 0.0f;
        float sumy = 0.0f;
        int moveDown = 0;
        int moveUp = 0;
        int moveLeft = 0;
        int moveRight = 0;
        for (int i = 0; i < nFingers; i++) {
            sumx += data[i].px - startx[i];
            sumy += data[i].py - starty[i];
            if (data[i].py - starty[i] < -0.08) moveDown++;
            else if (data[i].py - starty[i] > 0.08) moveUp++;
            if (data[i].px - startx[i] < -0.07) moveLeft++;
            else if (data[i].px - startx[i] > 0.07) moveRight++;
        }

        if (moveDown == 4) {
            if (sumy < -0.46 && type != 1) {
                type = 1;
                dispatchCommand(@"Four-Swipe-Down", TRACKPAD);
                for (int i = 0; i < nFingers; i++) {
                    startx[i] = data[i].px;
                    starty[i] = data[i].py;
                }
            }
        } else if (moveUp == 4 && type != 2) {
            if (sumy > 0.46) {
                type = 2;
                dispatchCommand(@"Four-Swipe-Up", TRACKPAD);
                for (int i = 0; i < nFingers; i++) {
                    startx[i] = data[i].px;
                    starty[i] = data[i].py;
                }
            }
        } else if (moveLeft == 4 && type != 3) {
            if (sumx < -0.40) {
                type = 3;
                dispatchCommand(@"Four-Swipe-Left", TRACKPAD);
                for (int i = 0; i < nFingers; i++) {
                    startx[i] = data[i].px;
                    starty[i] = data[i].py;
                }
            }
        } else if (moveRight == 4 && type != 4) {
            if (sumx > 0.40) {
                type = 4;
                dispatchCommand(@"Four-Swipe-Right", TRACKPAD);
                for (int i = 0; i < nFingers; i++) {
                    startx[i] = data[i].px;
                    starty[i] = data[i].py;
                }
            }
        }

    } else if (step == 3) { //end four fingers
        type = 0;
    }

    lastNFingers = nFingers;
}


static void gestureTrackpadTwoFixOneDoubleTap(const Finger *data, int nFingers, double timestamp) {
    static int step = 0;
    static double sttime;
    static float fing[3][2];
    static int idf[3];
    int i, j;
    if (nFingers <= 1 || nFingers > 3)
    	  step = 0;
    if (step == 0 && nFingers == 2) {
        step = 1;
    } else if (step == 1 && nFingers == 3 && data[0].size > 0.15 && data[1].size > 0.15 && data[2].size > 0.15) {
        for (i = 0; i < 3; i++) {
            fing[i][0] = data[i].px;
            fing[i][1] = data[i].py;
        }
        idf[0] = 0;
        idf[2] = 2;
        for (i = 0; i < 3; i++) {
            if (data[i].px+data[i].py < data[idf[0]].px+data[idf[0]].py)
                idf[0] = i;
            if (data[i].px+data[i].py > data[idf[2]].px+data[idf[2]].py)
                idf[2] = i;
        }
        idf[1] = 3 - idf[0] - idf[2];
        for (i = 0; i < 3; i++)
            idf[i] = data[idf[i]].identifier;

        sttime = timestamp;
        step = 2;
    } else if (step == 2 || step == 4) {
        if (timestamp - sttime > clickSpeed)
            step = 0;
        if (nFingers == 2) {
            if (step == 2) {
                sttime = timestamp;
                step = 3;
            } else if (step == 4) {
                for (i = 0; i < 3; i++) {
                    for (j = 0; j < 2; j++)
                        if (data[j].identifier == idf[i])
                            break;
                    if (j == 2) {
                        if (i == 0)
                            dispatchCommand(@"Two-Fix Index-Double-Tap", TRACKPAD);
                        else if (i == 1)
                            dispatchCommand(@"Two-Fix Middle-Double-Tap", TRACKPAD);
                        else
                            dispatchCommand(@"Two-Fix Ring-Double-Tap", TRACKPAD);
                        break;
                    }
                }

                step = 0;
            }
        }
    } else if (step == 3) {
        if (timestamp - sttime > clickSpeed)
            step = 0;
        if (nFingers == 3 && data[0].size > 0.15 && data[1].size > 0.15 && data[2].size > 0.15) {
            for (i = 0; i < 3; i++) {
                for (j = 0; j < 3; j++) {
                    if (lenSqr(fing[j][0], fing[j][1], data[i].px, data[i].py) < 0.001)
                        break;
                }
                if (j == 3) break;
            }
            if (i < 3)
                step = 0;
            else {
                step = 4;
                sttime = timestamp;
            }
        }
    }
}


static void gestureTrackpadAutoScroll(const Finger *data, int nFingers, double timestamp) {
    static double sttime;
    static int step = 0;
    static float midY;
    float x[2] = {data[0].px, data[1].px};
    static int startAlready = 0;
    static int shouldCheck = 1, chk[2];
    if (enHanded) {
        x[0] = 1 - x[0];
        x[1] = 1 - x[1];
    }

    if (step == 0) {
        if (nFingers == 2) {
            if (((x[0] < x[1]) ? x[0] : x[1]) < 0.08 || ((x[0] > x[1]) ? x[0] : x[1]) > 0.92) {
                if (shouldCheck) {
                    chk[0] = [commandForGesture(@"Left-Side Scroll", TRACKPAD) isEqualToString:@"Auto Scroll"];
                    chk[1] = [commandForGesture(@"Right-Side Scroll", TRACKPAD) isEqualToString:@"Auto Scroll"];
                    shouldCheck = 0;
                }
                if (
                   (chk[0] && ((x[0] < x[1]) ? x[0] : x[1]) < 0.08) ||
                   (chk[1] && ((x[0] > x[1]) ? x[0] : x[1]) > 0.92)
                   ) {
                    step = 1;
                    startAlready = 0;
                    midY = (data[0].py + data[1].py) / 2;
                }
            }
        } else if (nFingers == 1) {
            shouldCheck = 1;
        }
    } else if (step == 1) {
        if (timestamp > sttime) {
            float avgY = (data[0].py + data[1].py) / 2;
            float speedf = -((midY - avgY) * (midY - avgY) * (midY - avgY) * 50 * 8);
            if (!startAlready && fabs(speedf) < 0.1)
                speedf = 0;
            else
                startAlready = 1;

            int speed = (int)(speedf < 0 ? floorf(speedf) : ceilf(speedf));
            autoScrollFlag = speed == 0 ? 0 : (speed > 0 ? 1 : -1);
            CGEventRef eventRef = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, speed);
            if (eventRef) {
                CGEventPost(kCGHIDEventTap, eventRef);
                CFRelease(eventRef);
            }
            sttime = timestamp + 0.01;
        }
        if (nFingers != 2) {
            step = 0;
            autoScrollFlag = 0;
        }
    }
}


static int trackpadCallback(MTDeviceRef device, Finger *data, int nFingers, double timestamp, int frame) {
    if (DEBUG && logLevel >= LOG_LEVEL_TRACE) NSLog(@"TrackpadCallback %p", device);
    trackpadNFingers = nFingers;
    if (nFingers == 2) {
        twoFingersDistance = lenSqrF(data, 0, 1);
    } else if (nFingers > 2) {
        twoFingersDistance = 100;
        lastThreeFingerDate = [NSDate date];
        lastTwoFingerDate = [NSDate dateWithTimeIntervalSinceNow:-10];
    } else {
        twoFingersDistance = 100;
    }
    if (twoFingersDistance < 0.3f && fabs([lastThreeFingerDate timeIntervalSinceNow]) > 0.05) {
        trackpadHasTwoFingers = TRUE;
        lastTwoFingerDate = [NSDate date];
    } else {
        trackpadHasTwoFingers = FALSE;
    }

    static int thumbId = -1;
    Finger *dataUnnormalized = (Finger *)malloc(sizeof(Finger) * nFingers);
    for (int i = 0; i < nFingers; i++) {
        dataUnnormalized[i] = data[i];
        dataUnnormalized[i].px /= 1;
        dataUnnormalized[i].py /= 1;
    }

    if (nFingers == 0) {
        thumbId = -1;
    }

    if (enAll && enTPAll) {
        if (enCharRegTP) {
            // IMPORTANT : DO NOT CHANGE ORDER
            if (enTwoDrawing)
                trackpadRecognizerTwo(dataUnnormalized, nFingers, timestamp);
            if (enOneDrawing)
                trackpadRecognizerOne(data, nFingers, timestamp);
        }

        // remove hovering and other touch events
        for (int i = 0; i < nFingers; i++) {
            if (
                ! (
                    data[i].state == MTTouchStateMakeTouch ||
                    data[i].state == MTTouchStateTouching ||
                    data[i].state == MTTouchStateBreakTouch
                  )
                ) {
                if (DEBUG && logLevel >= LOG_LEVEL_TRACE) NSLog(@"Filtered %d %d %f %f", data[i].identifier, data[i].state, data[i].px, data[i].py);
                data[i--] = data[--nFingers];
            }
        }

        // detect thumb & palm resting
        int cl, cli, tl, tli;
        float mY, mX;
        cl = 0;
        tl = 0;
        mY = 1;

        mX = 1 - enHanded;
        for (int i = 0; i < nFingers; i++) {
            if (enHanded) {
                if (data[i].px > 1 - 0.1) {
                    tl++;
                    tli = i;
                } else if (data[i].px > mX) {
                    mX = data[i].px;
                }
            } else {
                if (data[i].px < 0.1) {
                    tl++;
                    tli = i;
                } else if (data[i].px < mX) {
                    mX = data[i].px;
                }
            }
        }
        if (tl == 1 && nFingers > 1 && fabs(mX - data[tli].px) >= 0.25) {
            if (DEBUG && logLevel >= LOG_LEVEL_TRACE) NSLog(@"Filtered %d %d %f %f", data[tli].identifier, data[tli].state, data[tli].px, data[tli].py);
            data[tli] = data[--nFingers];
        }

        if (thumbId != -1) {
            int tmp = 1;
            for (int i = 0; i < nFingers; i++) {
                if (data[i].identifier == thumbId) {
                    if (DEBUG && logLevel >= LOG_LEVEL_TRACE) NSLog(@"Filtered thumb %d %d %f %f", data[i].identifier, data[i].state, data[i].px, data[i].py);
                    data[i] = data[--nFingers];
                    tmp = 0;
                    break;
                }
            }
            if (tmp) {
                thumbId = -1;
            }
        } else {
            for (int i = 0; i < nFingers; i++) {
                if (data[i].py < 0.1 || data[i].majorAxis - data[i].minorAxis >= 5.5) {
                    cl++;
                    cli = i;
                } else if (data[i].py<mY)
                    mY = data[i].py;
            }
            if (cl == 1 && nFingers > 1 && mY-data[cli].py >= 0.4) {
                thumbId = data[cli].identifier;
                if (DEBUG && logLevel >= LOG_LEVEL_TRACE) NSLog(@"Filtered %d %d %f %f", data[cli].identifier, data[cli].state, data[cli].px, data[cli].py);
                data[cli] = data[--nFingers];
            }
        }

        if (DEBUG && logLevel >= LOG_LEVEL_TRACE) {
            for (int i = 0; i < nFingers; i++) {
                NSLog(@"MTTouch %d %d %f %f", data[i].identifier, data[i].state, data[i].px, data[i].py);
            }
        }

        if (enHanded)
            for (int i = 0; i < nFingers; i++)
                data[i].px = 1 - data[i].px;

        if (!gestureTrackpadMoveResize(data, nFingers, timestamp)) {
            if (!isTrackpadRecognizing) {
                gestureTrackpadAutoScroll(data, nFingers, timestamp);

                gestureTrackpadOneFixOneTap(data, nFingers, timestamp);

                gestureTrackpadThreeFingerTap(data, nFingers, timestamp);

                gestureTrackpadOneFixTwoSlide(data, nFingers, timestamp);
                gestureTrackpadChangeSpace(data, nFingers);

                gestureTrackpadTab4(data, nFingers, timestamp, 0);
                gestureTrackpadTab4(data, nFingers, timestamp, 1);
                gestureTrackpadFourFingerTap(data, nFingers, timestamp);
                trackpadTab4Triggered = FALSE;

                gestureTrackpadSwipeThreeFingers(data, nFingers);
                gestureTrackpadSwipeFourFingers(data, nFingers);
            }
            gestureTrackpadTwoFixOneDoubleTap(data, nFingers, timestamp);
        }
    }

    free(dataUnnormalized);
    return 0;
}

#pragma mark - Magic Mouse

static void gestureMagicMouseSwipeThreeFingers(Finger *data, int nFingers, double timestamp, int thumbPresent) {
    static double beforeendtime = -10;
    static double endtime = -1;
    static float startx[3], starty[3];
    static int lastNFingers;
    int step = 0;

    if (thumbPresent) {
        Finger tmp = data[thumbPresent - 1];
        data[thumbPresent - 1] = data[--nFingers];
        data[nFingers] = tmp;
    }

    if (lastNFingers != 3 && nFingers == 3) {
        step = 1;
        if (endtime - beforeendtime < 0.01) { //gap created by hardware (so short human can't do)
            step = 2;
        }
    } else if (lastNFingers == 3 && nFingers == 3) {
        step = 2;
    } else if (lastNFingers == 3 && nFingers != 3) {
        step = 3;
    }

    if (step == 1) { //start three fingers

        for (int i = 0; i < nFingers; i++) {
            startx[i] = data[i].px;
            starty[i] = data[i].py;
        }

        beforeendtime = timestamp;

        trigger = 0;

    } else if (step == 2) { //continue three fingers

        float sumx = 0.0f;
        float sumy = 0.0f;
        int moveRight = 0;
        int moveLeft = 0;
        int moveDown = 0;
        int moveVeryDown = 0;
        int moveUp = 0;
        for (int i = 0; i < nFingers; i++) {
            sumx += data[i].px - startx[i];
            sumy += data[i].py - starty[i];
            if (data[i].px - startx[i] > 0.01) moveRight++; //it's harder to swipe right than to swipe left
            else if (data[i].px - startx[i] < -0.015) moveLeft++;
            if (data[i].py - starty[i] < -0.03) moveDown++;
            if (data[i].py - starty[i] < -0.04) moveVeryDown++;
            else if (data[i].py - starty[i] > 0.03) moveUp++;
        }

        if (moveDown < 3 && moveUp < 3) {
            if (moveLeft == 3 && sumx < -0.25) {
                if (!trigger) {
                    dispatchCommand(@"Three-Swipe-Left", MAGICMOUSE);
                    trigger = 1;
                }
            } else if (moveRight >= 3 && sumx > 0.22) {
                if (!trigger) {
                    dispatchCommand(@"Three-Swipe-Right", MAGICMOUSE);
                    trigger = 1;
                }
            }
        } else if (moveVeryDown == 3) {
            if (sumy < -0.17) {
                if (!trigger) {
                    dispatchCommand(@"Three-Swipe-Down", MAGICMOUSE);
                    trigger = 1;
                }
            }
        } else if (moveUp == 3) {
            if (sumy > 0.25) {
                if (!trigger) {
                    dispatchCommand(@"Three-Swipe-Up", MAGICMOUSE);
                    trigger = 1;
                }
            }
        }
        beforeendtime = timestamp;
        endtime = timestamp;

    } else if (step == 3) { //end three fingers
        endtime = timestamp;
        trigger = 0;
    }

    lastNFingers = nFingers;

    if (thumbPresent) {
        Finger tmp = data[thumbPresent - 1];
        data[thumbPresent - 1] = data[nFingers];
        data[nFingers] = tmp;
    }
}

static void gestureMagicMouseTwoFingers(Finger *data, int nFingers, double timestamp, int thumbPresent) {
    static double beforeendtime = -10;
    static double endtime = -1;
    static float startx[3], starty[3];
    static int lastNFingers;
    int step = 0;

    if (thumbPresent) {
        Finger tmp = data[thumbPresent - 1];
        data[thumbPresent - 1] = data[--nFingers];
        data[nFingers] = tmp;
    }

    if (lastNFingers != 2 && nFingers == 2) {
        step = 1;
        if (endtime - beforeendtime < 0.01) { //gap created by hardware (so short human can't do)
            step = 2;
        }
    } else if (lastNFingers == 2 && nFingers == 2) {
        step = 2;
    } else if (lastNFingers == 2 && nFingers != 2) {
        step = 3;
    }

    if (step == 1) { //start two fingers

        if (data[0].px > data[1].px) {
            Finger tmp = data[0];
            data[0] = data[1];
            data[1] = tmp;
        }

        for (int i = 0; i < nFingers; i++) {
            startx[i] = data[i].px;
            starty[i] = data[i].py;
        }

        beforeendtime = timestamp;

        trigger = 0;

    } else if (step == 2) { //continue two fingers
        if (data[0].px > data[1].px) {
            Finger tmp = data[0];
            data[0] = data[1];
            data[1] = tmp;
        }

        float diffx[2], diffy[2];
        diffx[0] = data[0].px - startx[0];
        diffy[0] = data[0].py - starty[0];
        diffx[1] = data[1].px - startx[1];
        diffy[1] = data[1].py - starty[1];
        float dis0 = lenSqr(data[0].px, data[0].py, startx[0], starty[0]);
        float dis1 = lenSqr(data[1].px, data[1].py, startx[1], starty[1]);

        if (!trigger) {
            if (dis1 < 0.002 && dis0 > 0.06 && fabs(diffy[0]) < 0.05) {
                if (diffx[0] < 0) {
                    dispatchCommand(@"Middle-Fix Index-Slide-Out", MAGICMOUSE);
                    trigger = 1;
                } else {
                    dispatchCommand(@"Middle-Fix Index-Slide-In", MAGICMOUSE);
                    trigger = 1;
                }

            } else if (dis0 < 0.002 && dis1 > 0.02 && fabs(diffy[1]) < 0.05) {
                if (diffx[1] < 0) {
                    dispatchCommand(@"Index-Fix Middle-Slide-In", MAGICMOUSE);
                    trigger = 1;
                } else {
                    dispatchCommand(@"Index-Fix Middle-Slide-Out", MAGICMOUSE);
                    trigger = 1;
                }
            } else if (dis0 > 0.01 && dis1 > 0.01 && (dis0 > 0.02 || dis1 > 0.02) &&
                       fabs(diffy[0]) < 0.1 &&  fabs(diffy[1]) < 0.1) {
                if (diffx[0] < 0 && diffx[1] > 0) {
                    dispatchCommand(@"Pinch Out", MAGICMOUSE);
                    trigger = 1;
                } else if (diffx[0] > 0 && diffx[1] < 0) {
                    dispatchCommand(@"Pinch In", MAGICMOUSE);
                    trigger = 1;
                }
            }
        }

        beforeendtime = timestamp;
        endtime = timestamp;

    } else if (step == 3) { //end two fingers
        endtime = timestamp;
        trigger = 0;
    }

    lastNFingers = nFingers;

    if (thumbPresent) {
        Finger tmp = data[thumbPresent - 1];
        data[thumbPresent - 1] = data[nFingers];
        data[nFingers] = tmp;
    }
}


static int gestureMagicMouseV(const Finger *data, int nFingers) {
    int min = data[0].px > data[1].px;
    static CGFloat baseX, baseY, appX, appY;
    static CFTypeRef cWindow;
    static int type = 0, firstTouch = 1, reset = 0;
    int init = 0;
    static float fing[2][2];
    static float lastMouseX = -99999, lastMouseY = -99999;

    if (cWindow == NULL) {
        if (nFingers == 2) {
            if (firstTouch) {
                fing[0][0] = data[0].px;
                fing[0][1] = data[0].py;
                fing[1][0] = data[1].px;
                fing[1][1] = data[1].py;
                firstTouch = 0;
            }
            // If fingers change too much, need to start over.
            if (!reset && (lenSqr(fing[0][0], fing[0][1], data[0].px, data[0].py) > 0.0005 || lenSqr(fing[1][0], fing[1][1], data[1].px, data[1].py) > 0.0005))
                reset = 1;

            // Check gesture.
            if (!reset &&
               ((data[min].py > 0.9 && data[min].px <= 0.18) || (data[min].py > 0.8 && data[min].px <= 0.15)) &&
               ((data[!min].py > 0.9 && data[!min].px >= 0.82) || (data[!min].py > 0.8 && data[!min].px >= 0.85)) &&
               [commandForGesture(@"V-Shape", MAGICMOUSE) isEqualToString:@"Move / Resize"]) {
                init = 1;
                type = 1;
            }
        } else if (nFingers == 0) {
            firstTouch = 1;
            reset = 0;
        }

    } else {
        // Halt.
        if (nFingers == 0 || nFingers > 2) {
            CFSafeRelease(cWindow);
            cWindow = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow orderOut:nil]; }); // AppKit only on the main thread
                }
            });
            type = 0;
            firstTouch = 1;
            reset = 0;
        // Move or resize.
        } else if (nFingers <= 2) {
            if (type != 3-nFingers) {
                type = 3-nFingers;
                init = 1;
            }
        }
    }

    if (init) {
        getMousePosition(&baseX, &baseY);
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow orderOut:nil]; }); // AppKit only on the main thread
            }
        });
        if (cWindow == nil)
            cWindow = activateWindowAtPosition(baseX, baseY);

        if (cWindow == nil) {
            type = 0;
        } else {
            getWindowPos(cWindow, &appX, &appY);

            cursorImageType = type - 1;
            dispatch_async(dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow display]; }); // AppKit only on the main thread
                    dispatch_async(dispatch_get_main_queue(), ^{ [[cursorWindow contentView] setNeedsDisplay:YES]; }); // AppKit only on the main thread
                    setCursorWindowAtMouse();
                    dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow setLevel:NSScreenSaverWindowLevel]; }); // AppKit only on the main thread
                    dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow makeKeyAndOrderFront:nil]; }); // AppKit only on the main thread
                }
            });
        }
    }
    if (type) {
        CGFloat x, y;
        getMousePosition(&x, &y);
        if (init || x != lastMouseX || y != lastMouseY) {
            setCursorWindowAtMouse();
            if (type == 1) {
                setWindowPos2(cWindow, x, y, baseX, baseY, appX, appY);
            } else if (type == 2) {
                if (!setWindowSize2(cWindow, x, y, baseX, baseY)) {
                    CFSafeRelease(cWindow);
                    cWindow = nil;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @autoreleasepool {
                            dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow orderOut:nil]; }); // AppKit only on the main thread
                        }
                    });
                    type = 0;
                    firstTouch = 1;
                    reset = 0;
                } else {
                    float nx = x, ny = y;
                    if (x >= appX + 3)
                        baseX = x;
                    else
                        nx = appX + 3;
                    if (y >= appY + 3)
                        baseY = y;
                    else
                        ny = appY + 3;
                    if (nx != x || ny != y) {
                        mouseClick(8, nx, ny);
                    }
                }
            }
            lastMouseX = x;
            lastMouseY = y;
        }
    }

    return 0;
}


static void gestureMagicMouseTwoFixOneSlide(Finger *data, int nFingers, double timestamp, int thumbPresent) {
    static int step = 0;
    static float fing[3][2];
    // Min id
    static int mini;
    static int move = 0;
    static float last[2];

    static int lastThumbPresent = 0;
    if (!thumbPresent && lastThumbPresent && nFingers == 3) {
        thumbPresent = lastThumbPresent;
    }
    if (thumbPresent) {
        Finger tmp = data[thumbPresent - 1];
        data[thumbPresent - 1] = data[--nFingers];
        data[nFingers] = tmp;
    }
    lastThumbPresent = thumbPresent;

    if (step == 0 && nFingers == 2) {
        if (lenSqrF(data, 0, 1) < 0.4) {
            step = 1;
        }
    } else if (step == 1) {
        if (nFingers == 2 && lenSqrF(data, 0, 1) >= 0.4) {
            step = 0;
        } else if (nFingers == 3) {
            mini = 0;
            for (int i = 0; i < 3; i++) {
                fing[i][0] = data[i].px;
                fing[i][1] = data[i].py;
                if (fing[i][0] + fing[i][1] < fing[mini][0] + fing[mini][1]) {
                    mini = i;
                }
            }
            step = 2;
            move = 0;
        }
    } else if (step == 2) {
        if (nFingers != 3) {
            step = 0;
        } else {
            for (int i = 0; i < 3; i++) {
                if (i != mini && lenSqr(data[i].px, data[i].py, fing[i][0], fing[i][1]) > 0.001) {
                    step = 0;
                }
            }
            if (!move) {
                if (lenSqr(data[mini].px, data[mini].py, fing[mini][0], fing[mini][1]) > 0.001) {
                    move = 1;
                    last[0] = fing[mini][0];
                    last[1] = fing[mini][1];
                }
            } else {

                if (
                    (
                     lenSqr(data[mini].px, data[mini].py, last[0], last[1]) < 0.000001 ||
                     data[mini].state == MTTouchStateBreakTouch
                    ) &&
                    (
                     fabs(data[mini].px - fing[mini][0]) >= 0.07 * charRegIndexRingDistance / 0.33 ||
                     fabs(data[mini].py - fing[mini][1]) >= 0.08 * charRegIndexRingDistance / 0.33
                    )
                ) {
                    float dx = fabs(fing[mini][0] - data[mini].px), dy = fabs(fing[mini][1] - data[mini].py);
                    if (dx > dy) {
                        if (fing[mini][0] < data[mini].px)
                            dispatchCommand(@"Two-Fix One-Slide-Right", MAGICMOUSE);
                        else
                            dispatchCommand(@"Two-Fix One-Slide-Left", MAGICMOUSE);
                    } else {
                        if (fing[mini][1] < data[mini].py)
                            dispatchCommand(@"Two-Fix One-Slide-Up", MAGICMOUSE);
                        else
                            dispatchCommand(@"Two-Fix One-Slide-Down", MAGICMOUSE);
                    }
                    move = 0;
                    fing[mini][0] = data[mini].px;
                    fing[mini][1] = data[mini].py;
                }
                last[0] = data[mini].px;
                last[1] = data[mini].py;
            }
        }
    }
}

static int gestureMagicMouseThumb(const Finger *data, int nFingers) {
    static int type = 0;
    int tb = 0;
    int ret = 0;
    if (nFingers > 0) {
        for (int i = 1; i < nFingers; i++)
            if (data[i].py < data[tb].py)
                tb = i;

        if (data[tb].py <= 0.6 && data[tb].px <= 0.15) {
            if (type == 0) {
                if ([commandForGesture(@"Thumb", MAGICMOUSE) isEqualToString:@"Quick Tab Switching"]) {
                    findTabGroup_lx = -99999;
                    if (selectSafariTab()) { // mouse is on Safari
                        cursorImageType = 2;
                        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
                        dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow display]; }); // AppKit only on the main thread
                        dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow setLevel:NSScreenSaverWindowLevel]; }); // AppKit only on the main thread
                        dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow makeKeyAndOrderFront:nil]; }); // AppKit only on the main thread
                        [pool release];
                        type = 1;
                        quickTabSwitching = 1;
                    }
                } else if ([commandForGesture(@"Thumb", MAGICMOUSE) isEqualToString:@"Middle Click"]) {
                    type = 1;
                    simulating = MIDDLEBUTTONDOWN;
                    simulatingByDevice = MAGICMOUSE;

                    CGEventRef ourEvent = CGEventCreate(NULL);
                    CGPoint location = CGEventGetLocation(ourEvent);
                    CFRelease(ourEvent);
                    CGEventRef eventRef = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseDown, location, kCGMouseButtonCenter);
                    CGEventSetIntegerValueField(eventRef, kCGMouseEventButtonNumber, 2);
                    CGEventPost(kCGSessionEventTap, eventRef);
                    CFRelease(eventRef);
                } else {
                    type = 1;
                    dispatchCommand(@"Thumb", MAGICMOUSE);
                }
            }
            ret = tb + 1;
        } else if (type == 1) {
            NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
            dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow orderOut:nil]; }); // AppKit only on the main thread
            [pool release];
            type = 0;
            quickTabSwitching = 0;

            if ([commandForGesture(@"Thumb", MAGICMOUSE) isEqualToString:@"Middle Click"]) {
                CGEventRef ourEvent = CGEventCreate(NULL);
                CGPoint location = CGEventGetLocation(ourEvent);
                CFRelease(ourEvent);
                CGEventRef eventRef = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseUp, location, kCGMouseButtonCenter);
                CGEventSetIntegerValueField(eventRef, kCGMouseEventButtonNumber, 2);
                CGEventPost(kCGSessionEventTap, eventRef);
                CFRelease(eventRef);
                simulating = 0;
            }
        }
    } else if (type == 1) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        dispatch_async(dispatch_get_main_queue(), ^{ [cursorWindow orderOut:nil]; }); // AppKit only on the main thread
        [pool release];
        type = 0;
        quickTabSwitching = 0;

        if ([commandForGesture(@"Thumb", MAGICMOUSE) isEqualToString:@"Middle Click"]) {
            CGEventRef ourEvent = CGEventCreate(NULL);
            CGPoint location = CGEventGetLocation(ourEvent);
            CFRelease(ourEvent);
            CGEventRef eventRef = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseUp, location, kCGMouseButtonCenter);
            CGEventSetIntegerValueField(eventRef, kCGMouseEventButtonNumber, 2);
            CGEventPost(kCGSessionEventTap, eventRef);
            CFRelease(eventRef);
            simulating = 0;
        }
    }
    return ret;
}

static void gestureMagicMouseMiddleClick(const Finger *data, int nFingers) {
    middleClickFlag = (nFingers == 2 && (data[0].px > 0.47
                                         || (data[0].px > 0.35 && (data[0].px - data[1].px == 0 || (data[0].py - data[1].py) / (data[0].px - data[1].px) >= 0.16)) ))
                    || (nFingers == 1 && data[0].majorAxis > 10 && fabs(data[0].angle-1.5708) > 0.7854);
}

static int gestureMagicMouseOneFixOneTap(const Finger *data, int nFingers, double timestamp) {
    static double sttime = -1;
    static float fing[2][2];
    static int step = 0;
    static int fixId;
    static float avgx, avgy;

    if (CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft)) {
        sttime = -1;
    }

    if (step == 0 && nFingers == 1) {
        step = 1;
        fixId = data[0].identifier;
        sttime = -1;
    } else if (step == 1) {
        if (nFingers == 2) {
            if (fabs(data[0].py-data[1].py) < 0.25) {
                if (sttime < 0)
                    sttime = timestamp;
                if ((data[0].identifier == fixId || data[0].size > stvt / 10 + 0.2) &&
                   (data[1].identifier == fixId || data[1].size > stvt / 10 + 0.2)) {
                    step = 2;
                    avgx = (data[0].px + data[1].px) / 2;
                    avgy = (data[0].py + data[1].py) / 2;
                    fing[0][0] = data[0].px;
                    fing[0][1] = data[0].py;
                    fing[1][0] = data[1].px;
                    fing[1][1] = data[1].py;
                }
            } else
                step = 0;
        } else if (nFingers == 1) {
            sttime = -1;
            fixId = data[0].identifier;
        } else
            step = 0;
    } else if (step == 2) {
        if (nFingers == 1) {
            if (timestamp - sttime > clickSpeed)
                step = 0;
            else {
                if (data[0].identifier == fixId) {
                    if (avgx < data[0].px) {
                        if (fabs(avgx - data[0].px) > 0.22)
                            dispatchCommand(@"Middle-Fix Index-Far-Tap", MAGICMOUSE);
                        else
                            dispatchCommand(@"Middle-Fix Index-Near-Tap", MAGICMOUSE);
                    } else {
                        if (fabs(avgx - data[0].px) > 0.22)
                            dispatchCommand(@"Index-Fix Middle-Far-Tap", MAGICMOUSE);
                        else
                            dispatchCommand(@"Index-Fix Middle-Near-Tap", MAGICMOUSE);
                    }
                }
            }
            step = 0;
        } else if (nFingers == 2) {
            if (lenSqr(data[0].px, data[0].py, fing[0][0], fing[0][1]) > 0.0007 || lenSqr(data[1].px, data[1].py, fing[1][0], fing[1][1]) > 0.0007)
                step = 0;
        } else {
            step = 0;
        }
    }

    return 0;
}


static int magicMouseCallback(MTDeviceRef device, Finger *data, int nFingers, double timestamp, int frame) {
    int ignore = 0;

    if (!enAll || !enMMAll) {
        turnOffMagicMouse();
        return 0;
    }

    if (nFingers > 1) {
        for (int i = 0; i < nFingers; i++) {
            if (data[i].py < 0.3) {
                data[i] = data[--nFingers];
            }

            if ((data[i].px < 0.001 || data[i].px > 0.999) && data[i].size < 0.375000) {
                data[i] = data[--nFingers];
            }

            if (data[i].size > 5.5) {
                ignore = 1;
                break;
            }
        }
    }

    // Before the left-handed mirror below, so drawn letters are never flipped.
    if (enCharRegMM)
        magicMouseFingerRecognizer(data, nFingers, timestamp);

    if (enMMHanded) {
        for (int i = 0; i < nFingers; i++)
            data[i].px = 1 - data[i].px;
    }

    if (!ignore && !isMMFingerRecognizing && !mmDragging) { // our drag owns the touches until it ends
        int thumbPresent = gestureMagicMouseThumb(data, nFingers);
        disableHorizontalScroll = (nFingers > 1);

        magicMouseThreeFingerFlag = (nFingers - (thumbPresent > 0 ? 1 : 0) == 3);

        gestureMagicMouseSwipeThreeFingers(data, nFingers, timestamp, thumbPresent);
        gestureMagicMouseTwoFingers(data, nFingers, timestamp, thumbPresent);
        gestureMagicMouseOneFixOneTap(data, nFingers, timestamp);
        gestureMagicMouseV(data, nFingers);
        gestureMagicMouseTwoFixOneSlide(data, nFingers, timestamp, thumbPresent);
        gestureMagicMouseMiddleClick(data, nFingers);
    }

    return 0;
}



#pragma mark - Hardware Add/Remove Notifications

- (void)addMultitouchDevice:(NSTimer*)theTimer {
    BOOL found = NO;
    NSMutableDictionary* dict = [theTimer userInfo];
    int attemptMT = [dict[@"Attempt"] intValue];
    uint64_t newDeviceMultitouchID = [dict[@"Multitouch ID"] unsignedIntegerValue];
    if (logLevel >= LOG_LEVEL_INFO) NSLog(@"Adding device: %"PRIu64", try %d", newDeviceMultitouchID, attemptMT);

    CFMutableArrayRef tempDeviceList = MTDeviceCreateList();

    for (CFIndex i = 0; i < CFArrayGetCount(tempDeviceList); i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(tempDeviceList, i);
        int familyID;
        MTDeviceGetFamilyID(device, &familyID);
        uint64_t deviceID = 0;
        MTDeviceGetDeviceID(device, &deviceID);

        if (deviceID != newDeviceMultitouchID) {
            continue;
        }

        CFIndex oldIndex = -1;
        for (CFIndex i = 0; i < CFArrayGetCount(deviceList); i++) {
            MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(deviceList, i);
            uint64_t deviceID = 0;
            MTDeviceGetDeviceID(device, &deviceID);
            if (deviceID == newDeviceMultitouchID) {
                if (MTDeviceIsRunning(device)) {
                    if (logLevel >= LOG_LEVEL_INFO) NSLog(@"Stop device %li %"PRIu64" family %d (%s)", (long)i, deviceID, familyID, (MTDeviceIsRunning(device)) ? "running" : "not running");
                    if (familyID >= MINFAMILYID) {
                        MTUnregisterContactFrameCallback(device, trackpadCallback);
                        MTUnregisterContactFrameCallback(device, magicMouseCallback);
                        MTDeviceStop(device);
                    }
                    if (logLevel >= LOG_LEVEL_INFO) NSLog(@"Device %li %"PRIu64" family %d is %s", (long)i, deviceID, familyID, (MTDeviceIsRunning(device)) ? "running" : "not running");
                }
                oldIndex = i;
                break;
            }
        }
        if (oldIndex >= 0) {
            CFArrayRemoveValueAtIndex(deviceList, oldIndex);
        }

        if (logLevel >= LOG_LEVEL_INFO) NSLog(@"Start device %li %"PRIu64", family %d (%s)", (long)i, deviceID, familyID, (MTDeviceIsRunning(device)) ? "running" : "not running");
        if (familyIsBuiltinTrackpad(familyID)) {
            MTRegisterContactFrameCallback(device, trackpadCallback);
            MTDeviceStart(device, 0);
        } else if (familyIsMagicMouse(familyID)) {
            MTRegisterContactFrameCallback(device, magicMouseCallback);
            MTDeviceStart(device, 0);
        } else if (familyIsMagicTrackpad(familyID)) {
            MTRegisterContactFrameCallback(device, trackpadCallback);
            MTDeviceStart(device, 0);
        } else if (familyID >= MINFAMILYID) { // Unknown ID. Assume it's a trackpad.
            MTRegisterContactFrameCallback(device, trackpadCallback);
            MTDeviceStart(device, 0);
        }
        if (logLevel >= LOG_LEVEL_INFO) NSLog(@"Device %li %"PRIu64" family %d is %s", (long)i, deviceID, familyID, (MTDeviceIsRunning(device)) ? "running" : "not running");

        if (familyID >= MINFAMILYID) {
            found = YES;
            CFArrayAppendValue(deviceList, device);
        }
    }

    CFRelease(tempDeviceList);

    if (!found && attemptMT < 3) {
        attemptMT++;
        dict[@"Attempt"] = [NSNumber numberWithInt:attemptMT];
        [NSTimer scheduledTimerWithTimeInterval:1.0 target:me selector:@selector(addMultitouchDevice:) userInfo:dict repeats:NO];
    }
}

static void multitouchDeviceAdded(void* refCon, io_iterator_t iterator) {
    io_service_t newDevice;
    while ((newDevice = IOIteratorNext(iterator))) {
        io_name_t devName;
        io_string_t pathName;
        CFTypeRef deviceIDRef;
        int familyID;
        NSInteger deviceID = 0;

        IORegistryEntryGetName(newDevice, devName);
//        NSLog(@"Device's name = %s\n", devName);
        IORegistryEntryGetPath(newDevice, kIOServicePlane, pathName);
//        NSLog(@"Device's path in IOService plane = %s\n", pathName);

        deviceIDRef = IORegistryEntrySearchCFProperty(newDevice, pathName, CFSTR("Family ID"), kCFAllocatorDefault, 0);
        if (deviceIDRef != NULL) {
            familyID = (int)[(NSString*)deviceIDRef integerValue];
//            NSLog(@"Device's family ID = %@ -> %d", deviceIDRef, familyID);
            CFRelease(deviceIDRef);
        }
        deviceIDRef = IORegistryEntrySearchCFProperty(newDevice, pathName, CFSTR("Multitouch ID"), kCFAllocatorDefault, 0);
        if (deviceIDRef != NULL) {
            deviceID = [(NSString*)deviceIDRef integerValue];
//            NSLog(@"Device's multitouch ID = %@ -> %llu", deviceIDRef, (uint64_t)deviceID);
            CFRelease(deviceIDRef);
        }

        IOObjectRelease(newDevice);

        NSMutableDictionary* dict = [NSMutableDictionary dictionaryWithDictionary:@{
            @"Multitouch ID": [NSNumber numberWithInteger:deviceID],
            @"Attempt": @0,
        }];
        [NSTimer scheduledTimerWithTimeInterval:0.0 target:me selector:@selector(addMultitouchDevice:) userInfo:dict repeats:NO];
    }
}

static void multitouchDeviceRemoved(void* refCon, io_iterator_t iterator) {
    io_service_t removedDevice;
    while ((removedDevice = IOIteratorNext(iterator))) {
        io_name_t devName;
        io_string_t pathName;
        CFTypeRef deviceIDRef;
        int familyID = -1;
        NSInteger deviceID = 0;

        IORegistryEntryGetName(removedDevice, devName);
//        NSLog(@"Device's name = %s\n", devName);
        IORegistryEntryGetPath(removedDevice, kIOServicePlane, pathName);
//        NSLog(@"Device's path in IOService plane = %s\n", pathName);

        deviceIDRef = IORegistryEntrySearchCFProperty(removedDevice, pathName, CFSTR("Family ID"), kCFAllocatorDefault, 0);
        if (deviceIDRef != NULL) {
            familyID = (int)[(NSString*)deviceIDRef integerValue];
//            NSLog(@"Device's family ID = %@ -> %d", deviceIDRef, familyID);
            CFRelease(deviceIDRef);
        }
        deviceIDRef = IORegistryEntrySearchCFProperty(removedDevice, pathName, CFSTR("Multitouch ID"), kCFAllocatorDefault, 0);
        if (deviceIDRef != NULL) {
            deviceID = [(NSString*)deviceIDRef integerValue];
//            NSLog(@"Device's multitouch ID = %@ -> %"PRIu64, deviceIDRef, (uint64_t)deviceID);
            CFRelease(deviceIDRef);
        }

        IOObjectRelease(removedDevice);

        trigger = 0;
        if (logLevel >= LOG_LEVEL_INFO) NSLog(@"Device removed: %"PRIu64" family %d", (uint64_t)deviceID, familyID);
        if (familyIsMagicMouse(familyID)) {
            if (logLevel >= LOG_LEVEL_INFO) NSLog(@"Turning off magic mouse");
            turnOffMagicMouse();
        }
    }
}



#pragma mark - CGEventCallback

static CGEventRef CGEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    if (type >= kCGEventLeftMouseDown && type <= kCGEventRightMouseUp &&
        CGEventGetIntegerValueField(event, kCGEventSourceUserData) == mmSynthMark)
        return event; // a click we posted: none of Jitouch's click rules apply (they could swallow our press)
    if (type == kCGEventLeftMouseDown) {
        double timeInterval = fabs([lastTwoFingerDate timeIntervalSinceNow]);
        bool suppress = trackpadHasTwoFingers || timeInterval < 0.05;
        if (suppress) {
            if (logLevel >= LOG_LEVEL_DEBUG)
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{NSLog(@"Suppressed MouseDown with %d fingers d=%f t=%f", trackpadNFingers, twoFingersDistance, timeInterval);});
            return NULL;
        } else if (logLevel >= LOG_LEVEL_DEBUG)
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{NSLog(@"Did not suppress MouseDown with %d fingers d=%f t=%f", trackpadNFingers, twoFingersDistance, timeInterval);});
    } else if (logLevel >= LOG_LEVEL_DEBUG && type == kCGEventLeftMouseUp) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{NSLog(@"Did not suppress MouseUp with %d fingers d=%f", trackpadNFingers, twoFingersDistance);});
    }

    if (type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown) {

        mmLastClickWall = CFAbsoluteTimeGetCurrent(); // our own clicks returned above
        if (mmDragging) mmHwPress = 1;
        if (isTrackpadRecognizing) {
            cancelRecognition = 1;
            return NULL;
        }
        if (isMMFingerRecognizing)
            cancelRecognition = 1; // a real click means you weren't drawing: cancel, and let the click through
        if (simulating) {   //simulating should be reset when mouseup, but sometimes mouseup doesn't get called
            simulating = 0; //so we have to reset it manually
        }
        NSString *gesture = nil;
        int device = 0;
        if (middleClickFlag) {
            gesture = @"Middle Click";
            device = MAGICMOUSE;
        } else if (trackpadNFingers == 3) {
            trackpadClicked = 1;
            gesture = @"Three-Finger Click";
            device = TRACKPAD;
        } else if (trackpadNFingers == 4) {
            trackpadClicked = 1;
            gesture = @"Four-Finger Click";
            device = TRACKPAD;
        } else if (magicMouseThreeFingerFlag) {
            gesture = @"Three-Finger Click";
            device = MAGICMOUSE;
        }
        if (gesture != nil) {
            NSString *command = commandForGesture(gesture, device);
            if ([command isEqualToString:@"Middle Click"]) {
                simulating = MIDDLEBUTTONDOWN;
                simulatingByDevice = device;
                CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, 2);
                CGEventSetType(event, kCGEventOtherMouseDown);
            } else if ([command isEqualToString:@"Left Click"]) {
                simulating = LEFTBUTTONDOWN;
                CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, 0);
                CGEventSetType(event, kCGEventLeftMouseDown);
            } else if ([command isEqualToString:@"Right Click"]) {
                simulating = RIGHTBUTTONDOWN;
                CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, 1);
                CGEventSetType(event, kCGEventRightMouseDown);
            } else if ([command isEqualToString:@"Open Link in New Tab"]) {
                simulating = COMMANDANDLEFTBUTTONDOWN;
                CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, 0);
                CGEventSetFlags(event, kCGEventFlagMaskCommand);
                CGEventSetType(event, kCGEventLeftMouseDown);
            } else if (command == nil) {
            } else { // command that will be done by this case must not create a new click event
                simulating = IGNOREMOUSE;
                dispatchCommand(gesture, device);
                return NULL;
            }
            if (command != nil && logLevel >= LOG_LEVEL_INFO) NSLog(@"Gesture \"%@\" -> \"%@\" for %@", gesture, command, deviceTypeName[device]);
        }


        if (moveResizeFlag) {
            shouldExitMoveResize = 1;
            return NULL;
        }

    } else if (type == kCGEventLeftMouseUp || type == kCGEventRightMouseUp) {
        if (simulating == MIDDLEBUTTONDOWN) {
            CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, 2);
            CGEventSetType(event, kCGEventOtherMouseUp);
            simulating = 0;
            if (logLevel >= LOG_LEVEL_DEBUG) NSLog(@"Simulated MiddleMouseUp");
        } else if (simulating == LEFTBUTTONDOWN) {
            CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, 0);
            CGEventSetType(event, kCGEventLeftMouseUp);
            simulating = 0;
            if (logLevel >= LOG_LEVEL_DEBUG) NSLog(@"Simulated LeftMouseUp");
        } else if (simulating == RIGHTBUTTONDOWN) {
            CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, 1);
            CGEventSetType(event, kCGEventRightMouseUp);
            simulating = 0;
            if (logLevel >= LOG_LEVEL_DEBUG) NSLog(@"Simulated RightMouseUp");
        } else if (simulating == COMMANDANDLEFTBUTTONDOWN) {
            CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, 0);
            CGEventSetFlags(event, kCGEventFlagMaskCommand);
            CGEventSetType(event, kCGEventLeftMouseUp);
            simulating = 0;
            if (logLevel >= LOG_LEVEL_DEBUG) NSLog(@"Simulated CommandLeftMouseUp");
        } else if (simulating == IGNOREMOUSE) {
            simulating = 0;
            return NULL;
        }

    } else if (type == kCGEventScrollWheel) {
        if (!isMMFingerRecognizing)
            mmLastScrollWall = CFAbsoluteTimeGetCurrent();
        if (magicMouseThreeFingerFlag || isTrackpadRecognizing || isMMFingerRecognizing || mmDragging)
            return NULL;
        else if (autoScrollFlag) {
            int64_t sc = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
            if (sc*autoScrollFlag <= 0)
                return NULL;
        } else if (disableHorizontalScroll)
            CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2, 0);
        else if ((trackpadNFingers == 3 || trackpadNFingers == 4) && simulating == MIDDLEBUTTONDOWN)
            return NULL;
    }
    if (type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged) { // after a drag, log big pointer jumps
        static CGPoint last;
        static int haveLast;
        CGPoint at = CGEventGetLocation(event);
        double since = CFAbsoluteTimeGetCurrent() - mmLastReleaseWall, jump = hypot(at.x - last.x, at.y - last.y);
        if (haveLast && mmDragging != 1 && since < 1.0 && jump > 60) {
            // delta = the hardware's own motion: about equal to the jump means a fast hand, not a warp
            char line[240];
            snprintf(line, sizeof line, "glitch? jumped %.0f px (%.0f,%.0f)->(%.0f,%.0f) delta=(%lld,%lld) pid=%lld synth=%d lift=(%.0f,%.0f), %.0f ms after a drag",
                     jump, last.x, last.y, at.x, at.y,
                     CGEventGetIntegerValueField(event, kCGMouseEventDeltaX), CGEventGetIntegerValueField(event, kCGMouseEventDeltaY),
                     CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID),
                     CGEventGetIntegerValueField(event, kCGEventSourceUserData) == mmSynthMark, mmLiftPtr.x, mmLiftPtr.y, since * 1000);
            mmLogLine(line);
        }
        last = at;
        haveLast = 1;
    }
    if (type == kCGEventMouseMoved) {
        if (quickTabSwitching) {
            selectSafariTab();
        } else if (simulating == MIDDLEBUTTONDOWN) {
            CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, 2);
            CGEventSetType(event, kCGEventOtherMouseDragged);
        } else if (mmDragging == 1) {
            CGEventSetType(event, kCGEventLeftMouseDragged);
            uint64_t ts = CGEventGetTimestamp(event), up = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            uint64_t lat = up > ts ? up - ts : 0;
            if (mmLatN == 0) mmLatMach0 = (int64_t)mach_absolute_time() - (int64_t)ts; // unit sanity check
            mmLatN++; mmLatSumUp += lat; if (lat > mmLatMaxUp) mmLatMaxUp = lat;
        } else {
            mmLastMoveWall = CFAbsoluteTimeGetCurrent();
        }
    } else if (type == kCGEventLeftMouseDragged || type == kCGEventRightMouseDragged) {
        if (simulating == MIDDLEBUTTONDOWN) {
            CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber, 2);
            CGEventSetType(event, kCGEventOtherMouseDragged);
        }
    } else if (type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(eventTap, true);
    } else if (type == kCGEventTapDisabledByTimeout) {
        CGEventTapEnable(eventTap, true); // CGEvent.h: a disabled tap may be re-enabled by calling this function
        if (CGEventTapIsEnabled(eventTap)) return NULL;
        dispatch_async(dispatch_get_main_queue(), ^{ // main: the retry NSTimer needs a running run loop
            if (recreatingEventTap) return;
            recreatingEventTap = TRUE;
            NSLog(@"Received kCGEventTapDisabledByTimeout; attempting to recreate CGEventTap. Allow Jitouch in System Preferences -> Privacy -> Accessibility.");
            CFMachPortInvalidate(eventTap);
            CFRelease(eventTap);
            eventTap = [me createEventTap];
            if (eventTap == nil) {
                NSLog(@"Could not create CGEventTap. Scheduling retries.");
                eventTapTries = 0;
                [NSTimer scheduledTimerWithTimeInterval:1.0 target:me selector:@selector(createEventTapTimer:) userInfo:nil repeats:NO];
            } else {
                recreatingEventTap = FALSE;
            }
        });
        return NULL;
    }



    if (enCharRegMM) {

        CGEventType nType = CGEventGetType(event);
        static int freePass = 0;

        CGEventType mouseDown, mouseUp, mouseDrag;
        if (charRegMouseButton == 0) {
            mouseDown = kCGEventOtherMouseDown;
            mouseUp = kCGEventOtherMouseUp;
            mouseDrag = kCGEventOtherMouseDragged;
        } else if (charRegMouseButton == 1) {
            mouseDown = kCGEventRightMouseDown;
            mouseUp = kCGEventRightMouseUp;
            mouseDrag = kCGEventRightMouseDragged;
        }
        if (!freePass) {
            if (nType == mouseDown) {
                return NULL;
            } else if ((nType == mouseDrag) &&
                       (!simulating || (simulating == MIDDLEBUTTONDOWN && simulatingByDevice != TRACKPAD)))
            {
                CGPoint tmp = CGEventGetLocation(event);

                if (!isMouseRecognizing) {
                    isMouseRecognizing = 1;
                    mouseRecognizer(tmp.x, -tmp.y, 0);
                } else {
                    if (mouseRecognizer(tmp.x, -tmp.y, 1))
                        isMouseRecognizing = 2;
                }
                return NULL;
            } else if (nType == mouseUp) {
                if (isMouseRecognizing == 2) {
                    CGPoint tmp = CGEventGetLocation(event);
                    mouseRecognizer((float)tmp.x, -(float)tmp.y, 2);
                } else {
                    freePass = 1;
                    CGEventRef eventRef;

                    CGEventRef ourEvent = CGEventCreate(NULL);
                    CGPoint location = CGEventGetLocation(ourEvent);
                    CFRelease(ourEvent);

                    if (charRegMouseButton == 0) { // Middle
                        eventRef = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseDown, location, kCGMouseButtonCenter);
                        CGEventSetIntegerValueField(eventRef, kCGMouseEventButtonNumber, 2);
                        CGEventPost(kCGSessionEventTap, eventRef);
                        CFRelease(eventRef);

                        eventRef = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseUp, location, kCGMouseButtonCenter);
                        CGEventPost(kCGSessionEventTap, eventRef);
                        CFRelease(eventRef);
                    } else if (charRegMouseButton == 1) {
                        eventRef = CGEventCreateMouseEvent(NULL, kCGEventRightMouseDown, location, kCGMouseButtonRight);
                        CGEventPost(kCGSessionEventTap, eventRef);
                        CFRelease(eventRef);

                        eventRef = CGEventCreateMouseEvent(NULL, kCGEventRightMouseUp, location, kCGMouseButtonRight);
                        CGEventPost(kCGSessionEventTap, eventRef);
                        CFRelease(eventRef);
                    }
                }
                isMouseRecognizing = 0;
                return NULL;
            }
        } else if (nType == mouseUp)
            freePass = 0;
    }

    return event;
}

- (CFMachPortRef)createEventTap {
    CGEventMask eventMask;
    CFRunLoopSourceRef runLoopSource;

    eventMask = CGEventMaskBit(kCGEventScrollWheel) |
    CGEventMaskBit(kCGEventMouseMoved) |
    CGEventMaskBit(kCGEventLeftMouseDown) |
    CGEventMaskBit(kCGEventLeftMouseUp) |
    CGEventMaskBit(kCGEventRightMouseDown) |
    CGEventMaskBit(kCGEventRightMouseUp) |
    CGEventMaskBit(kCGEventOtherMouseDown) |
    CGEventMaskBit(kCGEventOtherMouseUp) |
    CGEventMaskBit(kCGEventLeftMouseDragged) |
    CGEventMaskBit(kCGEventRightMouseDragged) |
    CGEventMaskBit(kCGEventOtherMouseDragged);
    //CGEventMaskBit(kCGEventKeyUp) |
    //CGEventMaskBit(kCGEventKeyDown);
    CFMachPortRef eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, 0, eventMask, CGEventCallback, NULL);

    if (eventTap != nil) {
        CGEventTapEnable(eventTap, true);
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, kCFRunLoopCommonModes);
    }

    return eventTap;
}

int eventTapTries = 0;

- (void)createEventTapTimer:(NSTimer *)timer {
    CFMachPortRef newEventTap = nil;
    newEventTap = [me createEventTap];
    if (newEventTap == nil) {
        if (logLevel >= LOG_LEVEL_DEBUG) NSLog(@"Could not create CGEventTap (try %d)", eventTapTries);
        eventTapTries++;
        // Keep trying for as long as it takes: Accessibility is often re-allowed long after launch, and a missing
        // tap means drags get no pointer moves (log 16:04: moves=0 on every drag). ponytail: 1 s forever is cheap.
        [NSTimer scheduledTimerWithTimeInterval:(eventTapTries < 360 ? 1.0 : 3.0) target:me selector:@selector(createEventTapTimer:) userInfo:nil repeats:NO];
    } else {
        NSLog(@"CGEventTap created");
        eventTap = newEventTap;
        recreatingEventTap = FALSE;
    }
}

#pragma mark - Init
CFMutableArrayRef deviceList;

- (id)init {
    if (logLevel >= LOG_LEVEL_INFO) NSLog(@"Initializing.");
    if (self = [super init]) {
        me = self;

        systemWideElement = AXUIElementCreateSystemWide();

        lastTwoFingerDate = [NSDate date];
        lastThreeFingerDate = [NSDate date];

        // Character Recognizer
        initNormPdf();
        initChars();

        {
            deviceList = MTDeviceCreateList();
            for (CFIndex i = 0; i < CFArrayGetCount(deviceList); i++) {
                MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(deviceList, i);
                int familyID;
                MTDeviceGetFamilyID(device, &familyID);
                uint64_t deviceID = 0;
                MTDeviceGetDeviceID(device, &deviceID);
                if (logLevel >= LOG_LEVEL_INFO) NSLog(@"Start device %li %"PRIu64" family %d (%s)", (long)i, deviceID, familyID, (MTDeviceIsRunning(device)) ? "running" : "not running");
                if (familyIsBuiltinTrackpad(familyID)) {
                    MTRegisterContactFrameCallback(device, trackpadCallback);
                    MTDeviceStart(device, 0);
                } else if (familyIsMagicMouse(familyID)) {
                    MTRegisterContactFrameCallback(device, magicMouseCallback);
                    MTDeviceStart(device, 0);
                } else if (familyIsMagicTrackpad(familyID)) {
                    MTRegisterContactFrameCallback(device, trackpadCallback);
                    MTDeviceStart(device, 0);
                } else if (familyID >= MINFAMILYID) { // Unknown ID. Assume it's a trackpad.
                    MTRegisterContactFrameCallback(device, trackpadCallback);
                    MTDeviceStart(device, 0);
                }
                if (logLevel >= LOG_LEVEL_INFO) NSLog(@"Device %li %"PRIu64" family %d is %s", (long)i, deviceID, familyID, (MTDeviceIsRunning(device)) ? "running" : "not running");
            }
            //CFRelease((CFMutableArrayRef)deviceList); // DO NOT release. It'll crash.
        }

        /*
        io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, matchingDict);
        if (service) {
            hasMagicMouse = YES;
        }
        */

        IONotificationPortRef notificationObject = IONotificationPortCreate(kIOMasterPortDefault);
        CFRunLoopSourceRef notificationRunLoopSource = IONotificationPortGetRunLoopSource(notificationObject);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), notificationRunLoopSource, kCFRunLoopDefaultMode);

        {
            CFMutableDictionaryRef matchingDict = IOServiceNameMatching("AppleMultitouchDevice");
            matchingDict = (CFMutableDictionaryRef) CFRetain(matchingDict);

            //Device added notification
            io_iterator_t multitouchDeviceAddedIterator;
            IOServiceAddMatchingNotification(notificationObject, kIOFirstMatchNotification, matchingDict, multitouchDeviceAdded, NULL, &multitouchDeviceAddedIterator);
            io_service_t device;
            while ((device = IOIteratorNext(multitouchDeviceAddedIterator))) {
                // Remove existing devices; already added
                IOObjectRelease(device);
            }
            multitouchDeviceAdded(NULL, multitouchDeviceAddedIterator);

            //Device removed notification
            io_iterator_t multitouchDeviceRemovedIterator;
            IOServiceAddMatchingNotification(notificationObject, kIOTerminatedNotification, matchingDict, multitouchDeviceRemoved, NULL, &multitouchDeviceRemovedIterator);
            multitouchDeviceRemoved(NULL, multitouchDeviceRemovedIterator);
        }

        eventTap = [me createEventTap];
        if (eventTap == nil) {
            NSLog(@"Could not create CGEventTap. Allow Jitouch in System Preferences -> Privacy -> Accessibility.");
            recreatingEventTap = TRUE;
            eventTapTries = 0;
            [NSTimer scheduledTimerWithTimeInterval:1.0 target:me selector:@selector(createEventTapTimer:) userInfo:nil repeats:NO];
        }

        gestureWindow = [[GestureWindow alloc] init];
        sizeHistoryDict = [[NSMutableDictionary alloc] init];

        keyUtil = [[KeyUtility alloc] init];
    }
    return self;
}

- (void)reload {
    if (logLevel >= LOG_LEVEL_INFO) NSLog(@"Reloading gestures.");
    for (CFIndex i = 0; i < CFArrayGetCount(deviceList); i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(deviceList, i);
        int familyID;
        MTDeviceGetFamilyID(device, &familyID);
        uint64_t deviceID = 0;
        MTDeviceGetDeviceID(device, &deviceID);
        if (logLevel >= LOG_LEVEL_INFO) NSLog(@"Stop device %li %"PRIu64" family %d (%s)", (long)i, deviceID, familyID, (MTDeviceIsRunning(device)) ? "running" : "not running");
        if (familyID >= MINFAMILYID) {
            MTUnregisterContactFrameCallback(device, trackpadCallback);
            MTUnregisterContactFrameCallback(device, magicMouseCallback);
            MTDeviceStop(device);
        }
        if (logLevel >= LOG_LEVEL_INFO) NSLog(@"Device %li %"PRIu64" family %d is %s", (long)i, deviceID, familyID, (MTDeviceIsRunning(device)) ? "running" : "not running");
    }
    CFRelease(deviceList);
    sleep(1);
    deviceList = MTDeviceCreateList();
    for (CFIndex i = 0; i < CFArrayGetCount(deviceList); i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(deviceList, i);
        int familyID;
        MTDeviceGetFamilyID(device, &familyID);
        uint64_t deviceID = 0;
        MTDeviceGetDeviceID(device, &deviceID);
        if (logLevel >= LOG_LEVEL_INFO) NSLog(@"Start device %li %"PRIu64", family %d (%s)", (long)i, deviceID, familyID, (MTDeviceIsRunning(device)) ? "running" : "not running");
        if (familyIsBuiltinTrackpad(familyID)) {
            MTRegisterContactFrameCallback(device, trackpadCallback);
            MTDeviceStart(device, 0);
        } else if (familyIsMagicMouse(familyID)) {
            MTRegisterContactFrameCallback(device, magicMouseCallback);
            MTDeviceStart(device, 0);
        } else if (familyIsMagicTrackpad(familyID)) {
            MTRegisterContactFrameCallback(device, trackpadCallback);
            MTDeviceStart(device, 0);
        } else if (familyID >= MINFAMILYID) { // Unknown ID. Assume it's a trackpad.
            MTRegisterContactFrameCallback(device, trackpadCallback);
            MTDeviceStart(device, 0);
        }
        if (logLevel >= LOG_LEVEL_INFO) NSLog(@"Device %li %"PRIu64" family %d is %s", (long)i, deviceID, familyID, (MTDeviceIsRunning(device)) ? "running" : "not running");
    }
}

#pragma mark - Character Recognizer

static void initNormPdf() {
    float mn = 10, mx = -1;
    float lo = 0.5, hi = 1;
    for (int i = -100; i <= 100; i++) {
        normPdf[i + 100] = 1 / sqrt(2*PI*0.3*0.3) * exp(-(i/100.0) * (i/100.0) / (2*0.3*0.3));
        if (normPdf[i + 100] < mn)
            mn = normPdf[i + 100];
        if (normPdf[i + 100] > mx)
            mx = normPdf[i + 100];
    }
    for (int i = -100; i <= 100; i++) {
        normPdf[i + 100] = (normPdf[i + 100] - mn) * (hi - lo) / (mx - mn) + lo;
    }

    mn = 10; mx = -1;
    lo = 0.1; hi = 1.5;
    for (int i = -100; i <= 100; i++) {
        normIPdf[i + 100] = 1 / sqrt(2*PI*0.3*0.3) * exp(-(i/100.0) * (i/100.0) / (2*0.3*0.3));
        if (normIPdf[i + 100] < mn)
            mn = normIPdf[i + 100];
        if (normIPdf[i + 100] > mx)
            mx = normIPdf[i + 100];
    }
    for (int i = -100; i <= 100; i++) {
        normIPdf[i + 100] = (normIPdf[i + 100] - mn) * (hi - lo) / (mx - mn) + lo;
    }
}

static float getScore(const float *pdf, float input, float deg, float span) {
    for (int i = -1; i <= 1; i++) {
        if (input + 2*PI*i >= deg-span && input + 2*PI*i <= deg + span)
            return pdf[(int)(100 + ((input + 2*PI*i - deg) / span) * 100)];
    }
    return 0;
}

static void setDegreeSpan(DegreeSpan *ds, float deg, float span) {
    ds->deg = deg * PI / 180.0f;
    ds->span = span * PI / 180.0f;
}

static void initChars() {
    int c2 = 0;
    nChars = 0;

    chars[nChars].ch = "A";
    setDegreeSpan(&chars[nChars].ds[c2++], 65, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -65, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "B";
    setDegreeSpan(&chars[nChars].ds[c2++], 90, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -45, 50);
    setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
    /*setDegreeSpan(&chars[nChars].ds[c2++], 0, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -90, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], 180, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], 0, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -90, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], 180, 30);*/
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "C";
    setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -0, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "D";
    setDegreeSpan(&chars[nChars].ds[c2++], 90, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -45, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -135, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "E";
    setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "F";
    setDegreeSpan(&chars[nChars].ds[c2++], -180, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -90, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "G";
    setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 45, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 180, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "H";
    setDegreeSpan(&chars[nChars].ds[c2++], -90, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], 90, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 0, 60);
    //setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -90, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "Down";
    setDegreeSpan(&chars[nChars].ds[c2++], -90, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "Up";
    setDegreeSpan(&chars[nChars].ds[c2++], 90, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;
    /*
     chars[nChars].ch = "Down-Up";
     setDegreeSpan(&chars[nChars].ds[c2++], -90, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], 90, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;

     chars[nChars].ch = "Up-Down";
     setDegreeSpan(&chars[nChars].ds[c2++], 90, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], -90, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;*/
    chars[nChars].ch = "Y";
    setDegreeSpan(&chars[nChars].ds[c2++], -60, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 60, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -120, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "J";
    setDegreeSpan(&chars[nChars].ds[c2++], -90, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], 170, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "K";
    setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 90, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "L";
    setDegreeSpan(&chars[nChars].ds[c2++], -90, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], 0, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "M";
    setDegreeSpan(&chars[nChars].ds[c2++], 60, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -60, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 60, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -60, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "N";
    setDegreeSpan(&chars[nChars].ds[c2++], 90, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -60, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 90, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "O";
    setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -60, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 60, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 135, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "P";
    setDegreeSpan(&chars[nChars].ds[c2++], 90, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -45, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -135, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "Q";
    setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -60, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 60, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 110, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -60, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "R";
    setDegreeSpan(&chars[nChars].ds[c2++], 90, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "S";
    setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 180, 50);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "T";
    setDegreeSpan(&chars[nChars].ds[c2++], 0, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -90, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "U";
    setDegreeSpan(&chars[nChars].ds[c2++], -90, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], 0, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], 90, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "V";
    setDegreeSpan(&chars[nChars].ds[c2++], -60, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 60, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "W";
    setDegreeSpan(&chars[nChars].ds[c2++], -60, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 60, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -60, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 60, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "X";
    setDegreeSpan(&chars[nChars].ds[c2++], 45, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 180, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;



    chars[nChars].ch = "Z";
    setDegreeSpan(&chars[nChars].ds[c2++], 0, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 0, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;
    /*
     chars[nChars].ch = "1";
     setDegreeSpan(&chars[nChars].ds[c2++], 45, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -90, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;

     chars[nChars].ch = "2";
     setDegreeSpan(&chars[nChars].ds[c2++], 45, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], 0, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;

     chars[nChars].ch = "3";
     setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;

     chars[nChars].ch = "4";
     setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], 0, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], 135, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -90, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;


     chars[nChars].ch = "5";
     setDegreeSpan(&chars[nChars].ds[c2++], 180, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], -90, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], 135, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;

     chars[nChars].ch = "6";
     setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], 45, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], 135, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;

     chars[nChars].ch = "7";
     setDegreeSpan(&chars[nChars].ds[c2++], 0, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;

     chars[nChars].ch = "8";
     setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], 135, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], 45, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], 135, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;

     chars[nChars].ch = "9";
     setDegreeSpan(&chars[nChars].ds[c2++], 135, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -135, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -45, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], 45, 30);
     setDegreeSpan(&chars[nChars].ds[c2++], -90, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;

     chars[nChars].ch = "Up";
     setDegreeSpan(&chars[nChars].ds[c2++], 90, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;
     */

    chars[nChars].ch = "Left";
    setDegreeSpan(&chars[nChars].ds[c2++], 180, 35);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "Right";
    setDegreeSpan(&chars[nChars].ds[c2++], 0, 35);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "Left-Right";
    setDegreeSpan(&chars[nChars].ds[c2++], 180, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 0, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "Right-Left";
    setDegreeSpan(&chars[nChars].ds[c2++], 0, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], 180, 30);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

     chars[nChars].ch = "/ Down";
     setDegreeSpan(&chars[nChars].ds[c2++], -120, 25);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;

     chars[nChars].ch = "/ Up";
     setDegreeSpan(&chars[nChars].ds[c2++], 60, 25);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;


     chars[nChars].ch = "\\ Down";
     setDegreeSpan(&chars[nChars].ds[c2++], -60, 25);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;

     chars[nChars].ch = "\\ Up";
     setDegreeSpan(&chars[nChars].ds[c2++], 120, 25);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;


    chars[nChars].ch = "Up-Left";
    setDegreeSpan(&chars[nChars].ds[c2++], 90, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], 180, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "Up-Right";
    setDegreeSpan(&chars[nChars].ds[c2++], 90, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], 0, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "Left-Up";
    setDegreeSpan(&chars[nChars].ds[c2++], 180, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], 90, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;

    chars[nChars].ch = "Right-Up";
    setDegreeSpan(&chars[nChars].ds[c2++], 0, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], 90, 20);
    setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
    nChars++; c2 = 0;
    /*
     chars[nChars].ch = "Down-Left";
     setDegreeSpan(&chars[nChars].ds[c2++], -90, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], 180, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;
     */
    /*
     chars[nChars].ch = "[RUL]";
     setDegreeSpan(&chars[nChars].ds[c2++], 0, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], 90, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], 180, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;

     chars[nChars].ch = "[RUD]";
     setDegreeSpan(&chars[nChars].ds[c2++], 0, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], 90, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], -90, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;

     chars[nChars].ch = "[RUR]";
     setDegreeSpan(&chars[nChars].ds[c2++], 0, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], 90, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], 0, 20);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;
     */
    /*
     int i, j;
     for (i = nChars-1; i >= 0; i--) {
     chars[nChars].ch = chars[i].ch + 'a' - 'A';
     for (j = 0; chars[i].ds[j].span > 0; j++);

     for (j--; j >= 0; j--)
     setDegreeSpan(&chars[nChars].ds[c2++], chars[i].ds[j].deg > 0?chars[i].ds[j].deg*180/pi-180:chars[i].ds[j].deg*180/pi + 180, chars[i].ds[j].span*180/pi);
     setDegreeSpan(&chars[nChars].ds[c2++], -1, -1);
     nChars++; c2 = 0;
     }

     */
}

static void advanceStep(float deg) {
    float highestScore = -1e5;
    for (int i = 0; i < nChars; i++) {
        if (chars[i].ds[chars[i].step].span > 0) {
            float lo = chars[i].ds[chars[i].step].deg - chars[i].ds[chars[i].step].span;
            float hi = chars[i].ds[chars[i].step].deg + chars[i].ds[chars[i].step].span;

            if (lo < - PI)
                lo += 2*PI;
            if (hi > PI)
                hi -= 2*PI;

            if ((lo < hi && deg >= lo && deg <= hi) ||
                 (lo > hi && (deg >= lo || deg <= hi)))
                chars[i].step++;
        }
        if (chars[i].step > 0) {
            chars[i].score += getScore(normPdf, deg, chars[i].ds[chars[i].step-1].deg, chars[i].ds[chars[i].step-1].span);
            float penalty = getScore(normIPdf, deg,
                                     chars[i].ds[chars[i].step-1].deg > 0 ? chars[i].ds[chars[i].step-1].deg-PI : chars[i].ds[chars[i].step-1].deg+PI,
                                     PI - chars[i].ds[chars[i].step-1].span);
            if (chars[i].ds[chars[i].step].span < 0)
                chars[i].score -= 2 * penalty;
            else
                chars[i].score -= penalty;

        } else {
            chars[i].score -= getScore(normIPdf, deg,
                                       chars[i].ds[0].deg > 0 ? chars[i].ds[0].deg-PI : chars[i].ds[0].deg+PI, PI - chars[i].ds[0].span);
        }
        if (chars[i].score > highestScore)
            highestScore = chars[i].score;

    }
    if (highestScore < -5) {
        cancelRecognition = 1;
    }
}

static const char *finalizeStep(float x1, float y1, float x2, float y2, float top, float bottom, float left, float right) {
    int out = -1;
    if (top == bottom)
        top = bottom + 1e-8;
    if (right == left)
        right = left + 1e-8;
    for (int i = 0; i < nChars; i++) {
        if (strcmp(chars[i].ch, "H") == 0 && out != -1 && strcmp(chars[out].ch, "B") == 0)
            continue;

        if (strcmp(chars[i].ch, "J") == 0 && out != -1 && strcmp(chars[out].ch, "Y") == 0)
            continue;

        if ((strcmp(chars[i].ch, "D") == 0 && (y2-y1)/(top-bottom) > 0.2) ||
           (strcmp(chars[i].ch, "P") == 0 && (y2-y1)/(top-bottom) < 0.2))
            continue;

        if (strcmp(chars[i].ch, "N") == 0 && (y2-y1)/(top-bottom) < 0.3)
            continue;

        if (strcmp(chars[i].ch, "Y") == 0 && (y1-y2)/(top-bottom) < 0.5)
            continue;

        if ((strcmp(chars[i].ch, "O") == 0 && (y2-y1)/(top-bottom) < -0.2) ||
           (strcmp(chars[i].ch, "G") == 0 && (y2-y1)/(top-bottom) > -0.2))
            continue;

        if ((strcmp(chars[i].ch, "T") == 0 ||
           strcmp(chars[i].ch, "F") == 0 ||
           strcmp(chars[i].ch, "Left-Up") == 0 ||
            strcmp(chars[i].ch, "Right-Up") == 0) && (top-bottom)/(right-left) < 0.2)
            continue;

        if ((strcmp(chars[i].ch, "L") == 0 ||
            strcmp(chars[i].ch, "Up-Left") == 0 ||
            strcmp(chars[i].ch, "Up-Right") == 0) && (right-left)/(top-bottom) < 0.2)
            continue;

        /*if ((strcmp(chars[i].ch, "L") == 0 ||
            strcmp(chars[i].ch, "") == 0 ||
            strcmp(chars[i].ch, "Right-Up") == 0 ||
            strcmp(chars[i].ch, "Left-Up") == 0) && (top-bottom)/(right-left) < 0.2)
            continue;
        */
        if (chars[i].ds[chars[i].step].span < 0 && (out == -1 || chars[i].score > chars[out].score))
            out = i;
    }
    /*
     if (chars[out].ch[0] == 'N') {
     CGPostKeyboardEvent((CGCharCode)0, (CGKeyCode)55, true );
     CGPostKeyboardEvent((CGCharCode)0, (CGKeyCode)45, true );
     CGPostKeyboardEvent((CGCharCode)0, (CGKeyCode)45, false );
     CGPostKeyboardEvent((CGCharCode)0, (CGKeyCode)55, false );
     } else if (chars[out].ch[0] == 'S') {
     CGPostKeyboardEvent((CGCharCode)0, (CGKeyCode)55, true );
     CGPostKeyboardEvent((CGCharCode)0, (CGKeyCode)1, true );
     CGPostKeyboardEvent((CGCharCode)0, (CGKeyCode)1, false );
     CGPostKeyboardEvent((CGCharCode)0, (CGKeyCode)55, false );
     } else if (chars[out].ch[0] == 'O') {
     CGPostKeyboardEvent((CGCharCode)0, (CGKeyCode)55, true );
     CGPostKeyboardEvent((CGCharCode)0, (CGKeyCode)31, true );
     CGPostKeyboardEvent((CGCharCode)0, (CGKeyCode)31, false );
     CGPostKeyboardEvent((CGCharCode)0, (CGKeyCode)55, false );
     }*/
    if (out == -1 || chars[out].score < 0)
        return "?";
    return chars[out].ch;
}

static void clearStep() {
    for (int i = 0; i < nChars; i++) {
        chars[i].step = 0;
        chars[i].score = 0;
    }
}

static float hint_firstPos[2], hint_x, hint_y, hint_top, hint_bottom, hint_left, hint_right;
static const float hintWaitTime = 0.3f;
static const char *emptyString = "";

- (void)showHintTimer:(NSTimer *)aTimer {
    [gestureWindow setHintText: finalizeStep(hint_firstPos[0], hint_firstPos[1], hint_x, hint_y, hint_top, hint_bottom, hint_left, hint_right)];
}

static int mouseRecognizer(float x, float y, int step) {
    static NSTimer *timer = nil;

    static float lpos[2];
    static const float dst = 5;

    static float firstPos[2];
    static float top, bottom, left, right;

    static int distCounter = 0;
    int returnValue = 0;
    if (step == 0) {
        @autoreleasepool {
            lpos[0] = x;
            lpos[1] = y;
            firstPos[0] = lpos[0];
            firstPos[1] = lpos[1];
            clearStep();
            top = -10000;
            bottom = 10000;
            left = 10000;
            right = -10000;
            distCounter = 0;

            dispatch_async(dispatch_get_main_queue(), ^{
                [gestureWindow setHintText: emptyString];
                [gestureWindow setUpWindowForMagicMouse];
                [gestureWindow addRelativePointX:x-firstPos[0] Y:y-firstPos[1]];
            });
        };

    } else if (step == 1 && !cancelRecognition) {
        if (y > top)
            top = y;
        if (y < bottom)
            bottom = y;
        if (x > right)
            right = x;
        if (x < left)
            left = x;
        if (lenSqr(lpos[0], lpos[1], x, y) > dst) {
            @autoreleasepool {
                float deg = atan2(y - lpos[1], x - lpos[0]);
                advanceStep(deg);
                lpos[0] = x;
                lpos[1] = y;

                [gestureWindow addRelativePointX:x-firstPos[0] Y:y-firstPos[1]];

                if (distCounter >= 0) {
                    distCounter++;
                    if (distCounter >= 3) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [gestureWindow display];
                            [gestureWindow setLevel:NSScreenSaverWindowLevel];
                            [gestureWindow makeKeyAndOrderFront:nil];
                        });
                        distCounter = -1;
                        returnValue = 1;
                    }
                }
                if (timer != nil) {
                    if ([timer isValid])
                        [timer invalidate];
                    [timer release];
                    timer = nil;
                }
                timer = [[NSTimer scheduledTimerWithTimeInterval:(hintWaitTime)
                                                          target:me
                                                        selector:@selector(showHintTimer:)
                                                        userInfo:nil
                                                         repeats:NO] retain];
                hint_firstPos[0] = firstPos[0];
                hint_firstPos[1] = firstPos[1];
                hint_x = x;
                hint_y = y;
                hint_top = top;
                hint_bottom = bottom;
                hint_left = left;
                hint_right = right;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [gestureWindow setHintText: emptyString];
                });
            };
        }
    } else if (step == 2 || cancelRecognition) {
        cancelRecognition = 0;
        @autoreleasepool {
            dispatch_async(dispatch_get_main_queue(), ^{
                [gestureWindow clear];
                [gestureWindow orderOut:nil];
            });
        };
        if (!cancelRecognition) {
            NSString *commandString = [[NSString alloc] initWithUTF8String:finalizeStep(firstPos[0], firstPos[1], x, y, top, bottom, left, right)];
            dispatchCommand(commandString, CHARRECOGNITION);
            [commandString release];
        }

        if (timer != nil) {
            if ([timer isValid])
                [timer invalidate];
            [timer release];
            timer = nil;
        }
    }
    return returnValue;
}

static void trackpadRecognizerOne(const Finger *data, int nFingers, double timestamp) {
    static float lpos[2];
    static int step = 0;
    static const float dst = 0.0002;

    static float firstPos[2];
    static float top, bottom, left, right;
    static double sttime = -1;
    static float fing[2][2];
    static int fixId;

    static double hintTime;
    static CGFloat mx, my;

    if (step == 0 && nFingers == 1) {
        step = 1;
        fixId = data[0].identifier;
        sttime = -1;
    } else if (step == 1 && nFingers == 2) {
        if (nFingers == 2) {
            if (fabs(data[0].px-data[1].px) > charRegIndexRingDistance && fabs(data[0].py-data[1].py)< 0.5 && fabs(data[0].px-data[1].px) < 0.65 &&
               !CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft)) {
                if (sttime < 0)
                    sttime = timestamp;
                if ((data[0].identifier == fixId || data[0].size > stvt / 10) &&
                   (data[1].identifier == fixId || data[1].size > stvt / 10)) {
                    step = 2;

                    fing[0][0] = data[0].px;
                    fing[0][1] = data[0].py;
                    fing[1][0] = data[1].px;
                    fing[1][1] = data[1].py;
                }
            } else
                step = 0;
        } else if (nFingers == 1) {
            sttime = -1;
            fixId = data[0].identifier;
        } else
            step = 0;

    } else if (step == 2) {
        if (nFingers == 1) {
            if (timestamp - sttime > clickSpeed || (isTrackpadRecognizing > 0 && isTrackpadRecognizing != 1)) {
                step = 0;
            } else {
                @autoreleasepool {
                    getMousePosition(&mx, &my);

                    step = 3;
                    isTrackpadRecognizing = 1;
                    lpos[0] = data[0].px;
                    lpos[1] = data[0].py;
                    firstPos[0] = lpos[0];
                    firstPos[1] = lpos[1];

                    clearStep();
                    top = 0;
                    bottom = 1;
                    left = 1;
                    right = 0;

                    dispatch_async(dispatch_get_main_queue(), ^{
                        [gestureWindow setHintText: emptyString];
                        [gestureWindow setUpWindowForTrackpad];
                        [gestureWindow addPointX:data[0].px Y:data[0].py];
                        [gestureWindow display];
                        [gestureWindow setLevel:NSScreenSaverWindowLevel];
                        [gestureWindow makeKeyAndOrderFront:nil];
                    });

                    step = 3;
                }
            }
        } else if (nFingers == 2) {
            if (lenSqr(data[0].px, data[0].py, fing[0][0], fing[0][1]) > 0.001 || lenSqr(data[1].px, data[1].py, fing[1][0], fing[1][1]) > 0.001)
                step = 0;
        } else {
            step = 0;
        }

    } else if (step == 3) {
        if (nFingers != 1 || cancelRecognition) {
            step = 0;
            @autoreleasepool {
                mouseClick(8, mx, my);
                if (!cancelRecognition && nFingers == 0) {
                    NSString *commandString = [[NSString alloc] initWithUTF8String:finalizeStep(firstPos[0], firstPos[1], lpos[0], lpos[1], top, bottom, left, right)];
                    dispatchCommand(commandString, CHARRECOGNITION);
                    [commandString release];
                }
                cancelRecognition = 0;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [gestureWindow clear];
                    [gestureWindow orderOut:nil];
                });
            }
            isTrackpadRecognizing = 0;
        } else {
            if (hintTime > 0 && timestamp - hintTime >= hintWaitTime) {
                [gestureWindow setHintText: finalizeStep(firstPos[0], firstPos[1], lpos[0], lpos[1], top, bottom, left, right)];
                hintTime = -1;
            }

            if (data[0].py > top)
                top = data[0].py;
            if (data[0].py < bottom)
                bottom = data[0].py;
            if (data[0].px > right)
                right = data[0].px;
            if (data[0].px < left)
                left = data[0].px;
            if (lenSqr(lpos[0], lpos[1], data[0].px, data[0].py) > dst) {
                float deg = atan2(data[0].py - lpos[1], data[0].px - lpos[0]);
                advanceStep(deg);
                @autoreleasepool {
                    lpos[0] = data[0].px;
                    lpos[1] = data[0].py;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [gestureWindow addPointX:data[0].px Y:data[0].py];
                    });
                }
                hintTime = timestamp;
                [gestureWindow setHintText: emptyString];
            }

            mouseClick(8, 10000, 10000);
        }
    }
}

// Magic Mouse fingertip drawing: tap once, put the finger back down, draw, lift. Letters can take several strokes:
// after a lift the recognizer waits strokeGap for another stroke before it reads the letter.
// One stroke goes to Jitouch's own direction recognizer; two or more go to the $P point-cloud recognizer.
// Coordinates are the finger's normalized position on the mouse surface (0..1), same as the trackpad path.
#define MM_MAX_POINTS 2048
static int mmStep = 0, mmShown = 0, mmStrokes = 0, mmGen = 0, mmNPts = 0;
static PDPoint mmPts[MM_MAX_POINTS];
static float mmFirst[2], mmLast[2], mmTop, mmBottom, mmLeft, mmRight; // stroke 1 only, for Jitouch's recognizer
static const double strokeGap = 0.5;   // recorded multi-stroke F: 0.2-0.38 s between strokes
static const float pdollarMaxScore = 2.0f; // ponytail: real F (own templates) 0.68-1.07, built-ins 1.4-1.7; raise if real letters read as nothing
// One-stroke drawings are first matched against your trained handwriting; this is how close a match must be.
// Calibrated 2026-11-10: your trained letters scored at most 0.85 (leave-one-out); the closest recorded scroll
// stroke scored 2.32. tests/run.sh re-checks both against your current letters.txt on every build.
static const float personalMaxScore = 1.5f;
static const double scrollQuiet = 0.4;      // no system scroll this long before a tap, or it's part of scrolling
// A lift shorter than mergeGap that lands within mergeDist of where it left is contact loss, not a new stroke.
// Recorded deliberate re-placements always landed 0.1-0.35 away; slips came back 0.01-0.02 away.
static const double mergeGap = 0.2;
static const float mergeDist = 0.04f;
// One straight line is exactly what a scroll looks like, so on the mouse these never fire (trackpad unaffected).
static const char *mmScrollLike[] = {"Up", "Down", "Left", "Right", "/ Up", "/ Down", "\\ Up", "\\ Down",
                                     "Up-Down", "Down-Up", "Left-Right", "Right-Left", NULL};

static int mmButtonDown(void) {
#ifdef JITOUCH_TEST
    return jtTestButtonDown;
#else
    return CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft) ||
           CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonRight);
#endif
}

// Every stroke straight and pointing along the same axis = a run of scroll flicks, not a letter.
static int mmParallelFlicks(void) {
    float ax[64], ay[64];
    int n = 0;
    for (int i = 0, j; i < mmNPts && n < 64; i = j) {
        float path = 0;
        for (j = i + 1; j < mmNPts && mmPts[j].stroke == mmPts[i].stroke; j++)
            path += hypotf(mmPts[j].x - mmPts[j - 1].x, mmPts[j].y - mmPts[j - 1].y);
        float dx = mmPts[j - 1].x - mmPts[i].x, dy = mmPts[j - 1].y - mmPts[i].y, d = hypotf(dx, dy);
        if (d < 1e-4f) continue;          // a dot, not a stroke
        if (d < 0.85f * path) return 0;   // a curved stroke: letter-like
        ax[n] = dx / d; ay[n] = dy / d; n++;
    }
    for (int a = 1; a < n; a++)
        if (fabsf(ax[0] * ax[a] + ay[0] * ay[a]) < 0.9f) return 0; // more than ~25 degrees apart
    return n > 1;
}

// Every finished drawing (fired or not) and every refused tap goes to ~/Library/Logs/Jitouch-gestures.log,
// so a false trigger or a gesture that didn't fire can be diagnosed without recording anything.
static void mmLogLine(const char *line) {
#ifndef JITOUCH_TEST
    const char *path = [[@"~/Library/Logs/Jitouch-gestures.log" stringByExpandingTildeInPath] fileSystemRepresentation];
    struct stat st;
    FILE *f = fopen(path, (stat(path, &st) == 0 && st.st_size > 1024 * 1024) ? "w" : "a"); // ponytail: 1 MB cap, starts over
    if (!f) return;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    char ts[32];
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&tv.tv_sec));
    fprintf(f, "%s.%03d %s\n", ts, (int)(tv.tv_usec / 1000), line);
    fclose(f);
#endif
}

static void mmLog(const char *what, const char *letter, float score) {
#ifdef JITOUCH_TRACE
    printf("   %s %s (strokes %d, score %.2f)\n", what, letter ? letter : "-", mmStrokes, score);
#endif
    char line[160];
    snprintf(line, sizeof line, "%s %s strokes=%d score=%.2f", what, letter ? letter : "-", mmStrokes, score);
    mmLogLine(line);
}
// The sensor is 10 columns x 15 rows (MultitouchSupport reports it), so one normalized unit across the mouse is
// physically shorter than one along it. $P compares shapes, so x is scaled to make strokes physically proportioned.
static const float pdollarAspectX = 10.0f / 15.0f;
static pthread_mutex_t mmLock = PTHREAD_MUTEX_INITIALIZER;

static void mmEnd(int recognize) { // call with mmLock held
    if (recognize && mmShown) {
        const char *letter = NULL, *why = NULL;
        float score = 0;
        if (mmStrokes == 1 && (letter = pdollarRecognize(mmPts, mmNPts, personalMaxScore, &score, 1))) {
            // matched your own trained handwriting closely: that wins over the built-in direction templates
        } else if (mmStrokes == 1 && pdollarUserTemplateCount() > 0) {
            // You've trained your letters, so a one-stroke drawing that matches none of them isn't a letter.
            // (Jitouch's built-in shapes fired on casual scrolls: "Up-Left" and a one-stroke "F", log of 2026-11-10.)
            why = "rejected-no-personal-match";
        } else if (mmStrokes == 1) {
            letter = finalizeStep(mmFirst[0], mmFirst[1], mmLast[0], mmLast[1], mmTop, mmBottom, mmLeft, mmRight);
            for (int i = 0; mmScrollLike[i]; i++)
                if (strcmp(letter, mmScrollLike[i]) == 0) why = "rejected-scroll-like";
        } else if (mmParallelFlicks()) {
            why = "rejected-parallel-flicks";
        } else {
            letter = pdollarRecognize(mmPts, mmNPts, pdollarMaxScore, &score, 0);
            if (!letter) why = "rejected-no-match";
        }
        if (!why && (!letter || strcmp(letter, "?") == 0)) why = "rejected-no-match";
        mmLog(why ? why : "fired", letter, score);
        if (!why) {
            NSString *commandString = [[NSString alloc] initWithUTF8String:letter];
            dispatchCommand(commandString, CHARRECOGNITION);
            [commandString release];
        }
    }
    if (mmShown) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [gestureWindow clear];
            [gestureWindow orderOut:nil];
        });
    }
    mmShown = 0;
    cancelRecognition = 0;
    isMMFingerRecognizing = 0;
    mmStep = 0;
    mmGen++;
}

#ifdef JITOUCH_TEST
static CGPoint jtTestPointer;
#endif
static CGPoint mmPointer(void) {
#ifdef JITOUCH_TEST
    return jtTestPointer;
#endif
    CGEventRef here = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(here);
    CFRelease(here);
    return p;
}

static void mmPost(CGEventType type, CGPoint at, CGMouseButton button, int clickState) {
    CGEventRef e = CGEventCreateMouseEvent(NULL, type, at, button);
    CGEventSetIntegerValueField(e, kCGMouseEventClickState, clickState);
    CGEventSetIntegerValueField(e, kCGEventSourceUserData, mmSynthMark);
    CGEventPost(kCGSessionEventTap, e);
    CFRelease(e);
}

static void mmPostClick(CGEventType down, CGEventType up, CGMouseButton button, int clickState) {
    CGPoint at = mmPointer();
    mmPost(down, at, button, clickState);
    mmPost(up, at, button, clickState);
}

static void mmRightClick(void) {
#ifdef JITOUCH_TEST
    jtTestRecognized = @"Right Click";
    return;
#endif
    mmPostClick(kCGEventRightMouseDown, kCGEventRightMouseUp, kCGMouseButtonRight, 1);
}

static double mmLastClickT = -100; // touch time of the last single tap-click
static int mmLeftClick(double downAt, double now) { // a tap that lands soon after the last tap-click is a double click
    int state = downAt - mmLastClickT <= [NSEvent doubleClickInterval] ? 2 : 1;
    mmLastClickT = state == 2 ? -100 : now;
#ifdef JITOUCH_TEST
    jtTestRecognized = state == 2 ? @"Double Click" : @"Click";
    return state;
#endif
    mmPostClick(kCGEventLeftMouseDown, kCGEventLeftMouseUp, kCGMouseButtonLeft, state);
    return state;
}

static void mmDragRelease(void) { // call with mmLock held
    mmDragging = 0;
    mmLastReleaseWall = CFAbsoluteTimeGetCurrent();
    mmStep = 0;
    char line[200];
    snprintf(line, sizeof line, "drag: mouse up (moves=%llu wait avg=%.1fms max=%.1fms; mach-diff=%lld)", mmLatN,
             mmLatN ? mmLatSumUp / 1e6 / mmLatN : 0.0, mmLatMaxUp / 1e6, mmLatMach0);
    mmLogLine(line);
    mmLatN = mmLatSumUp = mmLatMaxUp = 0;
    mmHwPress = 0;
#ifdef JITOUCH_TEST
    jtTestRecognized = @"Drag released";
#else
    CGPoint now = mmPointer();
    snprintf(line, sizeof line, "drag: up at lift=(%.0f,%.0f) pointer=(%.0f,%.0f) gap=%.0f px",
             mmLiftPtr.x, mmLiftPtr.y, now.x, now.y, hypot(now.x - mmLiftPtr.x, now.y - mmLiftPtr.y));
    mmLogLine(line);
    mmPost(kCGEventLeftMouseUp, mmLiftPtr, kCGMouseButtonLeft, 1); // drop exactly where you let go
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        CGPoint p = mmPointer(); // if this equals the lift point, posting the up moved the cursor
        char l2[100];
        snprintf(l2, sizeof l2, "drag: pointer 30 ms after up=(%.0f,%.0f)", p.x, p.y);
        mmLogLine(l2);
    });
#endif
}

// A real button press took over during our drag: its own mouse-up ends the press, so post nothing.
static void mmDragAbandon(void) { // call with mmLock held
    mmDragging = 0;
    mmStep = 0;
    mmHwPress = 0;
    mmLastReleaseWall = CFAbsoluteTimeGetCurrent();
    mmLogLine("drag: real click took over");
}

// Let go of a finger-drag now (quit, SIGTERM, Jitouch turned off). Any thread; mmLock must NOT be held.
void mmForceRelease(void) {
    pthread_mutex_lock(&mmLock);
    if (mmDragging) {
        mmLiftPtr = mmPointer();
        mmLogLine("drag: released because Jitouch is quitting or turned off");
        mmDragRelease();
    }
    pthread_mutex_unlock(&mmLock);
}

// Frames can pause ~0.9 s with a finger still down (recorded-use-touches2.log 113.744 -> 114.618), and a 0.3 s
// limit dropped a held drag (log 15:28:49). Every recorded lift sent a 0-finger frame, so this only needs to
// catch a dead device (sleep, disconnect, Jitouch turned off): be patient.
static void mmDragWatchdog(int gen) {
#ifndef JITOUCH_TEST
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        pthread_mutex_lock(&mmLock);
        if (mmStep == 5 && mmDragging == 1 && gen == mmGen) {
            if (mmHwPress) {
                mmDragAbandon();
            } else if (CFAbsoluteTimeGetCurrent() - mmLastFrameWall > 2.0) {
                mmLiftPtr = mmPointer();
                mmLogLine("drag: touch frames stopped, released");
                mmDragRelease();
            } else {
                mmDragWatchdog(gen);
            }
        }
        pthread_mutex_unlock(&mmLock);
    });
#endif
}

static void magicMouseFingerRecognizer(const Finger *data, int nFingers, double timestamp) {
    // ponytail: calibration knobs. The mouse surface is narrower than it is long, so letters can read squished;
    // raise mmAspect above 1 if wide letters (M, W) misrecognize. tapMoveMax = how far a "tap" may wander.
    static const float mmAspect = 1.0f;
    static const float tapMoveMax = 0.0008f; // measured deliberate taps moved at most 0.0003
    // A quick still touch is a click. Taps measured in real use last 0.09-0.29 s (logs of 2026-11-10).
    static const double tapMaxHold = 0.35;
    // Held still armTime..armMax, a touch arms a letter (a dot appears): draw without lifting. Still longer is a
    // resting finger. ponytail: knobs; a rest that moves inside this window draws instead of scrolling.
    static const double armTime = 0.5, armMax = 1.5;
    // Tap, then touch again and move the mouse: a drag starts once the pointer moves dragPx (screen points).
    // Arming a letter needs the pointer within pointerStill px, so normal mousing with a resting finger never arms.
    static const CGFloat dragPx = 3, pointerStill = 4;
    static const CGFloat tapDragPx = 8; // ponytail: knob; a tap's own pointer drift must stay a click
    // How soon after a tap the finger must come back down to drag. Not the system double-click speed: yours is
    // 0.15 s, and real re-touches after a tap measured 0.75-0.9 s. ponytail: knob; a touch that lands this soon
    // after a tap and moves the mouse drags, so raise it only if drags still don't start.
    static const double dragWindow = 0.6;
    // One-touch drag: a finger lands on a still mouse, and the pointer moves dragPx within oneTouchWindow.
    // ponytail: risky on purpose (a deliberate choice): normal mousing can match. Set oneTouchWindow 0 to turn it off.
    // stillBefore: the pointer must not have moved this long before the finger landed. Off (0): real grabs land
    // mid-sweep, 12-31 ms after the last pointer move (log of 2026-11-10), and a 100 ms guard refused them.
    static const double oneTouchWindow = 0.3, stillBefore = 0; // 0.3: refusals at 240-242 ms (log 15:24)
    static int oneTouchOK = 0;
    static double preMoveGap; // how long the pointer had been still when the finger landed
    static CGPoint touchPtr;
    static const float dst = 0.0002f;

    static int lastN = 0, drawId = -1, tapClicked = 0, moved = 0;
    static double downT;
    static double tapStartWall;
    static double t0, hintTime = -1;
    static float tapPos[2], lpos[2];

    pthread_mutex_lock(&mmLock);
    mmLastFrameWall = CFAbsoluteTimeGetCurrent();
    if (mmStep == 0) drawId = -1; // ids are reused: a finished drag's id must not exempt a resting thumb

    // A thumb or ring finger resting on the lower side edges (Jitouch's thumb zone, both sides) is part of
    // a normal grip, not a gesture, so it doesn't count. The drawing finger always counts, tracked by id.
    // Two-finger tap = right click: exactly two fingers touch and lift within tapMaxHold, barely moving,
    // with no mouse click and no scrolling (the same rules as the tap that starts a letter).
    static int ttN, ttBad, ttIds[2];
    static float ttPos[2][2];
    static double ttStart, ttStartWall;
    const Finger *f = NULL;
    int nActive = 0;
    for (int i = 0; i < nFingers; i++) {
        int resting = (data[i].px <= 0.15 || data[i].px >= 0.85) && data[i].py <= 0.6;
        if (data[i].identifier == drawId || !resting) {
            nActive++;
            if (f == NULL || data[i].identifier == drawId)
                f = &data[i];
            if (lastN == 0 && nActive == 1) { ttN = 0; ttBad = mmButtonDown(); ttStart = timestamp; ttStartWall = CFAbsoluteTimeGetCurrent(); }
            int j = 0;
            while (j < ttN && ttIds[j] != data[i].identifier) j++;
            if (j == ttN && ttN < 2) {
                ttIds[ttN] = data[i].identifier;
                ttPos[ttN][0] = data[i].px;
                ttPos[ttN++][1] = data[i].py;
            } else if (j == ttN || lenSqr(ttPos[j][0], ttPos[j][1], data[i].px, data[i].py) > tapMoveMax) {
                ttBad = 1; // a third finger, or one moved
            }
        }
    }
    nFingers = nActive;
    if (nFingers > 0 && (timestamp - ttStart > tapMaxHold || mmButtonDown()))
        ttBad = 1;
    if (nFingers == 0 && lastN > 0 && ttN == 2) {
        int clicked = mmStep == 5 || mmLastClickWall >= ttStartWall - 0.05, scrolling = mmLastScrollWall >= ttStartWall - scrollQuiet;
        mmLogLine(ttBad || clicked || scrolling ? "two-finger-tap-refused" : "two-finger-tap: right click");
        if (!ttBad && !clicked && !scrolling) mmRightClick();
        ttN = 0;
    }
    float x = f ? f->px * mmAspect : 0;
    float y = f ? f->py : 0;

    if (mmStep == 4 && timestamp - t0 > strokeGap) // waited long enough after the last stroke: read the letter
        mmEnd(1);

    double wall = CFAbsoluteTimeGetCurrent();
    int startDrag = 0;
    if (mmStep == 1 && mmButtonDown())
        tapClicked = 1;

    if (mmStep == 1) { // first touch: a quick still tap clicks; held still, it arms a letter
        int clicked = tapClicked || mmLastClickWall >= tapStartWall - 0.05;
        int scrolling = mmLastScrollWall >= tapStartWall - scrollQuiet;
        if (nFingers == 0 && timestamp - t0 <= tapMaxHold) {
#ifdef JITOUCH_TRACE
            if (clicked || scrolling) printf("%.3f   not a tap: %s\n", timestamp, clicked ? "mouse click" : "scrolling");
#endif
            mmLogLine(clicked ? "tap-refused: the mouse button clicked" : scrolling ? "tap-refused: scrolling just before" : "tap: click");
            if (!clicked && !scrolling) mmLeftClick(t0, timestamp);
            mmStep = 0;
        } else if (nFingers == 1 && !clicked && !scrolling && oneTouchOK && timestamp - t0 <= oneTouchWindow &&
                   hypot(mmPointer().x - touchPtr.x, mmPointer().y - touchPtr.y) > tapDragPx) {
            startDrag = 1; // landed on a still mouse, then the mouse moved right away
        } else if (nFingers != 1 || clicked || scrolling || lenSqr(tapPos[0], tapPos[1], x, y) > tapMoveMax) {
#ifdef JITOUCH_TRACE
            printf("%.3f   not ours: touches=%d held=%.3fs moved2=%.4f (max %.4f)\n", timestamp, nFingers, timestamp - t0, lenSqr(tapPos[0], tapPos[1], x, y), tapMoveMax);
#endif
            mmStep = 0; // moved before arming (a scroll), another finger, or a click
        } else if ((!oneTouchOK || timestamp - t0 > oneTouchWindow) &&
                   hypot(mmPointer().x - touchPtr.x, mmPointer().y - touchPtr.y) > pointerStill) {
            if (nFingers == 1 && !clicked && !scrolling) { // say why this wasn't a one-touch drag
                char line[160];
                if (!oneTouchOK)
                    snprintf(line, sizeof line, "drag-refused: mouse was moving %.0f ms before the touch (needs %.0f)", preMoveGap * 1000, stillBefore * 1000);
                else
                    snprintf(line, sizeof line, "drag-refused: mouse started moving %.0f ms after the touch (max %.0f)", (timestamp - t0) * 1000, oneTouchWindow * 1000);
                mmLogLine(line);
            }
            mmStep = 0; // the mouse is moving under a resting finger: normal mousing
        } else if (timestamp - t0 >= armTime) {
            mmLogLine("armed: draw now");
            mmStep = 2; // the next frame starts the letter from where the finger sits
            t0 = timestamp;
        }
    } else if (mmStep == 2 || mmStep == 4) { // armed (finger still down) or waiting for the next stroke
        double wait = mmStep == 2 ? 1.0 : strokeGap;
        if (mmStep == 4 && nFingers == 1 && timestamp - t0 <= mergeGap &&
                   lenSqr(lpos[0], lpos[1], x, y) <= mergeDist * mergeDist) {
            // The finger slipped off for an instant and came back where it left: same stroke, carry on.
            mmStep = 3;
            mmGen++; // cancels the pending end-of-letter timer
            drawId = f->identifier;
        } else if (nFingers == 1 && timestamp - t0 <= wait) {
            if (mmStep == 2) {
                moved = 0;
                mmStrokes = 0;
                mmNPts = 0;
                isMMFingerRecognizing = 1; // blocks scroll and other mouse gestures while drawing
                clearStep();
                mmFirst[0] = mmLast[0] = x;
                mmFirst[1] = mmLast[1] = y;
                mmTop = 0; mmBottom = 1; mmLeft = 1; mmRight = 0;
                mmShown = 1; // the dot that says "draw now"
                dispatch_async(dispatch_get_main_queue(), ^{
                    [gestureWindow setHintText: emptyString];
                    [gestureWindow setUpWindowForMouseSurface];
                    [gestureWindow display];
                    [gestureWindow setLevel:NSScreenSaverWindowLevel];
                    [gestureWindow makeKeyAndOrderFront:nil];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [gestureWindow breakStroke];
                    [gestureWindow setHintText: emptyString];
                });
            }
            mmStep = 3;
            mmGen++; // cancels a pending end-of-letter timer
            mmStrokes++;
            downT = timestamp;
            hintTime = -1;
            drawId = f->identifier;
            lpos[0] = x;
            lpos[1] = y;
            if (mmNPts < MM_MAX_POINTS) mmPts[mmNPts++] = (PDPoint){x * pdollarAspectX, y, mmStrokes};
            if (mmShown)
                dispatch_async(dispatch_get_main_queue(), ^{ [gestureWindow addPointX:x Y:y]; });
        } else if (nFingers > 1) {
            mmEnd(0);
        } else if (mmStep == 2) {
            mmStep = 0; // lifted in the same instant it armed
        }
    } else if (mmStep == 6) { // touched again right after a tap-click: a double click, or a drag if the mouse moves
        int clicked = mmLastClickWall >= tapStartWall - 0.05, scrolling = mmLastScrollWall >= tapStartWall - scrollQuiet;
        if (nFingers == 0) {
            if (timestamp - t0 <= tapMaxHold && !clicked && !scrolling)
                mmLogLine(mmLeftClick(t0, timestamp) == 2 ? "tap: double click" : "tap: click (soon after a tap)");
            else if (timestamp - t0 <= tapMaxHold)
                mmLogLine(clicked ? "tap-refused: the mouse button clicked" : "tap-refused: scrolling just before");
            mmStep = 0;
        } else if (nFingers != 1 || mmButtonDown()) {
            mmStep = 0; // another finger, or a real click
        } else if (hypot(mmPointer().x - touchPtr.x, mmPointer().y - touchPtr.y) > tapDragPx) {
            startDrag = 1;
        } else if (lenSqr(tapPos[0], tapPos[1], x, y) > tapMoveMax) {
            mmStep = 0; // the finger slid while the mouse stayed put: a scroll
        } else if (timestamp - t0 > tapMaxHold) {
            mmStep = 1; // too long for a tap: carry on as a first touch, so it can still arm a letter
        }
    } else if (mmStep == 5) { // dragging: the button comes up the instant the drag finger lifts, where the cursor is.
        // Posting the up at an older point snaps the cursor back there (log 16:04: released at (1725,135) with the
        // cursor at (1922,139); 30 ms later the cursor was at (1737,135)). A finger that flickers back while the
        // mouse moves starts a new one-touch drag, so a flicker is a drop plus an instant re-grab.
        int dragDown = f && f->identifier == drawId; // the drag finger, by id: a second finger can't hold the button
        if (mmHwPress) {
            mmGen++;
            mmDragAbandon();
        } else if (!dragDown) {
            mmLiftPtr = mmPointer();
            mmGen++; // stops the watchdog
            mmDragRelease();
            drawId = -1;
        }
    } else if (mmStep == 3) { // drawing a stroke
        if (mmStrokes == 1 && !moved && nFingers > 0 && timestamp - downT > armMax - armTime) {
            mmLogLine("armed-timeout: resting finger");
            mmEnd(0); // armed but never drew: a resting finger, not a letter
            drawId = -1;
        } else if (nFingers == 0 && !cancelRecognition) { // finger lifted: wait for another stroke
            if (mmStrokes == 1 && !moved) {
                mmEnd(0); // armed, then lifted without drawing: nothing
            } else {
                mmStep = 4;
                t0 = timestamp;
                int gen = ++mmGen;
#ifndef JITOUCH_TEST
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(strokeGap * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                    pthread_mutex_lock(&mmLock);
                    if (mmStep == 4 && mmGen == gen) mmEnd(1);
                    pthread_mutex_unlock(&mmLock);
                });
#endif
            }
            drawId = -1;
        } else if (nFingers != 1 || f->identifier != drawId || cancelRecognition) {
            mmEnd(0); // second finger, or Jitouch gave up on the shape
            drawId = -1;
        } else {
            if (mmStrokes == 1) {
                if (y > mmTop) mmTop = y;
                if (y < mmBottom) mmBottom = y;
                if (x > mmRight) mmRight = x;
                if (x < mmLeft) mmLeft = x;
            }
            if (lenSqr(lpos[0], lpos[1], x, y) > dst) {
                if (mmStrokes == 1) {
                    advanceStep(atan2(y - lpos[1], x - lpos[0]));
                    mmLast[0] = x;
                    mmLast[1] = y;
                }
                if (mmNPts < MM_MAX_POINTS) mmPts[mmNPts++] = (PDPoint){x * pdollarAspectX, y, mmStrokes};
                moved = 1;
                lpos[0] = x;
                lpos[1] = y;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [gestureWindow setHintText: emptyString];
                    [gestureWindow addPointX:x Y:y];
                });
                hintTime = mmStrokes == 1 ? timestamp : -1; // hint only for one-stroke letters
            } else if (hintTime > 0 && timestamp - hintTime >= hintWaitTime) {
                const char *hint = finalizeStep(mmFirst[0], mmFirst[1], mmLast[0], mmLast[1], mmTop, mmBottom, mmLeft, mmRight);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [gestureWindow setHintText: hint];
                });
                hintTime = -1;
            }
        }
    }

    if (startDrag) { // press the button where the finger landed, then catch up to the pointer
        mmStep = 5;
        drawId = f->identifier;
        mmLastClickT = -100;
        mmHwPress = 0;
#ifdef JITOUCH_TEST
        jtTestRecognized = @"Drag";
#else
        // Press where the pointer is now: posting at the older touch point yanks the real cursor back there.
        mmPost(kCGEventLeftMouseDown, mmPointer(), kCGMouseButtonLeft, 1);
#endif
        mmDragging = 1; // only after the press is out, so no drag move can precede it
        { char line[120];
          snprintf(line, sizeof line, "drag: mouse down (mouse still %.0f ms before the touch)", preMoveGap * 1000);
          mmLogLine(line); }
        mmDragWatchdog(mmGen);
    }

#ifdef JITOUCH_TRACE
    { static int ps = 0; if (mmStep != ps) printf("%.3f step %d -> %d  touches=%d at (%.2f,%.2f) strokes=%d\n", timestamp, ps, mmStep, nFingers, x, y, mmStrokes); ps = mmStep; }
#endif
    if (mmStep == 0 && lastN == 0 && nFingers == 1) { // a fresh touch starts a possible tap
        mmStep = timestamp - mmLastClickT <= dragWindow ? 6 : 1; // 6: right after a tap-click
        t0 = timestamp;
        tapStartWall = wall;
        tapClicked = mmButtonDown();
        drawId = f->identifier; // keep counting this finger if it slides into the side zone
        touchPtr = mmPointer();
        preMoveGap = wall - mmLastMoveWall;
        oneTouchOK = preMoveGap >= stillBefore;
        tapPos[0] = x;
        tapPos[1] = y;
    }
    lastN = nFingers;
    pthread_mutex_unlock(&mmLock);
}

static void trackpadRecognizerTwo(const Finger *data, int nFingers, double timestamp) {
    static float lpos[2];
    static int step = 0;
    static const float dst = 0.0002;

    static float firstPos[2];
    static float top, bottom, left, right;
    static float fing[2][2];
    static double sttime;
    static NSMutableString *commandString = nil;

    static double hintTime;
    static int distCounter = 0;
    float x, y;

    if (step == 0 && nFingers < 2) {
        step = 1;
    } else if (step == 1 && nFingers == 2) {
        int left = data[0].px > data[1].px;
        if (fabs(data[0].px-data[1].px) > charRegIndexRingDistance &&
           fabs(data[0].px-data[1].px) < 0.65 &&
           fabs(data[0].py-data[1].py)< 0.6  &&
           data[!left].py-data[left].py + data[!left].py > -0.12 &&
           data[0].py > 0.14 && data[1].py > 0.14 &&
           !CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft) &&
           !(data[0].majorAxis >= 11 && data[1].majorAxis >= 11 && data[!left].angle > 1.5708 && data[left].angle < 1.5708 && data[!left].angle-data[left].angle > 0.5)) {
            @autoreleasepool {
                x = (data[0].px + data[1].px) / 2;
                y = (data[0].py + data[1].py) / 2;

                step = 3;
                isTrackpadRecognizing = 2;
                lpos[0] = x;
                lpos[1] = y;
                firstPos[0] = lpos[0];
                firstPos[1] = lpos[1];
                fing[0][0] = data[0].px;
                fing[0][1] = data[0].py;
                fing[1][0] = data[1].px;
                fing[1][1] = data[1].py;
                clearStep();
                top = 0;
                bottom = 1;
                left = 1;
                right = 0;

                dispatch_async(dispatch_get_main_queue(), ^{
                    [gestureWindow setHintText: emptyString];

                    distCounter = 0;

                    [gestureWindow setUpWindowForTrackpad];
                    [gestureWindow addPointX:x Y:y];
                });

                hintTime = -1;
            };
        } else
            step = 0;
    } else if (step == 3) {

        if (nFingers != 2 || cancelRecognition) {
            step = 0;
            @autoreleasepool {
                if (!cancelRecognition && distCounter == -1) {
                    if (!commandString) {
                        commandString = [[NSMutableString alloc] init];
                    }
                    [commandString setString:[NSString stringWithUTF8String:finalizeStep(firstPos[0], firstPos[1], lpos[0], lpos[1], top, bottom, left, right)]];
                    if (nFingers != 3) {
                        dispatchCommand(commandString, CHARRECOGNITION);
                    }
                }
                cancelRecognition = 0;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [gestureWindow clear];
                    [gestureWindow orderOut:nil];
                });
            };
            isTrackpadRecognizing = 0;

        } else {
            if (hintTime > 0 && timestamp - hintTime >= hintWaitTime) {
                @autoreleasepool {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [gestureWindow setHintText: finalizeStep(firstPos[0], firstPos[1], lpos[0], lpos[1], top, bottom, left, right)];
                    });
                };
                hintTime = -1;
            }

            x = (data[0].px + data[1].px) / 2;
            y = (data[0].py + data[1].py) / 2;

            if (y > top)
                top = y;
            if (y < bottom)
                bottom = y;
            if (x > right)
                right = x;
            if (x < left)
                left = x;
            if (lenSqr(lpos[0], lpos[1], x, y) > dst) {
                float deg = atan2(y - lpos[1], x - lpos[0]);
                advanceStep(deg);
                @autoreleasepool {
                    if (distCounter >= 0) {
                        distCounter++;
                        if (distCounter >= 5) {
                            if (lenSqr(fing[0][0], fing[0][1], data[0].px, data[0].py) > 0.003 && lenSqr(fing[1][0], fing[1][1], data[1].px, data[1].py) > 0.003
                               && fabs(lenSqr(fing[0][0], fing[0][1], fing[1][0], fing[1][1])-lenSqr(data[0].px, data[0].py, data[1].px, data[1].py)) < 0.13) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [gestureWindow display];
                                    [gestureWindow setLevel:NSScreenSaverWindowLevel];
                                    [gestureWindow makeKeyAndOrderFront:nil];
                                });
                                distCounter = -1;
                            } else {
                                cancelRecognition = 1;
                            }
                        }
                    }

                    lpos[0] = x;
                    lpos[1] = y;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [gestureWindow addPointX:x Y:y];
                    });

                    hintTime = timestamp;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [gestureWindow setHintText: emptyString];
                    });
                };
            }
        }
    } else if (step == 4) {
        if (timestamp - sttime > clickSpeed || nFingers < 2 || nFingers > 3)
            step = 0;
        else if (nFingers == 2) {
            step = 5;
            sttime = timestamp;
        }
    } else if (step == 5) {
        if (timestamp - sttime > clickSpeed || nFingers < 2 || nFingers > 3)
            step = 0;
        if (nFingers == 3) {
            step = 0;
        }
    }
}

#pragma mark -

- (void) dealloc {
    CFRelease(deviceList);
    [super dealloc];
}

@end

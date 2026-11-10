// Feeds synthetic Magic Mouse touch frames into magicMouseFingerRecognizer and checks what it recognizes.
// Run: tests/run.sh   (exit 0 = all pass)
#import <Cocoa/Cocoa.h>
static NSString *jtTestRecognized;
#define JITOUCH_TEST 1
#include "../jitouch/Jitouch/Gesture.m"

static const double FRAME = 0.01; // 100 Hz, close to the real touch frame rate
static double now = 1000;
static int failures = 0;

typedef struct { float x, y; } P;

static Finger touch(int ident, float x, float y) {
    Finger f;
    memset(&f, 0, sizeof f);
    f.identifier = ident;
    f.state = MTTouchStateTouching;
    f.px = x;
    f.py = y;
    f.size = 1.0f;
    return f;
}

// One frame: the drawing finger (if down) plus any extra resting touches such as a thumb.
static void frame(int fingerDown, P p, const Finger *extra, int nExtra) {
    Finger d[4];
    int n = 0;
    if (fingerDown) d[n++] = touch(1, p.x, p.y);
    for (int i = 0; i < nExtra; i++) d[n++] = extra[i];
    magicMouseFingerRecognizer(d, n, now);
    now += FRAME;
}

static void idle(double secs, const Finger *extra, int nExtra) {
    for (double t = 0; t < secs; t += FRAME) frame(0, (P){0, 0}, extra, nExtra);
}

static void tap(P p, const Finger *extra, int nExtra) {
    for (int i = 0; i < 6; i++) frame(1, p, extra, nExtra); // 60 ms touch
    idle(0.08, extra, nExtra);                              // 80 ms gap
}

// Draws straight segments through the points, `perSeg` frames each, finger held down throughout.
static void stroke(const P *pts, int n, int perSeg, const Finger *extra, int nExtra) {
    frame(1, pts[0], extra, nExtra);
    for (int s = 0; s + 1 < n; s++)
        for (int i = 1; i <= perSeg; i++) {
            float t = (float)i / perSeg;
            frame(1, (P){pts[s].x + (pts[s + 1].x - pts[s].x) * t, pts[s].y + (pts[s + 1].y - pts[s].y) * t}, extra, nExtra);
        }
}

static void reset(void) {
    [jtTestRecognized release];
    jtTestRecognized = nil;
    idle(1.0, NULL, 0); // long gap so no state leaks between cases
}

static void expect(const char *name, const char *want) {
    const char *got = jtTestRecognized ? [jtTestRecognized UTF8String] : "(nothing)";
    int ok = strcmp(got, want) == 0 && !isMMFingerRecognizing;
    if (!ok) failures++;
    printf("%s  %-44s want %-10s got %s%s\n", ok ? "PASS" : "FAIL", name, want, got,
           isMMFingerRecognizing ? " (still blocking scroll!)" : "");
}

static const P L_[] = {{0.40, 0.85}, {0.40, 0.45}, {0.68, 0.45}};
static const P Z_[] = {{0.35, 0.85}, {0.65, 0.85}, {0.35, 0.45}, {0.65, 0.45}};

static void drawLetter(const P *pts, int n, const Finger *extra, int nExtra) {
    tap(pts[0], extra, nExtra);
    stroke(pts, n, 15, extra, nExtra);
    idle(0.6, extra, nExtra); // lift
}

// Multi-stroke shapes are written in physical proportions; the sensor is 10 x 15, so widen x by 15/10
// around the middle to get the normalized coordinates the mouse would report.
static void drawStrokes(const P *const *strokes, const int *lens, int nStrokes) {
    P wide[8][8];
    for (int i = 0; i < nStrokes; i++)
        for (int j = 0; j < lens[i]; j++)
            wide[i][j] = (P){0.5f + (strokes[i][j].x - 0.5f) * 1.5f, strokes[i][j].y};
    tap(wide[0][0], NULL, 0);
    for (int i = 0; i < nStrokes; i++) {
        stroke(wide[i], lens[i], 12, NULL, 0);
        idle(i + 1 < nStrokes ? 0.25 : 0.6, NULL, 0); // pen lift between strokes, then the end-of-letter wait
    }
}

static void drawO(void) {
    P pts[41];
    for (int i = 0; i <= 40; i++) { // counterclockwise from the top, like the "O" template
        float a = M_PI / 2 + 2 * M_PI * i / 40;
        pts[i] = (P){0.5 + 0.18 * cosf(a), 0.65 + 0.2 * sinf(a)};
    }
    tap(pts[0], NULL, 0);
    stroke(pts, 41, 2, NULL, 0);
    idle(0.6, NULL, 0);
}

int main(void) {
    @autoreleasepool {
        initNormPdf();
        initChars();
        clickSpeed = 0.25f; // Jitouch default (Settings.m)
        enCharRegMM = 1;

        if (getenv("JT_PERSONAL_TEST")) { // JITOUCH_LETTERS holds 3 zig-zag "Q" examples (tests/run.sh)
            static const P zz[] = {{0.35, 0.80}, {0.60, 0.70}, {0.35, 0.60}, {0.60, 0.50}, {0.35, 0.40}};
            reset(); drawLetter(zz, 5, NULL, 0); expect("one stroke matches your trained letter", "Q");
            static const P line[] = {{0.50, 0.40}, {0.50, 0.85}};
            reset(); drawLetter(line, 2, NULL, 0); expect("straight stroke still ignored with training", "(nothing)");
            printf(failures ? "\n%d FAILED\n" : "\nALL PASSED\n", failures);
            return failures ? 1 : 0;
        }

        reset(); drawLetter(L_, 3, NULL, 0);                      expect("tap, then draw L", "L");
        reset(); drawLetter(Z_, 4, NULL, 0);                      expect("tap, then draw Z", "Z");
        reset(); drawO();                                         expect("tap, then draw O", "O");

        static const P N_[] = {{0.35, 0.45}, {0.35, 0.85}, {0.65, 0.45}, {0.65, 0.85}};
        static const P up[] = {{0.50, 0.40}, {0.50, 0.85}};
        static const P down[] = {{0.50, 0.85}, {0.50, 0.40}};
        static const P S_[] = {{0.62, 0.88}, {0.40, 0.74}, {0.60, 0.58}, {0.40, 0.44}, {0.30, 0.44}};
        reset(); drawLetter(S_, 5, NULL, 0);                      expect("tap, then draw S (screenshot)", "S");
        static const P G_[] = {{0.62, 0.85}, {0.40, 0.65}, {0.55, 0.42}, {0.68, 0.56}, {0.52, 0.56}};
        static const P M_[] = {{0.30, 0.45}, {0.38, 0.85}, {0.47, 0.55}, {0.56, 0.85}, {0.64, 0.45}};
        static const P Y_[] = {{0.35, 0.85}, {0.48, 0.62}, {0.61, 0.85}, {0.40, 0.45}};
        reset(); drawLetter(G_, 5, NULL, 0);                      expect("tap, then draw G", "G");
        reset(); drawLetter(M_, 5, NULL, 0);                      expect("tap, then draw M", "M");
        reset(); drawLetter(Y_, 4, NULL, 0);                      expect("tap, then draw Y", "Y");
        reset(); drawLetter(N_, 4, NULL, 0);                      expect("tap, then draw N (New)", "N");
        reset(); drawLetter(up, 2, NULL, 0);                      expect("straight stroke up is ignored (scroll-like)", "(nothing)");
        reset(); drawLetter(down, 2, NULL, 0);                    expect("straight stroke down is ignored (scroll-like)", "(nothing)");

        // Multi-stroke letters, written the normal way.
        { static const P a[] = {{0.40, 0.85}, {0.40, 0.45}}, b[] = {{0.40, 0.85}, {0.65, 0.85}}, c[] = {{0.40, 0.65}, {0.58, 0.65}};
          const P *st[] = {a, b, c}; const int ln[] = {2, 2, 2};
          reset(); drawStrokes(st, ln, 3); expect("multi-stroke F (3 strokes)", "F"); }
        { static const P a[] = {{0.35, 0.85}, {0.65, 0.85}}, b[] = {{0.50, 0.85}, {0.50, 0.45}};
          const P *st[] = {a, b}; const int ln[] = {2, 2};
          reset(); drawStrokes(st, ln, 2); expect("multi-stroke T (2 strokes)", "T"); }
        { static const P a[] = {{0.35, 0.85}, {0.35, 0.45}}, b[] = {{0.65, 0.85}, {0.65, 0.45}}, c[] = {{0.35, 0.65}, {0.65, 0.65}};
          const P *st[] = {a, b, c}; const int ln[] = {2, 2, 2};
          reset(); drawStrokes(st, ln, 3); expect("multi-stroke H (3 strokes)", "H"); }
        { static const P a[] = {{0.40, 0.85}, {0.40, 0.45}}, b[] = {{0.40, 0.85}, {0.65, 0.85}}, c[] = {{0.40, 0.65}, {0.60, 0.65}}, d[] = {{0.40, 0.45}, {0.65, 0.45}};
          const P *st[] = {a, b, c, d}; const int ln[] = {2, 2, 2, 2};
          reset(); drawStrokes(st, ln, 4); expect("multi-stroke E (4 strokes)", "E"); }
        { static const P a[] = {{0.35, 0.85}, {0.65, 0.45}}, b[] = {{0.65, 0.85}, {0.35, 0.45}};
          const P *st[] = {a, b}; const int ln[] = {2, 2};
          reset(); drawStrokes(st, ln, 2); expect("multi-stroke X (2 strokes)", "X"); }

        // Must NOT trigger.
        reset(); stroke(L_, 3, 15, NULL, 0); idle(0.6, NULL, 0); expect("no tap first (normal scroll)", "(nothing)");
        reset(); tap(L_[0], NULL, 0); tap(L_[0], NULL, 0);        expect("double tap, no movement", "(nothing)");
        reset();
        for (int i = 0; i < 40; i++) frame(1, L_[0], NULL, 0);    // 400 ms touch: a rest, not a tap
        idle(0.08, NULL, 0); stroke(L_, 3, 15, NULL, 0); idle(0.6, NULL, 0);
        expect("slow first touch", "(nothing)");
        reset();
        tap(L_[0], NULL, 0); stroke(L_, 2, 15, NULL, 0);
        { Finger second = touch(2, 0.6, 0.7); frame(1, L_[1], &second, 1); }
        idle(0.6, NULL, 0);
        expect("second finger lands mid-letter (cancel)", "(nothing)");
        reset(); tap(L_[0], NULL, 0); idle(1.5, NULL, 0); stroke(L_, 3, 15, NULL, 0); idle(0.6, NULL, 0);
        expect("gap after tap too long", "(nothing)");
        reset(); tap(L_[0], NULL, 0); idle(0.85, NULL, 0); stroke(L_, 3, 15, NULL, 0); idle(0.6, NULL, 0);
        expect("natural pause after tap (0.85 s)", "L");

        // Finger slips off for 0.1 s at the corner of an L and lands where it left: still one stroke.
        { static const P back[] = {{0.413, 0.45}, {0.68, 0.45}}; // lands 0.013 away, like the recorded slip
          reset(); tap(L_[0], NULL, 0); stroke(L_, 2, 15, NULL, 0); idle(0.1, NULL, 0); stroke(back, 2, 15, NULL, 0); idle(0.6, NULL, 0); }
        expect("finger slips off mid-stroke, comes back", "L");

        // Scroll and click guards.
        reset(); jtTestButtonDown = 1; tap(L_[0], NULL, 0); jtTestButtonDown = 0; stroke(L_, 3, 15, NULL, 0); idle(0.6, NULL, 0);
        expect("mouse click, then scroll", "(nothing)");
        reset(); mmLastScrollWall = CFAbsoluteTimeGetCurrent(); tap(L_[0], NULL, 0); stroke(L_, 3, 15, NULL, 0); idle(0.6, NULL, 0);
        mmLastScrollWall = 0;
        expect("touch while still scrolling, then stroke", "(nothing)");
        reset(); tap(L_[0], NULL, 0); mmLastScrollWall = CFAbsoluteTimeGetCurrent() + 1; stroke(L_, 3, 15, NULL, 0); idle(0.6, NULL, 0);
        mmLastScrollWall = 0;
        expect("scroll momentum after the tap", "(nothing)");
        { static const P f1[] = {{0.50, 0.40}, {0.50, 0.75}}, f2[] = {{0.52, 0.42}, {0.52, 0.80}}, f3[] = {{0.49, 0.38}, {0.50, 0.72}};
          const P *st[] = {f1, f2, f3}; const int ln[] = {2, 2, 2};
          reset(); drawStrokes(st, ln, 3); expect("tap, then 3 parallel scroll flicks", "(nothing)"); }
        reset(); tap(L_[0], NULL, 0); stroke(L_, 2, 15, NULL, 0); cancelRecognition = 1; stroke(L_ + 1, 2, 15, NULL, 0); idle(0.6, NULL, 0);
        expect("mouse click while drawing cancels", "(nothing)");

        // Real grip: thumb resting on the left side of the mouse the whole time.
        Finger thumb = touch(9, 0.05, 0.40);
        reset(); idle(0.1, &thumb, 1); drawLetter(L_, 3, &thumb, 1); expect("thumb resting on side, draw L", "L");

        static const P edgeL[] = {{0.10, 0.80}, {0.10, 0.35}, {0.40, 0.35}}; // passes through the side "thumb" zone
        reset(); drawLetter(edgeL, 3, NULL, 0); expect("letter drawn along the side edge", "L");

        printf(failures ? "\n%d FAILED\n" : "\nALL PASSED\n", failures);
    }
    return failures ? 1 : 0;
}

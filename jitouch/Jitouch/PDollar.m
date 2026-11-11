//
//  PDollar.m
//  Jitouch
//
//  $P point-cloud recognizer (Vatavu, Anthony & Wobbrock, ICMI 2012) for multi-stroke letters.
//

#import <Foundation/Foundation.h>
#include <math.h>
#include <float.h>
#include "PDollar.h"

#define PD_N 32

typedef struct { const char *name; PDPoint pts[PD_N]; int multi; } PDTemplate; // multi: drawn with 2+ strokes

// Letters people normally write with more than one stroke. Unit box, y up; {x, y, stroke}.
// One template per letter is enough: a 4-stroke E and a 2-stroke E make the same point cloud.
static const PDPoint tA[] = {{0,0,0},{0.5,1,0},{1,0,0}, {0.25,0.45,1},{0.75,0.45,1}};
static const PDPoint tB[] = {{0,1,0},{0,0,0}, {0,1,1},{0.55,0.97,1},{0.7,0.75,1},{0.55,0.53,1},{0,0.5,1},{0.65,0.47,1},{0.8,0.24,1},{0.65,0.03,1},{0,0,1}};
static const PDPoint tD[] = {{0,1,0},{0,0,0}, {0,1,1},{0.55,0.92,1},{0.8,0.5,1},{0.55,0.08,1},{0,0,1}};
static const PDPoint tE[] = {{0.8,1,0},{0,1,0},{0,0,0},{0.8,0,0}, {0,0.5,1},{0.6,0.5,1}};
static const PDPoint tF[] = {{0,1,0},{0,0,0}, {0,1,1},{0.8,1,1}, {0,0.5,2},{0.6,0.5,2}};
static const PDPoint tH[] = {{0,1,0},{0,0,0}, {1,1,1},{1,0,1}, {0,0.5,2},{1,0.5,2}};
static const PDPoint tK[] = {{0,1,0},{0,0,0}, {0.8,1,1},{0,0.45,1},{0.8,0,1}};
static const PDPoint tP[] = {{0,1,0},{0,0,0}, {0,1,1},{0.55,0.95,1},{0.75,0.75,1},{0.55,0.55,1},{0,0.5,1}};
static const PDPoint tR[] = {{0,1,0},{0,0,0}, {0,1,1},{0.55,0.95,1},{0.75,0.75,1},{0.55,0.55,1},{0,0.5,1},{0.8,0,1}};
static const PDPoint tT[] = {{0,1,0},{1,1,0}, {0.5,1,1},{0.5,0,1}};
static const PDPoint tX[] = {{0,1,0},{1,0,0}, {1,1,1},{0,0,1}};

#define T(name, arr) { name, arr, sizeof(arr) / sizeof(arr[0]) }
static const struct { const char *name; const PDPoint *pts; int n; } sources[] = {
    T("A", tA), T("B", tB), T("D", tD), T("E", tE), T("F", tF), T("H", tH),
    T("K", tK), T("P", tP), T("R", tR), T("T", tT), T("X", tX),
};
#define N_BUILTIN (int)(sizeof(sources) / sizeof(sources[0]))
#define MAX_TEMPLATES 512
static PDTemplate templates[MAX_TEMPLATES];
static int nTemplates;

static float dist(PDPoint a, PDPoint b) { return hypotf(a.x - b.x, a.y - b.y); }

static int isMultiStroke(const PDPoint *p, int n) {
    for (int i = 1; i < n; i++)
        if (p[i].stroke != p[0].stroke) return 1;
    return 0;
}

// Resample to exactly PD_N points spaced evenly along the drawn path (never across a pen lift).
static void resample(const PDPoint *in, int n, PDPoint *out) {
    float len = 0;
    for (int i = 1; i < n; i++)
        if (in[i].stroke == in[i - 1].stroke) len += dist(in[i - 1], in[i]);
    float interval = len / (PD_N - 1), D = 0;
    int k = 0;
    out[k++] = in[0];
    PDPoint prev = in[0];
    for (int i = 1; i < n && k < PD_N; i++) {
        if (in[i].stroke != in[i - 1].stroke) { prev = in[i]; continue; }
        float d = dist(prev, in[i]);
        while (D + d >= interval && d > 0 && k < PD_N) {
            float t = (interval - D) / d;
            PDPoint q = { prev.x + t * (in[i].x - prev.x), prev.y + t * (in[i].y - prev.y), in[i].stroke };
            out[k++] = q;
            d -= interval - D;
            D = 0;
            prev = q;
        }
        D += d;
        prev = in[i];
    }
    while (k < PD_N) out[k++] = in[n - 1]; // rounding can leave the last slot empty
}

// Uniform scale into the unit box (keeps aspect ratio), then center on the centroid.
static void normalize(PDPoint *p) {
    float minX = FLT_MAX, minY = FLT_MAX, maxX = -FLT_MAX, maxY = -FLT_MAX;
    for (int i = 0; i < PD_N; i++) {
        minX = fminf(minX, p[i].x); maxX = fmaxf(maxX, p[i].x);
        minY = fminf(minY, p[i].y); maxY = fmaxf(maxY, p[i].y);
    }
    float size = fmaxf(fmaxf(maxX - minX, maxY - minY), 1e-6f), cx = 0, cy = 0;
    for (int i = 0; i < PD_N; i++) {
        p[i].x = (p[i].x - minX) / size; p[i].y = (p[i].y - minY) / size;
        cx += p[i].x; cy += p[i].y;
    }
    cx /= PD_N; cy /= PD_N;
    for (int i = 0; i < PD_N; i++) { p[i].x -= cx; p[i].y -= cy; }
}

static float cloudDistance(const PDPoint *a, const PDPoint *b, int start) {
    int matched[PD_N] = {0};
    float sum = 0;
    int i = start;
    do {
        int best = -1;
        float min = FLT_MAX;
        for (int j = 0; j < PD_N; j++) {
            if (matched[j]) continue;
            float d = dist(a[i], b[j]);
            if (d < min) { min = d; best = j; }
        }
        matched[best] = 1;
        float weight = 1 - (float)((i - start + PD_N) % PD_N) / PD_N;
        sum += weight * min;
        i = (i + 1) % PD_N;
    } while (i != start);
    return sum;
}

static float greedyCloudMatch(const PDPoint *pts, const PDPoint *tmpl) {
    int step = (int)floor(pow(PD_N, 0.5)); // epsilon = 0.5, as in the paper
    float min = FLT_MAX;
    for (int i = 0; i < PD_N; i += step)
        min = fminf(min, fminf(cloudDistance(pts, tmpl, i), cloudDistance(tmpl, pts, i)));
    return min;
}

// Your own handwriting, recorded with tools/learn.py: one template per line, "LETTER x,y,stroke x,y,stroke ...".
// $P works best with the writer's own examples; built-ins are only the fallback.
static void loadUserTemplates(void) {
    const char *env = getenv("JITOUCH_LETTERS"); // tests point this at a scratch file
    NSString *path = env ? [NSString stringWithUTF8String:env]
                         : [@"~/Library/Application Support/Jitouch/letters.txt" stringByExpandingTildeInPath];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSArray *parts = [[line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] componentsSeparatedByString:@" "];
        if ([parts count] < 3 || nTemplates >= MAX_TEMPLATES) continue;
        PDPoint raw[1024];
        int n = 0;
        for (NSUInteger i = 1; i < [parts count] && n < 1024; i++) {
            NSArray *xys = [[parts objectAtIndex:i] componentsSeparatedByString:@","];
            if ([xys count] != 3) continue;
            raw[n++] = (PDPoint){[[xys objectAtIndex:0] floatValue], [[xys objectAtIndex:1] floatValue], [[xys objectAtIndex:2] intValue]};
        }
        if (n < 2) continue;
        templates[nTemplates].name = strdup([[parts objectAtIndex:0] UTF8String]);
        templates[nTemplates].multi = isMultiStroke(raw, n);
        resample(raw, n, templates[nTemplates].pts);
        normalize(templates[nTemplates].pts);
        nTemplates++;
    }
}

static dispatch_once_t loadOnce;
static void loadTemplates(void);
static const char *pdollarMatch(const PDPoint *pts, int n, float maxScore, float *score, int userOnly);

int pdollarUserTemplateCount(void) {
    loadTemplates();
    return nTemplates - N_BUILTIN;
}

const char *pdollarRecognize(const PDPoint *pts, int n, float maxScore, float *score, int userOnly) {
    loadTemplates();
    *score = FLT_MAX;
    if (n < 2) return NULL;
    return pdollarMatch(pts, n, maxScore, score, userOnly);
}

static void loadTemplates(void) {
    dispatch_once(&loadOnce, ^{
        for (int t = 0; t < N_BUILTIN; t++) {
            templates[t].name = sources[t].name;
            templates[t].multi = isMultiStroke(sources[t].pts, sources[t].n);
            resample(sources[t].pts, sources[t].n, templates[t].pts);
            normalize(templates[t].pts);
        }
        nTemplates = N_BUILTIN;
        loadUserTemplates();
    });
}

static const char *pdollarMatch(const PDPoint *pts, int n, float maxScore, float *score, int userOnly) {
    // Like with like: you write Y in two strokes, so a single stroke (a scroll, a piece of an F) is never a Y.
    int multi = isMultiStroke(pts, n);
    PDPoint cand[PD_N];
    resample(pts, n, cand);
    normalize(cand);
    const char *best = NULL, *second = NULL;
    float secondScore = FLT_MAX;
    for (int t = userOnly ? N_BUILTIN : 0; t < nTemplates; t++) {
        if (templates[t].multi != multi) continue;
        float d = greedyCloudMatch(cand, templates[t].pts);
        if (d < *score) { second = best; secondScore = *score; *score = d; best = templates[t].name; }
        else if (d < secondScore) { secondScore = d; second = templates[t].name; }
    }
#ifdef JITOUCH_TRACE
    printf("   $P best %s %.2f, runner-up %s %.2f\n", best, *score, second, secondScore);
#endif
    return *score <= maxScore ? best : NULL;
}

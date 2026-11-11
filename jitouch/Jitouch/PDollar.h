//
//  PDollar.h
//  Jitouch
//
//  $P point-cloud recognizer (Vatavu, Anthony & Wobbrock, ICMI 2012) for multi-stroke letters.
//  Stroke order, stroke direction and stroke count don't matter; only the drawn shape does.
//

typedef struct { float x, y; int stroke; } PDPoint;

// Returns the best-matching letter, or NULL if nothing scores under maxScore. *score gets the best distance.
// userOnly: compare only against your recorded handwriting (letters.txt), not the built-in shapes.
const char *pdollarRecognize(const PDPoint *pts, int n, float maxScore, float *score, int userOnly);

// How many examples of your own handwriting are loaded (0 if you haven't trained any letters).
int pdollarUserTemplateCount(void);

#!/usr/bin/env python3
"""Teach Jitouch your handwriting for a multi-stroke letter.

Usage:
  build/touch_probe 40 > /tmp/f.log        # draw the letter 5-10 times, ~1 s apart (tapping first is fine)
  tools/learn.py F /tmp/f.log              # appends to ~/Library/Application Support/Jitouch/letters.txt
  tools/learn.py F /tmp/f.log --out FILE   # or to another file
  tools/learn.py F /tmp/f.log --replace    # drop F's old examples first
  tools/learn.py G /tmp/g.log --one-stroke # one-stroke letter: each stroke is an example

Each letter = strokes separated by less than 0.6 s of no touch. Taps (barely moving touches) are dropped.
Restart Jitouch afterwards so it reloads the file.
"""
import os
import re
import sys

ASPECT_X = 10 / 15  # must match pdollarAspectX in Gesture.m (sensor is 10 columns x 15 rows)
LETTER_GAP = 0.6    # seconds of no touch that ends one letter
MIN_STROKE = 0.05   # strokes shorter than this (normalized path length) are taps or dots, not ink


def letters(path):
    groups, strokes, cur, last_touch = [], [], None, None
    for line in open(path):
        m = re.match(r'([\d.]+) n=(\d+)(.*)', line)
        if not m:
            continue
        t, n = float(m[1]), int(m[2])
        pts = [(float(x), float(y)) for x, y in re.findall(r'x=([\d.-]+) y=([\d.-]+)', m[3])]
        if n and last_touch is not None and t - last_touch > LETTER_GAP and strokes:
            groups.append(strokes); strokes = []
        if n:
            if cur is None:
                cur = []
            cur.append(pts[0])
            last_touch = t
        elif cur is not None:
            strokes.append(cur); cur = None
    if cur:
        strokes.append(cur)
    if strokes:
        groups.append(strokes)
    out = []
    for g in groups:
        ink = [s for s in g if path_len(s) >= MIN_STROKE]
        if ink:
            out.append(ink)
    return out


def path_len(s):
    return sum(((s[i][0]-s[i-1][0])**2 + (s[i][1]-s[i-1][1])**2) ** .5 for i in range(1, len(s)))


def is_straight_line(ink):
    """One nearly straight stroke: that's a scroll or a hand adjustment, never a letter. Kept out of training."""
    if len(ink) != 1:
        return False
    s = ink[0]
    d = ((s[-1][0]-s[0][0])**2 + (s[-1][1]-s[0][1])**2) ** .5
    return d >= 0.9 * path_len(s)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    letter, rec = sys.argv[1], sys.argv[2]
    dest = sys.argv[sys.argv.index('--out') + 1] if '--out' in sys.argv else \
        os.path.expanduser('~/Library/Application Support/Jitouch/letters.txt')
    found = letters(rec)
    if '--one-stroke' in sys.argv:  # one-stroke letters: every stroke is its own example, however fast you drew
        found = [[stroke] for ink in found for stroke in ink]
    if found and '--one-stroke' not in sys.argv:  # keep your usual stroke count; drop cut-off or merged letters
        usual = max(set(len(i) for i in found), key=[len(i) for i in found].count)
        odd = [i for i in found if len(i) != usual]
        found = [i for i in found if len(i) == usual]
        if odd:
            print(f'{letter}: dropped {len(odd)} examples not drawn with your usual {usual} strokes')
    dropped = [ink for ink in found if is_straight_line(ink)]
    found = [ink for ink in found if not is_straight_line(ink)]
    if dropped:
        print(f'{letter}: dropped {len(dropped)} straight-line strokes (scrolls or hand adjustments, not letters)')
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if '--replace' in sys.argv and os.path.exists(dest):  # retraining a letter drops its old examples
        keep = [l for l in open(dest) if not l.startswith(letter + ' ')]
        open(dest, 'w').writelines(keep)
    with open(dest, 'a') as f:
        for ink in found:
            f.write(letter + ' ' + ' '.join(f'{x * ASPECT_X:.4f},{y:.4f},{k}' for k, s in enumerate(ink) for x, y in s) + '\n')
    print(f'{letter}: {len(found)} examples ({", ".join(str(len(i)) + " strokes" for i in found)}) -> {dest}')


if __name__ == '__main__':
    main()

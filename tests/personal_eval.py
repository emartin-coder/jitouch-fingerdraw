#!/usr/bin/env python3
"""Leave-one-out check of trained handwriting, plus scroll strokes that must NOT match.

Usage: tests/personal_eval.py TEMPLATES [--max SCORE] [--negatives RECORDING ...]
Each trained sample is scored against all OTHER samples (never itself). Prints accuracy, the worst correct score,
and the best score any scroll stroke reached, so personalMaxScore can sit between them. Exit 1 if --max is given
and a sample is misread or a scroll stroke would fire.
"""
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'tools'))
from learn import ASPECT_X  # same width correction as the app

EVAL = os.path.join(os.path.dirname(__file__), '..', 'build', 'pd_eval')


def score(templates, sample):
    with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as f:
        f.writelines(templates)
    out = subprocess.run([EVAL, sample.strip()], env={**os.environ, 'JITOUCH_LETTERS': f.name},
                         capture_output=True, text=True, check=True).stdout.split()
    os.unlink(f.name)
    return out[0], float(out[1])


def scroll_strokes(path):
    """Single long strokes (path > 0.15) from a recording: what scrolling actually looks like."""
    strokes, cur = [], None
    for line in open(path):
        m = re.match(r'([\d.]+) n=(\d+)(?: btn=\d)?(.*)', line)
        if not m:
            continue
        pts = [(float(x), float(y)) for x, y in re.findall(r'x=([\d.-]+) y=([\d.-]+)', m[3])]
        if int(m[2]):
            cur = (cur or []) + [pts[0]]
        elif cur:
            strokes.append(cur); cur = None
    out = []
    for s in strokes:
        path = sum(((s[i][0]-s[i-1][0])**2 + (s[i][1]-s[i-1][1])**2) ** .5 for i in range(1, len(s)))
        if path > 0.15:
            out.append('X ' + ' '.join(f'{x * ASPECT_X:.4f},{y:.4f},0' for x, y in s))
    return out


def main():
    lines = [l for l in open(sys.argv[1]) if l.strip()]
    mx = float(sys.argv[sys.argv.index('--max') + 1]) if '--max' in sys.argv else None
    negs = sys.argv[sys.argv.index('--negatives') + 1:] if '--negatives' in sys.argv else []
    counts = {}
    for s in lines:
        counts[s.split()[0]] = counts.get(s.split()[0], 0) + 1
    thin = [f'{k} has only {v} example(s); train it again (needs 3+)' for k, v in counts.items() if v < 3]
    ok, worst, bad = 0, 0.0, list(thin)
    for i, s in enumerate(lines):
        want = s.split()[0]
        got, sc = score(lines[:i] + lines[i + 1:], s)
        if got == want and (mx is None or sc <= mx):
            ok += 1
            worst = max(worst, sc)
        else:
            bad.append(f'{want} read as {got} ({sc:.2f})')
    print(f'trained samples: {ok}/{len(lines)} read correctly (leave-one-out), worst correct score {worst:.2f}')
    for b in bad:
        print('  MISS', b)
    neg_best, fired = 99.0, []
    for rec in negs:
        for s in scroll_strokes(rec):
            got, sc = score(lines, s)
            neg_best = min(neg_best, sc)
            if mx is not None and sc <= mx:
                fired.append(f'{os.path.basename(rec)}: scroll stroke matched {got} ({sc:.2f})')
    if negs:
        print(f'scroll strokes: closest match score {neg_best:.2f} (must stay above the cutoff)')
    for f in fired:
        print('  FALSE', f)
    sys.exit(1 if mx is not None and (bad or fired) else 0)


if __name__ == '__main__':
    main()

#!/bin/zsh
# Builds and runs the fingertip-drawing recognizer test. Exit 0 = all pass.
set -euo pipefail
cd "${0:A:h}/.."
SRC=jitouch/Jitouch
mkdir -p build
OUT=build/test_fingerdraw
clang -fno-objc-arc -fobjc-exceptions -O1 -arch arm64 -mmacosx-version-min=11.0 -w \
  -include $SRC/Jitouch_Prefix.pch -I$SRC tests/test_fingerdraw.m \
  $(ls $SRC/*.m | grep -v -e '/main.m$' -e '/Gesture.m$') support/MultitouchSupport.tbd \
  -framework Cocoa -framework Carbon -framework IOKit -framework ScriptingBridge -framework ApplicationServices \
  -o $OUT
clang -fno-objc-arc -fobjc-exceptions -O1 -arch arm64 -mmacosx-version-min=11.0 -w -DJITOUCH_TRACE \
  -include $SRC/Jitouch_Prefix.pch -I$SRC tests/replay.m \
  $(ls $SRC/*.m | grep -v -e '/main.m$' -e '/Gesture.m$') support/MultitouchSupport.tbd \
  -framework Cocoa -framework Carbon -framework IOKit -framework ScriptingBridge -framework ApplicationServices \
  -o build/replay
clang -fno-objc-arc -O1 -arch arm64 -w tests/pd_eval.m $SRC/PDollar.m -framework Foundation -o build/pd_eval
clang -arch arm64 -w tests/touch_probe.m support/MultitouchSupport.tbd -framework Foundation -framework ApplicationServices -o build/touch_probe
JITOUCH_LETTERS=/dev/null $OUT   # built-in shapes only, so results don't depend on what you've trained
Q=$(mktemp); for i in 1 2 3; do echo "Q 0.2333,0.80,0 0.4000,0.70,0 0.2333,0.60,0 0.4000,0.50,0 0.2333,0.40,0" >> $Q; done
JITOUCH_LETTERS=$Q JT_PERSONAL_TEST=1 $OUT; rm -f $Q

# Real handwriting: each recorded 3-stroke F must read as F using templates learned from the OTHER recordings
# (leave-one-out, so a sample is never matched against itself).
T=$(mktemp -d)
fail=0
for k in tests/fixtures/real-F-*.log(N); do  # recordings are personal and not published; skipped when absent
  for j in tests/fixtures/real-F-*.log; do [[ $j == $k ]] || python3 tools/learn.py F $j --out $T/letters.txt >/dev/null; done
  # Recorded with the old tap start: drop the tap, and hold the finger still 0.6 s where the first stroke begins.
  python3 -c '
import sys; L=open(sys.argv[1]).read().splitlines(); up=lambda l: " n=0" in l; i=0
while not up(L[i]): i+=1  # the tap
while up(L[i]): i+=1      # the gap after it
t=float(L[i].split()[0]); rest=L[i].split(None,1)[1]
print("\n".join("%.3f %s" % (t-0.6+j*0.01, rest) for j in range(60))); print("\n".join(L[i:]))' $k > $T/held.log
  got=$(JITOUCH_LETTERS=$T/letters.txt build/replay $T/held.log | sed -n 's/.*RECOGNIZED "\(.*\)"/\1/p' | tail -1)
  rm -f $T/letters.txt
  if [[ $got == F ]]; then echo "PASS  real F, leave-one-out: ${k:t}"; else echo "FAIL  real F, leave-one-out: ${k:t} got '${got:-nothing}'"; fail=1; fi
done
rm -rf $T

# Your trained handwriting (what the app actually loads): every example must be read as its own letter using
# the others, and no recorded scroll stroke may come under the cutoff in Gesture.m (personalMaxScore).
LETTERS="$HOME/Library/Application Support/Jitouch/letters.txt"
if [[ -f $LETTERS ]]; then
  MAX=$(sed -n 's/^static const float personalMaxScore = \([0-9.]*\)f;.*/\1/p' $SRC/Gesture.m)
  tests/personal_eval.py "$LETTERS" --max $MAX --negatives tests/fixtures/negatives/*.log(N) || fail=1
fi
exit $fail

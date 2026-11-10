#!/bin/zsh
# Records your handwriting for each letter with spoken cues, then learns it.
# Usage: ONE_STROKE=1 tools/train.sh G M Y O S   (one-stroke letters; recordings kept in training/<letter>.log)
#        tools/train.sh F                        (multi-stroke letters: pause ~1 s between letters)
# For each letter: when you hear it, draw it about 8 times, pausing about 2 s between letters. No tap needed.
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p training build
[[ -x build/touch_probe ]] || clang -arch arm64 -w tests/touch_probe.m support/MultitouchSupport.tbd \
  -framework Foundation -framework ApplicationServices -o build/touch_probe
SECS=${SECS:-20}
say "Handwriting training. ${#@} letters. Draw each one 8 times. Pause two seconds between letters. Do not tap."
for L in "$@"; do
  say "Next letter: $L. Start drawing $L now."
  build/touch_probe $SECS > training/$L.log
  say "Stop."
  sleep 1
done
for L in "$@"; do python3 tools/learn.py $L training/$L.log --replace ${ONE_STROKE:+--one-stroke}; done
say "Training recorded."

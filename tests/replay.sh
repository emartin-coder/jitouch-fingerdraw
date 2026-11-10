#!/bin/zsh
# Replays a touch_probe recording through the recognizer. Usage: tests/replay.sh <recording.log>
set -euo pipefail
cd "${0:A:h}/.."
SRC=jitouch/Jitouch
clang -fno-objc-arc -fobjc-exceptions -O1 -arch arm64 -mmacosx-version-min=11.0 -w -DJITOUCH_TRACE \
  -include $SRC/Jitouch_Prefix.pch -I$SRC tests/replay.m \
  $(ls $SRC/*.m | grep -v -e '/main.m$' -e '/Gesture.m$') support/MultitouchSupport.tbd \
  -framework Cocoa -framework Carbon -framework IOKit -framework ScriptingBridge -framework ApplicationServices \
  -o build/replay
build/replay "$1"

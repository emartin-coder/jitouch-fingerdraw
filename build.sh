#!/bin/zsh
# Builds Jitouch (fingertip-drawing fork) without Xcode and installs it as /Applications/Jitouch.app.
# Needs: Xcode Command Line Tools (xcode-select --install). Apple Silicon only.
# Usage: ./build.sh             test, build, install to /Applications and the user's PreferencePanes
#        ./build.sh --no-install test and build into build/ only
set -euo pipefail
cd "${0:A:h}"
B=build
SRC=jitouch/Jitouch
TEMPLATE=$B/Jitouch.prefPane/Contents/Resources/Jitouch.app

# 0. Official release bundle (for its compiled nib), then the tests, which must pass before anything is built.
tools/fetch-template.sh
tests/run.sh

# Signing: a stable local identity keeps the Accessibility permission across rebuilds; ad-hoc ("-") loses it every rebuild.
SIGN_ID=-
security find-identity -p codesigning 2>/dev/null | grep -q '"Jitouch Local Signing"' && SIGN_ID="Jitouch Local Signing"
echo "Signing with: $SIGN_ID"

# 1. Compile the app executable (Apple Silicon).
clang -fno-objc-arc -fobjc-exceptions -O2 -arch arm64 -mmacosx-version-min=11.0 \
  -include $SRC/Jitouch_Prefix.pch -I$SRC $SRC/*.m support/MultitouchSupport.tbd \
  -framework Cocoa -framework Carbon -framework IOKit -framework ScriptingBridge -framework ApplicationServices \
  -o $B/Jitouch

# 2. Icon: render 1024px PNG, scale to every size macOS wants, pack into .icns.
swift support/make_icon.swift $B/icon_1024.png
rm -rf $B/AppIcon.iconset && mkdir $B/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s $B/icon_1024.png --out $B/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) $B/icon_1024.png --out $B/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $B/AppIcon.iconset -o $B/AppIcon.icns

# 3. Assemble the app from the official bundle: swap in our executable and icon, sign for this Mac.
rm -rf $B/Jitouch.app
cp -R $TEMPLATE $B/Jitouch.app
cp $B/Jitouch $B/Jitouch.app/Contents/MacOS/Jitouch
cp $B/AppIcon.icns $B/Jitouch.app/Contents/Resources/jitouchicon.icns
plutil -replace CFBundleShortVersionString -string "2.82.1-fingerdraw" $B/Jitouch.app/Contents/Info.plist
codesign --force --deep --sign "$SIGN_ID" $B/Jitouch.app
codesign --verify --deep --strict $B/Jitouch.app

[[ "${1:-}" == "--no-install" ]] && { echo "Built $B/Jitouch.app"; exit 0; }

# 4. Install: the app in /Applications, plus an identical copy inside the settings panel, because the panel's
#    login agent always launches its embedded path. (A symlink fails: codesign rejects links that leave the bundle.)
#    The app quits itself if another copy is already running, so only one ever runs.
pkill -x Jitouch || true
rm -rf /Applications/Jitouch.app
cp -R $B/Jitouch.app /Applications/Jitouch.app
PANE=~/Library/PreferencePanes/Jitouch.prefPane
if [[ ! -d $PANE ]]; then  # fresh Mac: install the official settings panel first (it sets up start-at-login when opened)
  mkdir -p ~/Library/PreferencePanes
  cp -R $B/Jitouch.prefPane $PANE
fi
if [[ -d $PANE ]]; then
  rm -rf $PANE/Contents/Resources/Jitouch.app
  cp -R $B/Jitouch.app $PANE/Contents/Resources/Jitouch.app
  codesign --force --deep --sign "$SIGN_ID" $PANE
  codesign --verify --deep --strict $PANE
fi
touch /Applications/Jitouch.app   # nudge Finder/Dock to pick up the new icon
launchctl kickstart -k gui/$(id -u)/com.jitouch.Jitouch.agent 2>/dev/null || open /Applications/Jitouch.app
echo "Installed /Applications/Jitouch.app"

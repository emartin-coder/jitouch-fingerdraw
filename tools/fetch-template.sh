#!/bin/zsh
# Downloads the official Jitouch v2.82.1 release (GPL-3.0) and extracts its prefpane into build/.
# The build reuses its compiled MainMenu.nib and resources, because compiling .xib files needs Xcode.
set -euo pipefail
cd "${0:A:h}/.."
[[ -d build/Jitouch.prefPane ]] && exit 0
T=$(mktemp -d)
curl -fsSL -o $T/Install-Jitouch.pkg https://github.com/JitouchApp/Jitouch/releases/download/v2.82.1/Install-Jitouch.pkg
# Refuse anything not signed by the Jitouch maintainer's Apple Developer ID (team 5UQY3B3594).
pkgutil --check-signature $T/Install-Jitouch.pkg | grep -q "Developer ID Installer: Aaron Kollasch (5UQY3B3594)" ||
  { echo "Release package signature check failed" >&2; exit 1; }
pkgutil --expand-full $T/Install-Jitouch.pkg $T/x
mkdir -p build
cp -R $T/x/JitouchPrefpane.pkg/Payload/Jitouch.prefPane build/
rm -rf $T
echo "Fetched official Jitouch v2.82.1 bundle into build/Jitouch.prefPane"

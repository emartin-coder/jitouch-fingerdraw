#!/bin/zsh
# Builds the downloadable installer: build/release/Jitouch-FingerDraw-<version>.pkg
# Like the official Jitouch installer, it puts Jitouch.prefPane (with this fork's app inside) in /Library/PreferencePanes.
# Opening the panel once sets Jitouch to start at login. Unsigned (no Developer ID), Apple silicon only.
# Usage: tools/make-release.sh 0.1.0
set -euo pipefail
cd "${0:A:h}/.."
VERSION=${1:?usage: tools/make-release.sh <version>}
R=build/release
./build.sh --no-install

rm -rf $R && mkdir -p $R/root
cp -R build/Jitouch.prefPane $R/root/
rm -rf $R/root/Jitouch.prefPane/Contents/Resources/Jitouch.app
cp -R build/Jitouch.app $R/root/Jitouch.prefPane/Contents/Resources/Jitouch.app
xattr -cr $R/root   # drop this Mac's local file attributes (com.apple.provenance) so they don't ship
# Ad-hoc signature, never a personal local certificate.
codesign --force --deep --sign - $R/root/Jitouch.prefPane
codesign --verify --deep --strict $R/root/Jitouch.prefPane

# Always install exactly to /Library/PreferencePanes, even if another Jitouch copy exists elsewhere or claims the same version.
pkgbuild --analyze --root $R/root $R/components.plist >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO $R/components.plist
plutil -replace 0.BundleIsVersionChecked -bool NO $R/components.plist
PKG=$R/Jitouch-FingerDraw-$VERSION.pkg
pkgbuild --root $R/root --component-plist $R/components.plist --install-location /Library/PreferencePanes \
  --identifier io.github.emartin-coder.jitouch-fingerdraw --version $VERSION $PKG
shasum -a 256 $PKG | tee $PKG.sha256

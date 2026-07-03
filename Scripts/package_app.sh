#!/usr/bin/env bash
# package_app.sh — build clauthbar.app, a real menu-bar app bundle.
#
# Produces build/clauthbar.app (LSUIElement, ad-hoc signed for local use). Drag
# it to /Applications and add it to Login Items, or run it directly:
#   open build/clauthbar.app
#
# For distribution, re-sign with a Developer ID identity + notarize (deferred).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "clauthbar: building release…"
swift build -c release

app="build/clauthbar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp ".build/release/clauthbar" "$app/Contents/MacOS/clauthbar"
cp "Scripts/Info.plist" "$app/Contents/Info.plist"

# Ad-hoc signature so Gatekeeper lets a locally-built app run.
codesign --force --sign - "$app"

echo "clauthbar: built $app"
echo "  run:      open $app"
echo "  install:  cp -R $app /Applications/  (then add to Login Items)"

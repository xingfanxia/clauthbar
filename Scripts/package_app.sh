#!/usr/bin/env bash
# package_app.sh — build ccsbar.app, a real menu-bar app bundle.
#
# Produces build/ccsbar.app (LSUIElement, ad-hoc signed for local use). Drag
# it to /Applications and launch it once — it registers for autostart itself via
# SMAppService (toggle off with "Start at login" in the panel), or run it directly:
#   open build/ccsbar.app
#
# For distribution, re-sign with a Developer ID identity + notarize (deferred).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# The bundle id in Info.plist is load-bearing: AppBundle.isMainApp gates
# notifications + login-item registration on this EXACT string. If they drift, the
# shipped app silently loses both with a green test suite — fail the build instead.
expected_bundle_id="com.xingfanxia.ccsbar"
if ! grep -q "$expected_bundle_id" Scripts/Info.plist; then
  echo "package_app.sh: Info.plist CFBundleIdentifier != $expected_bundle_id" >&2
  echo "  (must match AppBundle.mainAppID in Sources/CCSBarKit/AppBundle.swift)" >&2
  exit 1
fi

echo "ccsbar: building release…"
swift build -c release

app="build/ccsbar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp ".build/release/ccsbar" "$app/Contents/MacOS/ccsbar"
cp "Scripts/Info.plist" "$app/Contents/Info.plist"

# Provider brand glyphs (TABS-1.2) ship as loose Resources files —
# ProviderGlyph loads them via Bundle.main. Deliberately NOT the whole SPM
# resource bundle: the fixtures in it are dev-only and must not ship.
cp Sources/CCSBarKit/Resources/ProviderIcon-*.svg "$app/Contents/Resources/"

# Ad-hoc signature so Gatekeeper lets a locally-built app run.
codesign --force --sign - "$app"

echo "ccsbar: built $app"
echo "  run:      open $app"
echo "  install:  cp -R $app /Applications/ && open /Applications/ccsbar.app"
echo "            (it registers for autostart automatically; toggle via Start at login)"

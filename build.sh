#!/bin/bash
# Builds MenuHub.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MenuHub"

APP=build/MenuHub.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MenuHub"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# A stable identity keeps the Accessibility grant across rebuilds; ad-hoc signing loses it.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
codesign --force --sign "${IDENTITY:--}" "$APP"

mkdir -p ~/Applications
pkill -x MenuHub 2>/dev/null || true
rm -rf ~/Applications/MenuHub.app
cp -R "$APP" ~/Applications/
echo "Terpasang di ~/Applications/MenuHub.app"

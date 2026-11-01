#!/bin/bash
# Builds the command-line tool (./beatlight) and the menu bar app (./Beatlight.app).
# Needs Apple's Command Line Tools: xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

CFLAGS=(-fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=13.0)
FRAMEWORKS=(-framework Foundation -framework Accelerate -framework AVFoundation -framework CoreGraphics
            -framework CoreMedia -framework IOKit -framework ScreenCaptureKit)

clang "${CFLAGS[@]}" -o beatlight beatlight.m engine.m "${FRAMEWORKS[@]}"
echo "Built ./beatlight"

# Quit a running copy of the app first (it restores the backlight on quit).
pkill -x Beatlight 2>/dev/null && sleep 1 || true

APP=Beatlight.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
clang "${CFLAGS[@]}" -o "$APP/Contents/MacOS/Beatlight" app.m engine.m "${FRAMEWORKS[@]}" \
  -framework Cocoa -framework ServiceManagement
codesign --force --sign - "$APP"   # ad-hoc signature: required on Apple Silicon, ties permissions to the app
echo "Built ./$APP — start it with: open $APP"

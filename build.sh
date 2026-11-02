#!/bin/bash
# Builds the command-line tool (./beatlight) and the menu bar app (./Beatlight.app).
# Needs Apple's Command Line Tools: xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

# Use the Command Line Tools' own compiler, linker and SDK when they're installed. If
# xcode-select points at an older Xcode, its linker can't read a newer Command Line Tools
# SDK ("tapi error: malformed file ... unknown architecture").
if [[ -z "${DEVELOPER_DIR:-}" && -d /Library/Developer/CommandLineTools/usr/bin ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

CFLAGS=(-fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=13.0)
FRAMEWORKS=(-framework Foundation -framework Accelerate -framework AVFoundation -framework CoreGraphics
            -framework CoreMedia -framework IOKit -framework ScreenCaptureKit)

clang "${CFLAGS[@]}" -o beatlight beatlight.m engine.m orgb.c "${FRAMEWORKS[@]}"
echo "Built ./beatlight"

# Quit a running copy of the app first (it restores the backlight on quit).
pkill -x Beatlight 2>/dev/null && sleep 1 || true

APP=Beatlight.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
clang "${CFLAGS[@]}" -o "$APP/Contents/MacOS/Beatlight" app.m engine.m orgb.c "${FRAMEWORKS[@]}" \
  -framework Cocoa -framework ServiceManagement
# Sign with a stable identity when one exists, so macOS keeps Beatlight's permissions across
# rebuilds. An ad-hoc signature changes on every build, and macOS then treats it as a new app
# and asks for Screen & System Audio Recording again. Override with BEATLIGHT_SIGN_IDENTITY.
IDENTITY="${BEATLIGHT_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
             | awk -F'"' '/Beatlight Local|Apple Development/ { print $2; exit }' || true)
fi
codesign --force --sign "${IDENTITY:--}" "$APP"
if [[ -n "$IDENTITY" ]]; then
  echo "Signed with \"$IDENTITY\" (permissions carry over to future builds)"
else
  echo "Signed ad-hoc: macOS will ask for permission again after every rebuild."
  echo "  To stop that, create a \"Beatlight Local\" code-signing certificate (see README > Permissions keep coming back)."
fi
echo "Built ./$APP — start it with: open $APP"

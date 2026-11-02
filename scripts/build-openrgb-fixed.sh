#!/bin/bash
# Builds OpenRGB 1.1 with a one-line macOS fix, then installs it in /Applications.
# Needed for Logitech devices behind a LIGHTSPEED or POWERPLAY receiver (see README).
#
# The bug: OpenRGB's "Logitech HID++ 2.0" detector skips devices behind a receiver
# (G502 LIGHTSPEED, POWERPLAY mat) when an older detector "owns" them. It treats a
# detector that is missing from the settings as enabled, but on macOS those older
# detectors don't exist at all, so the devices are skipped and nothing drives them.
# The fix treats a missing detector as not owning anything. OpenRGB adds every detector
# that does exist on the platform to the settings before detection, so this is safe.
#
# Takes ~20-30 minutes, mostly downloading Qt and compiling.
# The original app is kept at ~/OpenRGB-fixed/OpenRGB-original.app.
set -euo pipefail

WORK="$HOME/OpenRGB-fixed"
SRC="$WORK/src"
FILE="Controllers/LogitechController/LogitechControllerDetect.cpp"

if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif command -v brew >/dev/null; then
  eval "$(brew shellenv)"
else
  echo "Install Homebrew first: https://brew.sh" >&2
  exit 1
fi

echo "==> Installing build dependencies with Homebrew"
brew install qt hidapi libusb mbedtls@3 pkg-config

echo "==> Getting OpenRGB 1.1 source"
mkdir -p "$WORK"
if [[ -d "$SRC/.git" ]]; then
  git -C "$SRC" checkout -- .
else
  git clone --depth 1 --branch release_1.1 https://github.com/CalcProgrammer1/OpenRGB.git "$SRC"
fi
cd "$SRC"

echo "==> Applying the fix"
python3 - "$FILE" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''        return(detector_settings["detectors"][detector_name]);
    }

    return(true);
}'''
new = '''        return(detector_settings["detectors"][detector_name]);
    }

    /* Missing from the settings means this detector isn't built on this platform (every
       detector that exists is added before detection runs), so it can't own the device. */
    return(false);
}'''
if s.count(old) != 1:
    sys.exit("Couldn't find the code to patch; OpenRGB's source may have changed.")
open(p, "w").write(s.replace(old, new))
print("Patched", p)
EOF

echo "==> Building (the slow part)"
qmake OpenRGB.pro
make -j"$(sysctl -n hw.ncpu)"

echo "==> Bundling Qt and signing"
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
           | awk -F'"' '/Beatlight Local|Apple Development/ { print $2; exit }' || true)
macdeployqt OpenRGB.app -codesign="${IDENTITY:--}"
macdeployqt OpenRGB.app -codesign="${IDENTITY:--}"   # second pass, as OpenRGB's own build does

echo "==> Installing"
osascript -e 'quit app "OpenRGB"' 2>/dev/null || true
sleep 2
if [[ -d /Applications/OpenRGB.app && ! -d "$WORK/OpenRGB-original.app" ]]; then
  mv /Applications/OpenRGB.app "$WORK/OpenRGB-original.app"
else
  rm -rf /Applications/OpenRGB.app
fi
cp -R OpenRGB.app /Applications/
echo
echo "Done. Open OpenRGB: the G502 and the POWERPLAY mat should both be listed."
echo "To go back: rm -rf /Applications/OpenRGB.app && mv \"$WORK/OpenRGB-original.app\" /Applications/OpenRGB.app"

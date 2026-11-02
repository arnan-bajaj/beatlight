#!/bin/bash
# One-time setup, after building Beatlight and installing OpenRGB:
#   - a hidden OpenRGB server (no window) that runs only while you use Beatlight
#   - a "Beatlight" launcher in /Applications that starts the server and opens Beatlight
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTL="$ROOT/scripts/beatlight-ctl.sh"
LAUNCHER=/Applications/Beatlight.app
LABEL=com.arnanbajaj.openrgb-server
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[[ -d /Applications/OpenRGB.app ]] || { echo "Install OpenRGB in /Applications first." >&2; exit 1; }
[[ -d "$ROOT/Beatlight.app" ]]     || { echo "Build Beatlight first: bash build.sh" >&2; exit 1; }
if [[ -e "$LAUNCHER" && ! -f "$LAUNCHER/Contents/Resources/Scripts/main.scpt" ]]; then
  echo "$LAUNCHER exists and isn't a launcher made by this script; move it out of /Applications first." >&2
  exit 1
fi
chmod +x "$CTL"

echo "==> Hidden OpenRGB server (starts only when you launch Beatlight)"
launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
for _ in $(seq 20); do   # unloading finishes in the background; loading again too early fails with error 5
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done
pkill -xf /Applications/OpenRGB.app/Contents/MacOS/OpenRGB 2>/dev/null || true   # close the OpenRGB window
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/OpenRGB.app/Contents/MacOS/OpenRGB</string>
        <string>--server</string>
        <string>--noautoconnect</string>
    </array>
    <key>RunAtLoad</key><false/>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
plutil -lint -s "$PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl print "$DOMAIN/$LABEL" >/dev/null

echo "==> Beatlight launcher in /Applications"
rm -rf "$LAUNCHER"
osacompile -o "$LAUNCHER" -e "do shell script \"/bin/bash \" & quoted form of \"$CTL\" & \" start\""

echo
echo "Done. Open Beatlight from Applications or Spotlight to start Beatlight and the OpenRGB server."

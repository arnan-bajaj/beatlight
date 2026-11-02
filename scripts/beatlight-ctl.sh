#!/bin/bash
# Starts and stops Beatlight together with a hidden OpenRGB server (no window, no Dock icon).
# The Beatlight launcher that scripts/setup-launcher.sh puts in /Applications runs "start".
#   scripts/beatlight-ctl.sh start | stop | settings
set -u
LABEL=com.arnanbajaj.openrgb-server
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$(cd "$(dirname "$0")/.." && pwd)/Beatlight.app"
OPENRGB_GUI="/Applications/OpenRGB.app/Contents/MacOS/OpenRGB"

load_server() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || launchctl bootstrap "$DOMAIN" "$PLIST"
}
stop_server() {
  launchctl kill SIGTERM "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
}

case "${1:-}" in
  start)
    # The OpenRGB window and the hidden server can't both run: close the window first.
    if pkill -xf "$OPENRGB_GUI" 2>/dev/null; then sleep 2; fi
    load_server
    launchctl kickstart "$DOMAIN/$LABEL"
    open "$APP"
    ;;
  stop)
    # Beatlight puts your lights back (through OpenRGB) as it quits, so stop it first.
    if pkill -x Beatlight 2>/dev/null; then sleep 3; fi
    stop_server
    ;;
  settings)
    # Opens the OpenRGB window to change device settings; "start" goes back to the hidden server.
    stop_server
    sleep 2
    open -a OpenRGB
    ;;
  *)
    echo "usage: $0 start | stop | settings" >&2
    exit 2
    ;;
esac

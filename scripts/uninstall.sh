#!/bin/bash
# Uninstall DockAwake and restore normal sleep behavior.
set -euo pipefail

APP_DST="$HOME/Applications/DockAwake.app"
HELPER_DST="/Library/PrivilegedHelperTools/dockawake-pmset"
SUDOERS_DST="/etc/sudoers.d/dockawake"

osascript -e 'tell application "DockAwake" to quit' 2>/dev/null || true
sleep 1

echo "==> Removing login item"
"$APP_DST/Contents/MacOS/DockAwake" --unregister-login-item 2>/dev/null || true

echo "==> Restoring normal sleep"
sudo /usr/bin/pmset -a disablesleep 0

echo "==> Removing files (sudo required)"
sudo rm -f "$SUDOERS_DST" "$HELPER_DST"
rm -rf "$APP_DST"

pmset -g | grep SleepDisabled || echo "SleepDisabled cleared"
echo "Done."

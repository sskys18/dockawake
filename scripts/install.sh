#!/bin/bash
# Install DockAwake: app -> ~/Applications, helper -> /Library/PrivilegedHelperTools,
# narrow NOPASSWD sudoers rule -> /etc/sudoers.d/dockawake.
# Requires administrator authentication once, during install only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
HELPER_DST="/Library/PrivilegedHelperTools/dockawake-pmset"
SUDOERS_DST="/etc/sudoers.d/dockawake"
APP_DST="$HOME/Applications/DockAwake.app"
INSTALL_USER="$(id -un)"

"$ROOT/scripts/build.sh"

echo "==> Installing app to $APP_DST"
mkdir -p "$HOME/Applications"
rm -rf "$APP_DST"
cp -R "$BUILD/DockAwake.app" "$APP_DST"

echo "==> Installing privileged helper (sudo required)"
sudo mkdir -p /Library/PrivilegedHelperTools
sudo install -o root -g wheel -m 755 "$BUILD/dockawake-pmset" "$HELPER_DST"

echo "==> Installing sudoers rule"
SUDOERS_TMP="$(mktemp)"
cat > "$SUDOERS_TMP" <<EOF
$INSTALL_USER ALL=(root) NOPASSWD: $HELPER_DST on, $HELPER_DST off
EOF
visudo -c -f "$SUDOERS_TMP" >/dev/null
sudo install -o root -g wheel -m 440 "$SUDOERS_TMP" "$SUDOERS_DST"
rm -f "$SUDOERS_TMP"

echo "==> Verifying passwordless helper access"
sudo -n "$HELPER_DST" off
pmset -g | grep SleepDisabled

echo "==> Launching DockAwake"
open "$APP_DST"

echo "Done. Click the DockAwake icon in the Dock to toggle keep-awake."

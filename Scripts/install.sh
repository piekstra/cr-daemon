#!/bin/bash
set -euo pipefail

# Build, install to ~/Applications (Spotlight-indexed), and load the LaunchAgent.
# launchd keeps cr-daemon alive across crashes and relaunches it at login.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="cr-daemon"
LABEL="com.piekstra.cr-daemon"
INSTALL_DIR="$HOME/Applications"
APP="$INSTALL_DIR/${APP_NAME}.app"
LA_DIR="$HOME/Library/LaunchAgents"
PLIST="$LA_DIR/${LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/cr-daemon"

"$SCRIPT_DIR/make-app.sh"

echo "==> stopping any running instance"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

echo "==> installing to $APP"
mkdir -p "$INSTALL_DIR" "$LA_DIR" "$LOG_DIR"
rm -rf "$APP"
cp -R "$ROOT/build/${APP_NAME}.app" "$APP"

echo "==> writing LaunchAgent $PLIST"
EXEC="$APP/Contents/MacOS/$APP_NAME"
sed -e "s|__EXEC_PATH__|$EXEC|g" -e "s|__LOG_DIR__|$LOG_DIR|g" \
    "$ROOT/Scripts/${LABEL}.plist" > "$PLIST"

echo "==> loading LaunchAgent"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true

mdimport "$INSTALL_DIR" >/dev/null 2>&1 || true

cat <<EOF

Installed. Look for the cr-daemon icon in your menu bar.
  • Spotlight: ⌘-Space → "cr-daemon"
  • Config:    ~/Library/Application Support/cr-daemon/config.json
  • Logs:      $LOG_DIR
  • Uninstall: $SCRIPT_DIR/uninstall.sh

First run? Stage the reviewer identity: $SCRIPT_DIR/setup-reviewer.sh
EOF

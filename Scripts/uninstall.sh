#!/bin/bash
set -euo pipefail

# Remove the LaunchAgent and the app. Leaves config/state/logs in place so a
# reinstall resumes where you left off (delete ~/Library/Application Support/
# cr-daemon manually for a clean slate).

LABEL="com.piekstra.cr-daemon"
APP="$HOME/Applications/cr-daemon.app"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

echo "==> unloading LaunchAgent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo "==> removing app"
rm -rf "$APP"

echo "uninstalled. Runtime data kept at ~/Library/Application Support/cr-daemon"

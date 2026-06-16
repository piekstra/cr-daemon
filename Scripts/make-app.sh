#!/bin/bash
set -euo pipefail

# Build cr-daemon (release) and assemble it into an ad-hoc-signed .app bundle.
# SwiftPM emits a bare binary; this wraps it with Info.plist (LSUIElement) so it
# runs as a menu-bar-only app. No full Xcode required.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="cr-daemon"
BUILD_DIR="$ROOT/build"
BUNDLE="$BUILD_DIR/${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release --package-path "$ROOT"
BIN_DIR="$(swift build -c release --package-path "$ROOT" --show-bin-path)"

echo "==> assembling ${APP_NAME}.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"

# Ad-hoc signature (required on Apple Silicon to run). Not notarized — this is a
# local, single-user build. See README "Signing & Gatekeeper".
echo "==> ad-hoc codesign"
codesign --force --sign - "$BUNDLE"

echo "built: $BUNDLE"

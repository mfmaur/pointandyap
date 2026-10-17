#!/bin/bash
# Builds Point.app, signs it with the Developer ID in CODESIGN_IDENTITY (hardened runtime) and installs it to /Applications.
# Usage: POINT_ENV=/path/to/.env bash scripts/build.sh   (the file must define CODESIGN_IDENTITY)
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${POINT_ENV:-/Users/marcmaur/000_Doppelganger/.env}"
set -a; . "$ENV_FILE"; set +a
: "${CODESIGN_IDENTITY:?CODESIGN_IDENTITY missing}"

swift build -c release
APP=build/Point.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Point "$APP/Contents/MacOS/Point"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --timestamp --entitlements Resources/Point.entitlements \
  --sign "$CODESIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if pgrep -x Point >/dev/null; then pkill -x Point; sleep 1; fi
rm -rf /Applications/Point.app
cp -R "$APP" /Applications/Point.app
echo "installed /Applications/Point.app"

#!/bin/bash
# Builds Point.app, signs it with the Developer ID in CODESIGN_IDENTITY (hardened runtime) and installs it to /Applications.
# Usage: bash scripts/build.sh   (CODESIGN_IDENTITY from the environment, else from POINT_ENV or the workspace .env)
# POINT_NO_INSTALL=1 stops after signing (scripts/release.sh); POINT_VERSION sets the version in the bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  ENV_FILE="${POINT_ENV:-/Users/marcmaur/000_Doppelganger/.env}"
  set -a; . "$ENV_FILE"; set +a
fi
: "${CODESIGN_IDENTITY:?CODESIGN_IDENTITY missing}"

swift build -c release
APP=build/Point.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Point "$APP/Contents/MacOS/Point"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${POINT_VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$POINT_VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$(date +%s)" "$APP/Contents/Info.plist"
fi
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/Fonts/* "$APP/Contents/Resources/Fonts/"
cp -R Resources/skill "$APP/Contents/Resources/"
cp -R Resources/Sounds "$APP/Contents/Resources/"
codesign --force --options runtime --timestamp --entitlements Resources/Point.entitlements \
  --sign "$CODESIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
[ -n "${POINT_NO_INSTALL:-}" ] && { echo "built $APP"; exit 0; }

# Never quit Point in the middle of a recording: the newest session has no events.json while its audio is still written.
latest=$(ls -1d "$HOME"/Point/sessions/*/ 2>/dev/null | tail -1)
if [ -n "$latest" ] && [ ! -f "$latest/events.json" ] && [ -f "$latest/audio.caf" ] \
   && [ $(( $(date +%s) - $(stat -f %m "$latest/audio.caf") )) -lt 30 ]; then
  echo "Point is recording; not reinstalling now. Run again after Stop." >&2; exit 1
fi
if pgrep -x Point >/dev/null; then pkill -x Point; sleep 1; fi
rm -rf /Applications/Point.app
cp -R "$APP" /Applications/Point.app
echo "installed /Applications/Point.app"

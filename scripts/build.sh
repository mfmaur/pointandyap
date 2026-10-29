#!/bin/bash
# Builds "Point and Yap.app", signs it with the Developer ID in CODESIGN_IDENTITY (hardened runtime) and installs it to
# /Applications. Usage: bash scripts/build.sh   (CODESIGN_IDENTITY from the environment, or from the env file named by
# POINTANDYAP_ENV). POINTANDYAP_NO_INSTALL=1 stops after signing (scripts/release.sh); POINTANDYAP_VERSION sets the version.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${CODESIGN_IDENTITY:-}" ] && [ -n "${POINTANDYAP_ENV:-}" ]; then
  set -a; . "$POINTANDYAP_ENV"; set +a
fi
: "${CODESIGN_IDENTITY:?CODESIGN_IDENTITY missing (export it, or set POINTANDYAP_ENV to a file that defines it)}"

swift build -c release
APP="build/Point and Yap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/PointAndYap "$APP/Contents/MacOS/PointAndYap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${POINTANDYAP_VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$POINTANDYAP_VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$(date +%s)" "$APP/Contents/Info.plist"
fi
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/Fonts/* "$APP/Contents/Resources/Fonts/"
cp -R Resources/skill "$APP/Contents/Resources/"
cp -R Resources/Sounds "$APP/Contents/Resources/"
cp -R Resources/live "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Welcome"
cp Resources/Welcome/welcome.mp4 Resources/Welcome/welcome-poster.png "$APP/Contents/Resources/Welcome/"
# Sparkle (updates), signed from the inside out as its documentation asks for apps built outside Xcode.
mkdir -p "$APP/Contents/Frameworks"
ditto .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
F="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$@"; }
sign "$F/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$F/XPCServices/Downloader.xpc"
sign "$F/Autoupdate"
sign "$F/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --timestamp --entitlements Resources/PointAndYap.entitlements \
  --sign "$CODESIGN_IDENTITY" "$APP"
# A local build signed ad hoc (CODESIGN_IDENTITY=-) has no Team ID, and the hardened runtime then refuses to load
# Sparkle: sign the whole bundle again without it.
if [ "$CODESIGN_IDENTITY" = "-" ]; then codesign --force --deep --sign - "$APP"; fi
codesign --verify --strict --verbose=2 "$APP"
[ -n "${POINTANDYAP_NO_INSTALL:-}" ] && { echo "built $APP"; exit 0; }

# Never quit the app in the middle of a recording: the newest session has no events.json while its audio is still
# written. (~/Point is where builds before 0.1.1 kept recordings.)
for dir in "$HOME/PointAndYap/sessions" "$HOME/Point/sessions"; do
  latest=$(ls -1d "$dir"/*/ 2>/dev/null | tail -1 || true)
  if [ -n "$latest" ] && [ ! -f "$latest/events.json" ] && [ -f "$latest/audio.caf" ] \
     && [ $(( $(date +%s) - $(stat -f %m "$latest/audio.caf") )) -lt 30 ]; then
    echo "Point and Yap is recording; not reinstalling now. Run again after Stop." >&2; exit 1
  fi
done
for name in PointAndYap Point; do
  if pgrep -x "$name" >/dev/null; then pkill -x "$name"; sleep 1; fi
done
rm -rf "/Applications/Point and Yap.app" /Applications/Point.app
cp -R "$APP" "/Applications/Point and Yap.app"
echo "installed /Applications/Point and Yap.app"

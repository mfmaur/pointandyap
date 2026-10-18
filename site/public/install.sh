#!/bin/sh
# Point and Yap installer: curl -fsSL https://pointandyap.com/install.sh | sh
# Downloads the latest notarized DMG from GitHub Releases, checks Apple's notarization, copies the app to /Applications.
set -eu
REPO="mfmaur/pointandyap"
URL="https://github.com/$REPO/releases/latest/download/PointAndYap.dmg"

say() { printf '%s\n' "$*"; }
fail() { say "Point and Yap: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "this is a Mac app."
[ "$(uname -m)" = "arm64" ] || fail "it needs a Mac with Apple silicon."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 26 ] || fail "it needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."

tmp=$(mktemp -d)
mnt="$tmp/mnt"
cleanup() { hdiutil detach -quiet "$mnt" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

say "Downloading Point and Yap…"
curl -fL --progress-bar -o "$tmp/PointAndYap.dmg" "$URL" || fail "the download failed ($URL)."
mkdir -p "$mnt"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$tmp/PointAndYap.dmg" || fail "could not open the disk image."
app=$(find "$mnt" -maxdepth 1 -name "*.app" | head -n 1)
[ -n "$app" ] || fail "no app in the disk image."
name=$(basename "$app")
spctl --assess --type execute "$app" 2>/dev/null || fail "macOS did not accept the app's signature; nothing was installed."

if pgrep -qx PointAndYap || pgrep -qx Point || pgrep -qf "/Applications/$name/"; then
  say "Quitting the running Point and Yap…"
  osascript -e "quit app \"${name%.app}\"" 2>/dev/null || true
  pkill -x Point 2>/dev/null || true   # the app before 0.1.1
  sleep 1
fi
dest="/Applications/$name"
old="/Applications/Point.app"   # the name before 0.1.1
if [ -w /Applications ]; then rm -rf "$dest" "$old"; ditto "$app" "$dest"
else say "Copying to /Applications needs your password."; sudo rm -rf "$dest" "$old"; sudo ditto "$app" "$dest"; fi

say "Installed $dest"
open "$dest"

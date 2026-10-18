#!/bin/bash
# Builds a release: sign (Developer ID), notarize and staple the app, PointAndYap.dmg (signed, notarized, stapled),
# then a DRAFT GitHub release with the DMG. The site's Download button reads published releases only, so a draft
# changes nothing until it is published on GitHub.
# Usage: bash scripts/release.sh 0.1.0   (keys from the environment, or from the file named by POINTANDYAP_ENV:
# CODESIGN_IDENTITY, APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID, APP_STORE_CONNECT_KEY_PATH)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: release.sh <version>}"
if [ -z "${APP_STORE_CONNECT_KEY_ID:-}" ] && [ -n "${POINTANDYAP_ENV:-}" ]; then
  set -a; . "$POINTANDYAP_ENV"; set +a
fi
: "${CODESIGN_IDENTITY:?}" "${APP_STORE_CONNECT_KEY_ID:?}" "${APP_STORE_CONNECT_ISSUER_ID:?}" "${APP_STORE_CONNECT_KEY_PATH:?}"
grep -q "^## $VERSION" CHANGELOG.md || { echo "CHANGELOG.md has no '## $VERSION' section" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit first: the release is tagged at HEAD" >&2; exit 1; }
git fetch -q origin
git branch -r --contains HEAD | grep -q . || { echo "push HEAD first" >&2; exit 1; }

notarize() {
  xcrun notarytool submit "$1" --key "$APP_STORE_CONNECT_KEY_PATH" --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" --wait --timeout 30m | tee build/notary.log
  grep -q "status: Accepted" build/notary.log || { echo "notarization failed for $1" >&2; exit 1; }
}

POINTANDYAP_NO_INSTALL=1 POINTANDYAP_VERSION="$VERSION" bash scripts/build.sh
APP="build/Point and Yap.app"

# The app itself, so it stays valid offline once copied out of the DMG.
rm -f build/PointAndYap.zip
ditto -c -k --keepParent "$APP" build/PointAndYap.zip
notarize build/PointAndYap.zip
xcrun stapler staple "$APP"

# The disk image: the app, a link to Applications, the background and the window layout (scripts/dmg).
DMG=build/PointAndYap.dmg
STAGE=build/dmg
MNT=build/dmg-mount
rm -rf "$STAGE" "$DMG" build/dmg-rw.dmg build/dmg-bg
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swift scripts/dmg/background.swift build/dmg-bg
tiffutil -cathidpicheck build/dmg-bg/background.png build/dmg-bg/background@2x.png -out "$STAGE/.background/background.tiff"
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
[ -x build/dmg-tools/bin/python ] || { python3 -m venv build/dmg-tools && build/dmg-tools/bin/pip install -q ds-store==1.3.1 mac-alias==2.2.2; }
# The volume name must be free while building, or the layout's alias names the wrong volume.
[ ! -e "/Volumes/Point and Yap" ] || { echo "eject the mounted Point and Yap volume first" >&2; exit 1; }
hdiutil create -volname "Point and Yap" -srcfolder "$STAGE" -ov -fs HFS+ -format UDRW -quiet build/dmg-rw.dmg
mkdir -p "$MNT"
hdiutil attach build/dmg-rw.dmg -readwrite -noverify -noautoopen -nobrowse -mountpoint "$MNT" -quiet
build/dmg-tools/bin/python -I scripts/dmg/layout.py "$MNT" "Point and Yap.app"
SetFile -a C "$MNT"
SetFile -a V "$MNT/.background" "$MNT/.VolumeIcon.icns" "$MNT/.DS_Store"
hdiutil detach "$MNT" -quiet
hdiutil convert build/dmg-rw.dmg -format UDZO -ov -quiet -o "$DMG"
rm -f build/dmg-rw.dmg
codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

# Notes: the version's CHANGELOG section.
awk -v v="## $VERSION" '$0 ~ "^"v {on=1; next} on && /^## / {exit} on' CHANGELOG.md > build/notes.md
TAG="v$VERSION"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" --clobber
else
  gh release create "$TAG" "$DMG" --draft --target "$(git rev-parse HEAD)" \
    --title "Point and Yap $VERSION" --notes-file build/notes.md
fi
echo "draft release $TAG with $DMG"

#!/bin/bash
# Builds a release: sign (Developer ID), notarize and staple the app, PointAndYap.dmg (signed, notarized, stapled),
# then a DRAFT GitHub release with the DMG. The site's Download button reads published releases only, so a draft
# changes nothing until it is published on GitHub.
# Usage: bash scripts/release.sh 0.1.0   (keys from the environment, else POINT_ENV or the workspace .env:
# CODESIGN_IDENTITY, APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID, APP_STORE_CONNECT_KEY_PATH)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: release.sh <version>}"
if [ -z "${APP_STORE_CONNECT_KEY_ID:-}" ]; then
  ENV_FILE="${POINT_ENV:-/Users/marcmaur/000_Doppelganger/.env}"
  set -a; . "$ENV_FILE"; set +a
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

POINT_NO_INSTALL=1 POINT_VERSION="$VERSION" bash scripts/build.sh
APP=build/Point.app

# The app itself, so it stays valid offline once copied out of the DMG.
rm -f build/Point.zip
ditto -c -k --keepParent "$APP" build/Point.zip
notarize build/Point.zip
xcrun stapler staple "$APP"

DMG=build/PointAndYap.dmg
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Point and Yap" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
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

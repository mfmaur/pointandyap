#!/bin/bash
# Publishes a release that scripts/release.sh drafted: the GitHub release goes live, then the appcast at
# pointandyap.com/appcast.xml offers it to every installed copy (Sparkle downloads it in the background), then the
# Homebrew cask follows. The appcast's EdDSA signature comes from the key in the login Keychain (account pointandyap).
# Usage: bash scripts/publish.sh 0.1.2   (run on main, right after release.sh, with build/ from that run)
# Needs: gh logged in; CLOUDFLARE_API_TOKEN for the site deploy (from the environment or POINTANDYAP_ENV).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: publish.sh <version>}"
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] && [ -n "${POINTANDYAP_ENV:-}" ]; then
  set -a; . "$POINTANDYAP_ENV"; set +a
fi
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN missing (export it, or set POINTANDYAP_ENV)}"
APP="build/Point and Yap.app"
DMG=build/PointAndYap.dmg
TAG="v$VERSION"
PLIST="$APP/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$VERSION" ] \
  || { echo "build/ holds another version; run scripts/release.sh $VERSION first" >&2; exit 1; }
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")

# The draft must carry this very DMG.
RID=$(gh api "repos/mfmaur/pointandyap/releases" --jq ".[] | select(.tag_name==\"$TAG\") | .id")
[ -n "$RID" ] || { echo "no release $TAG" >&2; exit 1; }
REMOTE=$(gh api "repos/mfmaur/pointandyap/releases/$RID" --jq '.assets[] | select(.name=="PointAndYap.dmg") | .size')
[ "$REMOTE" = "$(stat -f %z "$DMG")" ] || { echo "the release's DMG differs from $DMG" >&2; exit 1; }

# 1. GitHub: the release goes live, at the commit build/ was made from.
gh api -X PATCH "repos/mfmaur/pointandyap/releases/$RID" -f target_commitish="$(git rev-parse HEAD)" \
  -F draft=false -f make_latest=true --jq '"published \(.tag_name)"'
for _ in $(seq 1 24); do
  [ "$(curl -sIL -o /dev/null -w '%{http_code}' "https://github.com/mfmaur/pointandyap/releases/download/$TAG/PointAndYap.dmg")" = 200 ] && break
  sleep 5
done

# 2. The appcast: one item, the newest version.
# The signing key: the file POINTANDYAP_SPARKLE_KEY names (no Keychain prompt), else the login Keychain (account pointandyap).
if [ -n "${POINTANDYAP_SPARKLE_KEY:-}" ]; then KEY=(--ed-key-file "$POINTANDYAP_SPARKLE_KEY"); else KEY=(--account pointandyap); fi
SIG=$(.build/artifacts/sparkle/Sparkle/bin/sign_update "${KEY[@]}" "$DMG")   # sparkle:edSignature="…" length="…"
cat > site/public/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Point and Yap</title>
    <link>https://pointandyap.com</link>
    <item>
      <title>Point and Yap $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/mfmaur/pointandyap/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/mfmaur/pointandyap/releases/download/$TAG/PointAndYap.dmg" $SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
(cd site && env -u CLOUDFLARE_ACCOUNT_ID npx --yes wrangler@4 deploy >/dev/null) && echo "appcast live: $VERSION (build $BUILD)"
git add site/public/appcast.xml
git commit -qm "Appcast: $VERSION" && git push -q origin HEAD

# 3. Homebrew.
bash scripts/update-cask.sh "$VERSION" "$DMG"

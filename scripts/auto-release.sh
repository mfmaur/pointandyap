#!/bin/bash
# Releases automatically: when main's CHANGELOG.md starts with a version (## 0.1.5) that has no release yet and is newer
# than the latest one, runs release.sh and publish.sh for it. Merging a PR that renames "## Unreleased" to a version is
# how a release is made. Meant for a LaunchAgent every 15 minutes on the maintainer's Mac (keys stay on that Mac).
# Works in its own clone so it never touches a checkout someone is working in.
# Env: POINTANDYAP_RELEASE_DIR (the clone; default ~/Library/Application Support/PointAndYap-release/repo), plus what
# release.sh and publish.sh need (POINTANDYAP_ENV, POINTANDYAP_SPARKLE_KEY). --dry-run says what it would do.
set -euo pipefail
# All in one function: bash reads it whole before running, so the git reset below may rewrite this file safely.
main() {
REPO="mfmaur/pointandyap"
DIR="${POINTANDYAP_RELEASE_DIR:-$HOME/Library/Application Support/PointAndYap-release/repo}"
LOCK="$(dirname "$DIR")/.lock"
DRY="${1:-}"
say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
notify() { osascript -e "display notification \"$1\" with title \"Point and Yap release\"" 2>/dev/null || true; }

mkdir -p "$(dirname "$DIR")"
mkdir "$LOCK" 2>/dev/null || { say "another run holds $LOCK"; exit 0; }
trap 'rmdir "$LOCK"' EXIT

[ -d "$DIR/.git" ] || git clone -q "https://github.com/$REPO.git" "$DIR"
cd "$DIR"
git fetch -q origin --tags
git checkout -q main
git reset -q --hard origin/main   # this clone is the job's own; nothing is ever edited here by hand

VERSION=$(sed -n 's/^## \([0-9][0-9.]*\)$/\1/p' CHANGELOG.md | head -1)
LATEST=$(gh api "repos/$REPO/releases/latest" --jq .tag_name 2>/dev/null | sed 's/^v//' || true)
[ -n "$VERSION" ] || { say "no version at the top of CHANGELOG.md"; exit 0; }
if [ "$VERSION" = "$LATEST" ] || [ "$(printf '%s\n%s\n' "$VERSION" "${LATEST:-0}" | sort -V | tail -1)" != "$VERSION" ]; then
  say "nothing to release (changelog $VERSION, latest $LATEST)"; exit 0
fi
# A draft of this version from an earlier run that failed half way: start clean.
if gh release view "v$VERSION" --repo "$REPO" --json isDraft --jq .isDraft 2>/dev/null | grep -q true; then
  [ "$DRY" = "--dry-run" ] || gh release delete "v$VERSION" --repo "$REPO" --yes --cleanup-tag
fi
if [ "$DRY" = "--dry-run" ]; then say "would release $VERSION (latest $LATEST)"; exit 0; fi

say "releasing $VERSION (latest $LATEST)"
notify "Releasing $VERSION"
if bash scripts/release.sh "$VERSION" && bash scripts/publish.sh "$VERSION"; then
  say "released $VERSION"; notify "$VERSION is live"
else
  say "release of $VERSION failed"; notify "Release of $VERSION failed, see the log"; exit 1
fi
}
main "$@"; exit

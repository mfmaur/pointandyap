#!/bin/bash
# Writes the Homebrew cask for a published release into github.com/mfmaur/homebrew-tap and pushes it.
# Usage: bash scripts/update-cask.sh 0.1.0 [path/to/PointAndYap.dmg]   (run after the release is published)
set -euo pipefail
VERSION="${1:?version}"
DMG="${2:-build/PointAndYap.dmg}"
[ -f "$DMG" ] || { echo "no DMG at $DMG" >&2; exit 1; }
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
MNT=$(mktemp -d); hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DMG"
APP=$(basename "$(find "$MNT" -maxdepth 1 -name '*.app' | head -n 1)"); hdiutil detach -quiet "$MNT"
TAP=$(mktemp -d); gh repo clone mfmaur/homebrew-tap "$TAP" -- -q
mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/point-and-yap.rb" <<CASK
cask "point-and-yap" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/mfmaur/pointandyap/releases/download/v#{version}/PointAndYap.dmg"
  name "Point and Yap"
  desc "Talk and point at your screen; your coding agent gets the to-do list"
  homepage "https://pointandyap.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "$APP"

  zap trash: [
    "~/Library/Application Support/PointAndYap",
    "~/Library/Preferences/com.marcmaurer.pointandyap.plist",
  ]
end
CASK
cd "$TAP" && git add -A && git commit -qm "point-and-yap $VERSION" && git push -q
echo "cask point-and-yap $VERSION ($APP, $SHA) pushed"

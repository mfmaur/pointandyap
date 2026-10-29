#!/bin/bash
# The whole review-link loop on this Mac, with nothing deployed: the relay in wrangler dev, --share, a guest in real
# Chrome (its fake microphone plays speech from `say`), --pull with on-device transcription, the triage gate, --accept.
# Usage: bash relay/test/e2e.sh   (needs Node and Google Chrome; touches only a temporary folder)
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build >/dev/null
B=$PWD/.build/debug/PointAndYap
T=$(mktemp -d -t pointandyap-e2e)
export POINTANDYAP_SESSIONS=$T/sessions POINTANDYAP_LINKS=$T/links POINTANDYAP_RELAY=http://127.0.0.1:8799
(cd relay/test && npm install --silent >/dev/null)
(cd relay && npx --yes wrangler@4 dev --port 8799 --ip 127.0.0.1 --persist-to "$T/r2" >"$T/wrangler.log" 2>&1) &
RELAY=$!
trap 'kill $RELAY 2>/dev/null; pkill -f "wrangler.*8799" 2>/dev/null || true' EXIT
until curl -s -o /dev/null http://127.0.0.1:8799/review.css; do sleep 1; done

mkdir -p "$T/sessions" && cp -R Tests/PointAndYapTests/Fixtures/2026-10-17_120000 "$T/sessions/"
"$B" --process "$T/sessions/2026-10-17_120000" >/dev/null
URL=$("$B" --share 2026-10-17_120000 --from Owner | tail -1)
# Chrome only plays a fake-capture file at 48 kHz.
say -o "$T/guest.wav" --data-format=LEI16@48000 "This button should say Store instead of Save. And here, the date should be today."
node relay/test/guest.mjs "$URL" "$T/guest.wav" "$T"
"$B" --pull
ITEM=$("$B" --items | grep -m1 '\[triage\] from Dana' | cut -d' ' -f2)
"$B" --items | grep -q "AXButton \"Save\"" || { echo "FAIL: the guest's point did not resolve to the Save button"; exit 1; }
"$B" --items | grep -qi "store" || { echo "FAIL: the guest's words were not transcribed"; exit 1; }
POINTANDYAP_AGENT=agent "$B" --done "$ITEM" >/dev/null 2>&1 && { echo "FAIL: an agent closed an item in triage"; exit 1; }
"$B" --accept "$ITEM"
POINTANDYAP_AGENT=agent "$B" --done "$ITEM" --note "e2e"
echo "PASS ($T)"

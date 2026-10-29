#!/bin/bash
# Live review end to end on this Mac: a Vite + React app in its dev server, PointAndYap --live in front of it, a guest
# in real Chrome who points and talks (its fake microphone plays speech from `say`), the triage gate and --accept, an
# agent on the MCP that waits for the item, edits the source file the guest pointed at and marks it done, hot reload
# changing the guest's page, and the guest confirming it.
# Usage: bash relay/test/live-e2e.sh [app dir]   (needs Node and Google Chrome; LIVE_TUNNEL=1 goes through cloudflared)
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build >/dev/null
B=$PWD/.build/debug/PointAndYap
T=$(mktemp -d -t pointandyap-live)
export POINTANDYAP_SESSIONS=$T/sessions
(cd relay/test && npm install --silent >/dev/null)
APP=${1:-}
if [ -z "$APP" ]; then
  (cd "$T" && npx --yes create-vite@6.5.0 app --template react-ts >/dev/null && cd app && npm install --silent >/dev/null)
  APP=$T/app
fi
cp "$APP/src/App.tsx" "$T/App.tsx.orig"
PORT=5174
if lsof -ti tcp:$PORT -sTCP:LISTEN >/dev/null; then echo "FAIL: port $PORT is already in use (an old test's dev server?)"; exit 1; fi
(cd "$APP" && exec npx vite --port $PORT --strictPort >"$T/vite.log" 2>&1) &
VITE=$!
# npx starts vite as its own process: whatever listens on the port goes too.
LIVE=
cleanup() {
  kill $VITE $LIVE 2>/dev/null || true
  lsof -ti tcp:$PORT -sTCP:LISTEN | xargs kill 2>/dev/null || true
  cp "$T/App.tsx.orig" "$APP/src/App.tsx" || true
}
trap cleanup EXIT
until curl -s -o /dev/null "http://localhost:$PORT"; do sleep 0.5; done

"$B" --live $PORT --from Owner $([ -n "${LIVE_TUNNEL:-}" ] || echo --no-tunnel) >"$T/live.log" 2>&1 &
LIVE=$!
until grep -q "__pay/k/" "$T/live.log"; do sleep 0.5; done
LINK=$(grep -o 'https\?://[^ ]*/__pay/k/[A-Za-z0-9_-]*' "$T/live.log" | head -1)
echo "link: $LINK"

if [ -n "${TWO:-}" ]; then
  say -o "$T/guest.wav" --data-format=LEI16@48000 "This counter button should be green. [[slnc 1400]] And the heading should say hello Dana. [[slnc 9000]]"
else
  say -o "$T/guest.wav" --data-format=LEI16@48000 "This counter button should be green. [[slnc 9000]]"
fi
node relay/test/live-guest.mjs "$LINK" "$T/guest.wav" "$T" both >"$T/guest.log" 2>&1 &
GUEST=$!

# The owner accepts what the guest asked for (it waits in triage until then).
for _ in $(seq 1 60); do ITEM=$("$B" --items | grep -m1 '\[triage\] from Dana' | cut -d' ' -f2 || true); [ -n "$ITEM" ] && break; sleep 1; done
[ -n "$ITEM" ] || { cat "$T/guest.log"; echo "FAIL: no item from the guest"; exit 1; }
"$B" --items | grep -q 'drawn at `src/App.tsx:' || { "$B" --items; echo "FAIL: the point has no source line"; exit 1; }
if [ -n "${TWO:-}" ]; then
  # Two requests from one recording; the owner accepts it from their own browser's bar.
  "$B" --items | grep -c '\[triage\] from Dana' | grep -qx 2 || { "$B" --items; echo "FAIL: not two requests"; exit 1; }
  OWNER=$(grep -o 'http://127.0.0.1:[0-9]*/__pay/k/[A-Za-z0-9_-]*' "$T/live.log" | tail -1)
  curl -s -c "$T/jar" -o /dev/null "$OWNER"
  curl -s -b "$T/jar" -H 'Content-Type: application/json' -d "{\"id\":\"$ITEM\"}" "${OWNER%%/__pay/*}/__pay/api/accept" | grep -q '"ok":true' || { echo "FAIL: accept from the bar"; exit 1; }
else
  "$B" --accept "$ITEM"
fi

node relay/test/live-agent.mjs "$B" "$APP"
wait $GUEST || { cat "$T/guest.log"; echo "FAIL: the guest did not see and confirm the fix"; exit 1; }
cat "$T/guest.log"
grep -q '"confirmed"' "$POINTANDYAP_SESSIONS/${ITEM%%#*}/state.json" || { echo "FAIL: not confirmed in state.json"; exit 1; }
echo "PASS ($T)"

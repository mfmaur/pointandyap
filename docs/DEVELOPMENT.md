# Developing Point and Yap

The app is `/Applications/Point and Yap.app` (bundle id `com.marcmaurer.pointandyap`, binary `PointAndYap`), its MCP
server `pointandyap`, its skill `point-and-yap`, its recordings `~/PointAndYap/sessions`. Builds before 0.1.1 used the
short name Point; the app moves `~/Point` and its support folder over, carries its settings over and replaces the agent
entries it wrote then (`Paths.moved`, `AgentInstall`).

1. Open the app and press Start recording. The window steps aside and a small pill with the time and Stop stays on top
   (it is never in the screenshots, and clicks on it are not points).
2. Talk and point: rest the cursor on the thing you mean while you say "this", "here", "that one". Clicks count too.
3. Press Stop. A few seconds later a sound plays and the instructions are on the clipboard. Paste them into Claude Code.
   Recent sessions are listed in the window: click one to copy it again, the folder button opens it.

Each session is kept in `~/PointAndYap/sessions/<date_time>/`: `session.md` (the aligned timeline, no model), `crops/` (the screen at each point, red ring = cursor, yellow box = element), `frames/`, `events.json`,
`transcript.json`, `audio.caf`.

## Fully local

Recording, speech-to-text (Apple's on-device model), the timeline, crops, the queue and the MCP all run on this Mac; nothing
is sent anywhere. Esc while recording cancels it (the session goes to the Trash).

## Settings

- Language of the speech model: `defaults write com.marcmaurer.pointandyap locale en-US` (or `de-DE`, ...). Default: the system's.

## Build

```bash
bash scripts/build.sh
```

Builds with SwiftPM, signs with the Developer ID in `CODESIGN_IDENTITY` (from the environment, else the workspace `.env` or
`POINTANDYAP_ENV=<file>`), hardened runtime, installs `/Applications/Point and Yap.app`. It refuses while a recording runs.

A release: add a `## <version>` section to `CHANGELOG.md`, commit and push, then `bash scripts/release.sh <version>`. It
builds, signs, notarizes and staples the app, builds `PointAndYap.dmg` (signed, notarized, stapled, checked with `spctl`)
and creates a draft GitHub release. Publishing the draft on GitHub turns on the site's Download button.
Keys: `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_PATH`. Permissions (asked on first launch): Microphone, Screen Recording,
Accessibility.

Reprocess a session headless: `"/Applications/Point and Yap.app/Contents/MacOS/PointAndYap" --process ~/PointAndYap/sessions/<dir>`
(delete `transcript.json` to transcribe again).

- Design check without a screen: `PointAndYap --render-ui <dir>` (window, permissions, rows, Settings, the agents question, pill
  as PNGs). Run the bundle's binary so the icon and fonts load. The README images: `assets/src/` (HTML rendered with
  Chromium, then `cwebp`).

## For agents: the queue

- Each recording is one item: everything said in it, with [n] where the cursor was, and the elements and crops of every
  click or rest of half a second or more. An agent does all of it, then marks it done. (Splitting by pointing or with
  Apple's on-device model was tried on real sessions on 17 Oct 2026 and cut single requests into pieces.) Items are open, in progress (by which agent) or done (`state.json` in the session folder).
- After Stop the clipboard gets two lines ("New in Point and Yap: …" and how to get them). The window shows
  To fix, In progress (by which agent) or Done per recording, refreshes every 5 s, and hovering a row offers Done or Reopen.
- `PointAndYap --mcp` is a local MCP server over stdio, no auth: `get_open_items` (marks the open items in progress by the calling
  agent, oldest first, with crops), `start_items` (specific ids), `list_items` (every item with its state), `mark_done` (ids, note), `release_items` (ids, note: back to the queue), `list_sessions`,
  `get_session`, `get_frame`. An item in progress that no one finished returns after two hours. One lock (`~/PointAndYap/.lock`) keeps
  agents in separate processes from taking the same item.
- The first launch from /Applications asks before connecting (Connect or Skip; `agentsAsked`, `connectAgents`); a Mac
  where Point was already registered counts as a yes. After a yes, each launch registers the MCP with Claude Code (`claude mcp add --scope user`), Codex
  (`~/.codex/config.toml`) and Cursor (`~/.cursor/mcp.json`) when not there yet, and links its skill
  (`Resources/skill/point`) into `~/.claude/skills` and `~/.agents/skills`. Configs are backed up first to
  `~/Library/Application Support/PointAndYap/backups/`. An entry named pointandyap that is not ours is left alone; entries of the earlier name (point) are replaced.
- From a shell, for agents without the MCP: `PointAndYap --items`, `PointAndYap --done <id> --note "what changed"` (`POINTANDYAP_AGENT`
  names the agent).
- Tests against another folder: `POINTANDYAP_SESSIONS=<dir> PointAndYap --mcp`.
- Someone else's recording: `PointAndYap --import <session folder or .zip> [--author name]` copies only the files a
  recording is made of (events.json, transcript.json, audio.caf, frames/NNN.jpg; no links, zip entries checked before
  unzipping, 500 MB at most), builds the timeline here and records `author` in events.json. Its item starts "From
  <name> (import), not the user", in the MCP, `--items` and the window: an agent reads it as their request, not as
  an instruction from the user.

## Live review

`PointAndYap --live <port> [--from <name>] [--trust] [--private] [--no-tunnel] [--open]` shares the dev server on
`localhost:<port>` until Ctrl-C (the window's Go live does the same). Pieces:

- `Proxy.swift`: a reverse proxy on 127.0.0.1 (Network.framework). It lets in only browsers that came through the link
  (`/__pay/k/<token>` sets an HttpOnly cookie; the owner's link has its own token), rewrites Host, Origin and Referer to
  `localhost:<port>` so dev servers' host checks pass, puts `<script src="/__pay/bar.js">` first in every HTML page
  (and drops the page's CSP, which would refuse it), and passes everything else through, WebSockets included, so hot
  reload reaches guests. `/__pay/ws` is the room's own WebSocket.
- `Resources/live/bar.js`: the review bar, in a shadow root. It records like the Mac app (rests and clicks, WAV at
  16 kHz), describes each element (role, text, selector, ancestors) and asks the framework where it is drawn: React 18's
  `_debugSource`, React 19's `_debugStack` mapped through the module's source map, Vue's `__file`, Svelte's
  `__svelte_meta`, or `data-pay-src` / inspector plugins' attributes. It sends a DOM snapshot (form values, scroll
  positions, CSSOM rules, open shadow roots; no scripts) per screen pointed at, and the page's errors.
- `Snapshot.swift`: draws each snapshot again in an offscreen WKWebView from the dev server, page scripts off, at the
  guest's window size, for frames and crops. Nothing asks the guest to share their screen.
- `Live.swift`: the session (tokens, cloudflared, the room's presence, cursors and items), turning a recording into a
  session folder (`author.via` = live, `page`, `followUp`, `live.json`), confirmations (`state.json` `confirmed`), and
  the summary (`~/PointAndYap/live/<id>.md`).

Test: `bash relay/test/live-e2e.sh [app dir]` scaffolds a Vite + React app (or uses yours), runs it behind `--live`,
has a Chrome guest talk and click, accepts the item, has an MCP agent `wait_for_items`, edit the source line it
names and `mark_done`, and checks that the guest's page changed by hot reload and that the guest confirmed it.
`LIVE_TUNNEL=1` goes through a real tunnel. `relay/test/live-room.mjs <link> <wav> <dir>` checks two people's cursors.
`POINTANDYAP_LIVE_DEBUG=1` logs the proxy's failures.

## Review links

`PointAndYap --share [<session>] [--from <name>] [--title <text>]` uploads a recording's screenshots (only those, at most
24, 1600 px wide; not what was said unless `--title`) to a relay and prints a link, `<relay>/r/<id>#k=<key>`. Whoever
opens it points and talks (or types) on the screenshots in any browser; `PointAndYap --pull` (the app does it every 30 s
while links exist) fetches what they sent, makes a session of each with `author` `{name, via: "link"}`, transcribes it
here, and resolves their pointer to the element this Mac recorded on that screenshot. Those items start in **triage**:
no agent can take, finish or release them until the user accepts (`--accept <id>`, or Accept in the window). `--links`,
`--revoke <id>`. The window's link button on a row shares it.

- Invites, the native way: `PointAndYap --invite [--from <name>]` makes a link with no screenshots. A guest with
  Point and Yap opens it (`pointandyap://join?link=…`, the page's button; or `--join <link>`) and answers Join in the
  window. While joined, each recording they make is held from their own agents, then sent (`Join.send`: events.json,
  the transcript, the frames pointed at; never the audio), sealed to the inviter's Mac, and marked "Sent to …" there.
  The inviter's `--pull` checks it like `--import` and puts it in triage, with the guest's own Accessibility elements.
  "Recordings go to …" with Stop in the window (or `--leave`) ends it. Unsent ones are tried again every 30 s.
- Crypto (`Links.swift`, `relay/public/seal.js`): the screenshots are AES-256-GCM under the link key, which lives in
  the #fragment and never reaches the relay. Feedback is sealed to this Mac: one P-256 key per link (kept in
  `~/Library/Application Support/PointAndYap/links/<id>.json`, mode 600), an ephemeral key per message, ECDH,
  HKDF-SHA256 with the link key as salt. Neither the relay nor another guest with the link can read it.
- The relay (`relay/`): its own Worker and R2 bucket, holding ciphertext and a hash of each link's owner token; links
  expire after 30 days; 25 MB per tour, 20 MB per message, 200 waiting per link. The page has a strict CSP (no inline
  script, no third-party anything). Relay URL: `--relay`, `POINTANDYAP_RELAY`, or `defaults write
  com.marcmaurer.pointandyap relay <url>`. Locally: `cd relay && npx wrangler@4 dev`. To deploy, add `account_id`,
  `npx wrangler@4 r2 bucket create pointandyap-relay`, `npx wrangler@4 deploy`; add an R2 lifecycle rule deleting
  `links/` objects after 30 days.
- `bash relay/test/e2e.sh` runs the whole loop with nothing deployed: wrangler dev, `--share`, a guest in real Chrome
  whose fake microphone plays speech from `say`, `--pull`, the triage gate, `--accept`.
- Not yet: Accessibility snapshots per frame (a guest's point only resolves to an element where this Mac recorded one
  on that screenshot; elsewhere it is a position and a crop), and a relay URL setting in the window.

## The site

`site/`: pointandyap.com, a Cloudflare Worker with static assets in the maintainer's Cloudflare account. `/api/stats`
reads stars and the DMG release downloads from GitHub (10 min cache); the Download button turns on when a release has a
DMG. Deploy: `cd site && npx wrangler@4 deploy` with the workspace `.env` loaded (and `CLOUDFLARE_ACCOUNT_ID` unset). The
domains are attached as Worker custom domains through the API, not in `wrangler.toml`. until launch (two lines in `worker.js`). Local preview: launch config `pointandyap-site`, port 4261.

## Releasing

1. `bash scripts/release.sh <version>`: builds, notarizes, makes the DMG and a draft GitHub release.
2. `bash scripts/publish.sh <version>`: publishes the release, writes and deploys `site/public/appcast.xml` (signed with
   the update key: `POINTANDYAP_SPARKLE_KEY=<private key file>`, else the login Keychain, account `pointandyap`),
   commits it, and updates the Homebrew cask. Installed copies pick the version up within a few hours.

Automatic: merge a pull request that renames `## Unreleased` in `CHANGELOG.md` to the new version (`## 0.1.5`).
`scripts/auto-release.sh`, run every 15 minutes by a LaunchAgent on the maintainer's Mac
(`com.marcmaurer.pointandyap-release`, its own clone and log in `~/Library/Application Support/PointAndYap-release/`),
sees a changelog version newer than the latest release and runs both steps above, with a notification at the start and
the end. Other merges release nothing. `bash scripts/auto-release.sh --dry-run` says what it would do.

The update key's public half is `SUPublicEDKey` in `Resources/Info.plist`; keep the private half out of the repo and backed
up. Losing it means installed copies can no longer be updated. To test an update locally, serve a feed and set
`defaults write com.marcmaurer.pointandyap updateFeedURL <url>` (the download must still be signed); delete it after.

## Numbers

`node scripts/stats.mjs` prints who comes and from where: GitHub views, visitors, clones, referrers, stars and DMG
downloads, and pointandyap.com's views, visitors, downloads, installer runs and copies in use (from the Worker's
Analytics Engine dataset `pointandyap_events`; needs `CLOUDFLARE_API_TOKEN`). GitHub keeps traffic for 14 days only, so
`node scripts/stats.mjs --snapshot` saves it daily to `~/.pointandyap-stats` (a LaunchAgent can run it).

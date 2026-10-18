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

The update key's public half is `SUPublicEDKey` in `Resources/Info.plist`; keep the private half out of the repo and backed
up. Losing it means installed copies can no longer be updated. To test an update locally, serve a feed and set
`defaults write com.marcmaurer.pointandyap updateFeedURL <url>` (the download must still be signed); delete it after.

## Numbers

`node scripts/stats.mjs` prints who comes and from where: GitHub views, visitors, clones, referrers, stars and DMG
downloads, and pointandyap.com's views, visitors, downloads, installer runs and copies in use (from the Worker's
Analytics Engine dataset `pointandyap_events`; needs `CLOUDFLARE_API_TOKEN`). GitHub keeps traffic for 14 days only, so
`node scripts/stats.mjs --snapshot` saves it daily to `~/.pointandyap-stats` (a LaunchAgent can run it).

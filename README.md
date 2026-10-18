# Point

Talk about what is on screen while you point with the cursor; get instructions a coding agent can act on.

1. Open Point and press Start recording. The window steps aside and a small pill with the time and Stop stays on top
   (it is never in the screenshots, and clicks on it are not points).
2. Talk and point: rest the cursor on the thing you mean while you say "this", "here", "that one". Clicks count too.
3. Press Stop. A few seconds later a sound plays and the instructions are on the clipboard. Paste them into Claude Code.
   Recent sessions are listed in the window: click one to copy it again, the folder button opens it.

Each session is kept in `~/Point/sessions/<date_time>/`: `session.md` (the aligned timeline, no model), `instructions.md`
(written by Claude), `crops/` (the screen at each point, red ring = cursor, yellow box = element), `frames/`, `events.json`,
`transcript.json`, `audio.caf`. Nothing leaves the Mac except the step that writes `instructions.md`.

## Fully local

Recording, speech-to-text (Apple's on-device model), the timeline, crops, the queue and the MCP all run on this Mac; nothing
is sent anywhere. Esc while recording cancels it (the session goes to the Trash).

## Settings

- Language of the speech model: `defaults write com.marcmaurer.point locale en-US` (or `de-DE`, ...). Default: the system's.

## Build

```bash
bash scripts/build.sh
```

Builds with SwiftPM, signs with the Developer ID in `CODESIGN_IDENTITY` (from the workspace `.env`, or `POINT_ENV=<file>`),
hardened runtime, installs `/Applications/Point.app`. Permissions (asked on first launch): Microphone, Screen Recording,
Accessibility.

Reprocess a session headless: `/Applications/Point.app/Contents/MacOS/Point --process ~/Point/sessions/<dir>`
(delete `transcript.json` to transcribe again).

The plan and what comes later: `PLAN.md`.
- Design check without a screen: `Point --render-ui <dir>` (window, permissions, rows, pill as PNGs).

## For agents: the queue

- Each recording is one item: everything said in it, with [n] where the cursor was, and the elements and crops of every
  click or rest of half a second or more. An agent does all of it, then marks it done. (Splitting by pointing or with
  Apple's on-device model was tried on real sessions on 17 Oct 2026 and cut single requests into pieces.) Items are open, in progress (by which agent) or done (`state.json` in the session folder).
- After Stop the clipboard gets two lines ("New in Point, 2 things to fix …" and how to get them). The window shows
  To fix, In progress (by which agent) or Done per recording, refreshes every 5 s, and hovering a row offers Done or Reopen.
- `Point --mcp` is a local MCP server over stdio, no auth: `get_open_items` (marks the open items in progress by the calling
  agent, oldest first, with crops), `start_items` (specific ids), `list_items` (every item with its state), `mark_done` (ids, note), `release_items` (ids, note: back to the queue), `list_sessions`,
  `get_session`, `get_frame`. An item in progress that no one finished returns after two hours. One lock (`~/Point/.lock`) keeps
  agents in separate processes from taking the same item.
- On launch from /Applications, Point registers the MCP with Claude Code (`claude mcp add --scope user`), Codex
  (`~/.codex/config.toml`) and Cursor (`~/.cursor/mcp.json`) when not there yet, and links its skill
  (`Resources/skill/point`) into `~/.claude/skills` and `~/.agents/skills`. Configs are backed up first to
  `~/Library/Application Support/Point/backups/`. An entry named point that is not Point's is left alone.
- From a shell, for agents without the MCP: `Point --items`, `Point --done <id> --note "what changed"` (`POINT_AGENT`
  names the agent).
- Tests against another folder: `POINT_SESSIONS=<dir> Point --mcp`.

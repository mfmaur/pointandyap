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

## Instructions step

In this order, the first that works:
1. The Anthropic API (`claude-opus-5-5`) with the key in `~/Library/Application Support/Point/anthropic-key` (0600), about
   0.03 to 0.10 USD a session.
2. The local Claude Code CLI (`claude -p`, your subscription), when you are signed in to it in Terminal.
3. Neither: `session.md` goes on the clipboard instead; it is already readable by an agent.

## Settings

- Language of the speech model: `defaults write com.marcmaurer.point locale en-US` (or `de-DE`, ...). Default: the system's.

## Build

```bash
bash scripts/build.sh
```

Builds with SwiftPM, signs with the Developer ID in `CODESIGN_IDENTITY` (from the workspace `.env`, or `POINT_ENV=<file>`),
hardened runtime, installs `/Applications/Point.app`. Permissions (asked on first launch): Microphone, Screen Recording,
Accessibility.

Reprocess a session headless: `/Applications/Point.app/Contents/MacOS/Point --process ~/Point/sessions/<dir> [--no-claude]`
(delete `transcript.json` to transcribe again).

The plan and what comes later: `PLAN.md`.
- Design check without a screen: `Point --render-ui <dir>` (window, permissions, rows, pill as PNGs).

## For agents

- After Stop the clipboard gets two short lines: what the session is about and where to read it (the `point` MCP's
  `get_session` with the id, or the folder). Paste them into any agent.
- `Point --mcp` is a local MCP server over stdio, no auth, read only over `~/Point/sessions`: `list_sessions`,
  `get_session` (default the latest; instructions or timeline plus the crops as images), `get_frame`.
- On launch from /Applications, Point registers it with Claude Code (`claude mcp add --scope user`), Codex
  (`~/.codex/config.toml`) and Cursor (`~/.cursor/mcp.json`) when not there yet, and links its skill
  (`Resources/skill/point`) into `~/.claude/skills` and `~/.agents/skills`, as the Doppelganger skill is. Configs are backed
  up first to `~/Library/Application Support/Point/backups/`. An entry named point that is not Point's is left alone.

# Point

Talk about what is on screen while you point with the cursor; get instructions a coding agent can act on.

1. Press ⌃⌥P (the menu-bar dot turns red and shows a timer).
2. Talk and point: rest the cursor on the thing you mean while you say "this", "here", "that one". Clicks count too.
3. Press ⌃⌥P again. A few seconds later a sound plays and the instructions are on the clipboard. Paste them into Claude Code.

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

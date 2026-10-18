# Changelog

## 0.1.0

The first public build. macOS 26, Apple silicon. Signed with a Developer ID and notarized by Apple.

- Press Control twice, talk while you point at things on screen, press Control twice again. Esc cancels.
- Voice is transcribed on your Mac (Apple's on-device speech model). Each recording keeps the cursor path, screenshots,
  cropped points and the Accessibility element under the cursor.
- Every recording becomes one item in a local queue: to fix, in progress (by which agent) or done.
- A local MCP server for coding agents (`get_open_items`, `start_items`, `list_items`, `mark_done`, `release_items`,
  `list_sessions`, `get_session`, `get_frame`) and a shell fallback (`Point --items`, `Point --done`).
- On first launch it asks before connecting to Claude Code, Codex and Cursor. Nothing in their configs changes before
  that yes, and each config is backed up first.
- Everything stays on your Mac. No account. The only download is Apple's speech model, which macOS fetches once.

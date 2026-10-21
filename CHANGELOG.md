# Changelog

## 0.1.5

- The installer no longer contains a folder path from the Mac it was built on. Nothing changes in the app.

## 0.1.4

- Recent hides recordings without speech; Settings, Show recordings without speech brings them back.
- A Bluetooth headset no longer goes into call mode while nothing is recording: the microphone is opened only for a
  recording, on the one device it records from, and closed when it stops. Up to 0.1.3 a headset that connected after
  the first recording stayed in call mode (muffled playback everywhere) until Point and Yap quit.

## 0.1.3

- A short loop of how it works above Start recording, once the permissions are allowed, until Got it; How it works
  brings it back.

## 0.1.2

- Updates itself: checks pointandyap.com every few hours, downloads a new version in the background (Sparkle, signed
  with its own key) and installs it when you quit; the window shows it with a Restart button. From this version on.
- Records from the Mac's built-in microphone when the default input is Bluetooth: AirPods no longer switch into call
  mode while you record, and the done sound is no longer cut off.
- After allowing Screen Recording or Accessibility, macOS's Quit & Reopen now really reopens the app.

## 0.1.1

- The app is now "Point and Yap" everywhere: `/Applications/Point and Yap.app`, the MCP server `pointandyap`, the skill
  `point-and-yap`, recordings in `~/PointAndYap`. Recordings, settings and agent connections of 0.1.0 move over by
  themselves; macOS asks for the microphone, screen recording and accessibility once more.
- A designed installer window: drag Point and Yap into Applications.
- Soft start and done sounds of its own.

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

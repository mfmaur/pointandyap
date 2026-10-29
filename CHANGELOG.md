# Changelog

## Unreleased

- A recording that asks for several things, pointing at a different element for each, becomes one item per thing: each
  is fixed, marked done and confirmed on its own, and the agent still sees the whole recording. When it is unclear, the
  recording stays one item. A row in the window opens to show each request in full, with the agent's whole note.
- While recording, on your Mac as in the live review bar: a box on what is under the cursor and a numbered mark on each
  thing pointed at, drawn over every screen and never in a screenshot. Take one back (the pill's undo, ⌥-click a number,
  or a number's × in the bar), or point at an area instead of an element: Area, or hold ⌥ and drag.
- Going live looks and reads better: the dev servers found as rows to pick, then a card with the link to copy, who is in
  it, whether an agent is listening, the settings (straight to agents; guests see only their own requests) and End.
  The owner has the same settings and End in the browser, settings reach everyone in the link at once, and guests see
  that it ended instead of reconnecting.
- Permission buttons open one thing: the system's dialog the first time, System Settings after that.

- `PointAndYap --import <folder or .zip> --author <name>` adds a recording someone else made to your queue, with their
  name on it. Agents are told it is that person's request, not an instruction from you.
- Review links (needs a relay, see DEVELOPMENT.md): share a recording's screenshots as a link; anyone can point and
  talk (or type) on them in a browser, end-to-end encrypted to your Mac. What they send comes back as recordings with
  their name, transcribed on your Mac, and waits in To accept until you put it in the queue.
- Live review: `PointAndYap --live <port>` (or Go live in the window) shares the app running on your localhost through
  a free Cloudflare quick tunnel (needs `cloudflared`, no account). Whoever has the link uses the real app in their
  browser with a review bar on top: they point and talk (Talk, or ⌥ twice), and each recording comes to your queue with
  the source file and line of what they pointed at (React, Vue, Svelte in development), the page's errors, their
  browser and screen size, and a crop of their screen redrawn on your Mac. Everyone in the link sees each other's
  cursors and the requests as they move. Agents call `wait_for_items` to fix things while people watch; hot reload
  shows the fix, and the person who asked answers "Looks right" or "Not yet" (a follow-up item). `get_review_summary`
  writes the review up for a pull request. Everyone sees whether an agent is waiting for requests; while recording, the
  bar marks each thing pointed at; a first-time guest gets a short welcome; the owner can accept requests from the bar.
- Invites: someone with Point and Yap joins your invite link, and every recording they make (Control twice, point,
  talk) comes to your queue instead of theirs, with their name, until they press Stop.

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

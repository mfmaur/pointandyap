# Point: plan

Point is a small Mac menu-bar tool, separate from Rocky and Doppelganger. You press a hotkey, talk about what is on screen
while you point at things with the cursor, press the hotkey again, and get numbered instructions a coding agent can act on,
each tied to the element you pointed at and backed by a cropped screenshot. For Marc only for now; nothing leaves the Mac
except the one Claude call at the end.

## Deeper, not bigger

1. What a top professional would add: capture what the screen *is* (the Accessibility element under the cursor, its role,
   label, value, window, app, URL), not only pixels, and line up every spoken "this" or "here" with where the cursor rested at
   that moment. Keep the raw session so a later version (source tags, app state) can reprocess it.
2. Rawest material: word timings from the transcript, cursor samples at 30 Hz with clicks, full-resolution screenshots at
   every point and click, the AX element at each point. Not a video, not a summary.
3. Methods: on-device speech (SpeechAnalyzer, macOS 26) with word time ranges; dwell detection (cursor still for 350 ms);
   AX hit-testing (`AXUIElementCopyElementAtPosition`); crops with the cursor drawn in; one Claude vision call that writes the
   instructions from that aligned material.
4. Outside proof: a test session built from a synthetic voice (`say`) and scripted points must produce a session.md whose
   points line up with the words, and instructions that name the right element. Then Marc's own sessions: does Claude Code
   edit the right place first try.

## What one session produces

`~/Point/sessions/<yyyy-MM-dd_HHmmss>/`

- `audio.caf`: the recording.
- `events.json`: cursor samples, clicks, points (dwells) with their AX element, app, window title, URL, and frames.
- `frames/NNN.jpg`: full screenshots of the display under the cursor (at start, every point, every click, every 3 s).
- `transcript.json`: words with start and end seconds.
- `crops/NN.jpg`: one crop per point (900 x 600 pt around the cursor, cursor ring drawn in).
- `session.md`: the aligned timeline, deterministic, no model: each sentence with the points made while it was spoken, the
  element, and its crop. Good enough for an agent on its own.
- `instructions.md`: numbered, structured instructions written by Claude from session.md and the crops (absolute image paths,
  so a coding agent can open them). Copied to the clipboard when ready.

## Interface (minimal)

- Menu-bar icon: a dot; red while recording, half-filled while processing.
- Hotkey ⌃⌥P starts and stops (Carbon hot key, needs no Accessibility).
- Menu: Start/Stop, Copy last instructions, Open last session, Quit.
- When done: the instructions are on the clipboard and a short sound plays. Paste into Claude Code.

## Build steps

1. Capture: hotkey, AVAudioEngine to `audio.caf`, cursor sampler (30 Hz, dwell and click detection), ScreenCaptureKit
   screenshot of the display under the cursor, AX probe at each point.
   Check: a recorded session has frames, points with AX roles, and audio.
2. Processing (`Point --process <dir>` reruns it headless): transcribe with word times; group words into sentences (pause
   over 0.7 s or punctuation); attach each point to the sentence it falls in (with 0.5 s slack); crops with the cursor ring;
   write session.md.
   Check: synthetic session (voice from `say`, scripted points) lines up.
3. Claude pass: one call to the Messages API (`claude-opus-5-5`, raw HTTP, key from
   `~/Library/Application Support/Point/anthropic-key`), up to 12 crops plus session.md, writes instructions.md. About 0.03 to
   0.10 USD per session. Without a key the tool stops at session.md and copies that instead.
   Check: the synthetic session's instructions name the pointed element.
4. Package: SwiftPM release build, an .app bundle (LSUIElement, usage strings), signed with Marc's Developer ID Application
   identity and the hardened runtime (microphone entitlement), installed to `/Applications/Point.app` so the macOS
   permissions stick to a stable signature.
5. Marc grants Microphone, Screen Recording and Accessibility once, records a real session, pastes it into Claude Code.

## Later (not now)

- Source tags for apps we build: a dev build where SwiftUI views carry `accessibilityIdentifier("File.swift:142")`; React Grab
  for web. Point already records `AXIdentifier`, so these show up without a change to Point.
- App state at each point (a debug hook in the app under test writes its route and selected ids).
- A local MCP server (`list_sessions`, `get_session`) instead of the clipboard.
- Redaction of sensitive text before the Claude call.
- Open source once it has proven itself.

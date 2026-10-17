---
name: point
description: Marc's narrated screen recordings from the Point app. Use when Marc says he recorded, showed or pointed at something ("the Point session", "what I just showed you", "see my recording", "fix what I pointed at"), or pastes a "New Point session" line.
---

# Point

Point records Marc talking about his screen while he points at things with the cursor. Each session holds numbered
instructions for a coding agent (or the aligned timeline when no instructions were written), the Accessibility element
under each point and a cropped screenshot per point (red ring = cursor, yellow box = the element's frame).

## Read a session

- With the `point` MCP: `get_session` (no id = the latest; images included), `list_sessions`, `get_frame` for a full
  screenshot.
- Without the MCP: the folder `~/Point/sessions/<id>/`: `instructions.md` first, else `session.md`; crops in `crops/NN.jpg`
  (NN = the point's [n]); full screenshots in `frames/`.

## How to act on it

1. Read the instructions and look at every crop before changing code.
2. Find the code behind each element: its visible text, `identifier` (a source location when the app sets one), window and
   the path of parent elements are the search keys. Grep for the visible text first.
3. Do each numbered item; ask Marc about the open questions instead of guessing.
4. In your reply, name the item numbers you handled.

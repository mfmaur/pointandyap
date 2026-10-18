---
name: point-and-yap
description: The user's queue of things to fix from Point and Yap, where they point at things on screen and talk. Use when the user says "work through Point", "fix what I pointed at", "check Point", refers to something they recorded or showed, or pastes a "New in Point and Yap" line.
---

# Point and Yap

The user points at things on their screen with the cursor and says what is wrong. Every recording becomes an item in a
queue: what they said, the elements under the cursor (role, visible text, window, `identifier` when the app sets one, the
parent elements) and cropped screenshots (red ring = cursor, yellow box = the element's frame).

## Work through the queue

1. `get_open_items` (pointandyap MCP) marks the open items in progress by you, oldest first, and returns them; no other agent
   gets them. To pick specific ones instead: `get_open_items` with `take: false`, then `start_items` with their ids.
   `list_items` shows what is open, in progress (by which agent) and done.
2. For each item: look at its crops, find the code behind the element (grep its visible text first, then the identifier,
   window and parents), make the change, check it.
3. **Right after each fix, `mark_done`** with the item's id and a one-line note (what changed, which file). This is how
   the user sees it is done; an item you fix but do not mark stays open in their list and goes to another agent later.
   Done items are never handed out again.
4. An item you cannot do, or that needs the user: `release_items` with a note saying why; it goes back to the queue.
5. Call `get_open_items` again until it says there is nothing open. In your reply, list the ids you did.

Do not ask the user which items to do: the open ones are the ones to do. Ask only when an item is ambiguous, and then
release it with the question as the note.

## Without the MCP (shell)

`/Applications/Point.app/Contents/MacOS/Point --items` prints the open items; after a fix,
`/Applications/Point.app/Contents/MacOS/Point --done <id> --note "what changed"` (set `POINT_AGENT` to your name).

## Files

Recordings are folders in `~/Point/sessions/<id>/`: `session.md`, crops in `crops/NN.jpg`, the item states in
`state.json`. Prefer the MCP: it keeps the states right when several agents work.

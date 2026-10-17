---
name: point
description: Marc's queue of things to fix from the Point app, where he points at things on screen and comments. Use when Marc says "work through Point", "fix what I pointed at", "check Point", refers to something he recorded or showed, or pastes a "New in Point" line.
---

# Point

Marc points at things on his screen with the cursor and says what is wrong. Every comment becomes an item in a queue:
what he said, the element under the cursor (role, visible text, window, `identifier` when the app sets one, the parent
elements) and a cropped screenshot (red ring = cursor, yellow box = the element's frame).

## Work through the queue

1. `get_open_items` (point MCP) marks the open items in progress by you, oldest first, and returns them; no other agent
   gets them. To pick specific ones instead: `get_open_items` with `take: false`, then `start_items` with their ids.
   `list_items` shows what is open, in progress (by which agent) and done.
2. For each item: look at its crop, find the code behind the element (grep its visible text first, then the identifier,
   window and parents), make the change, check it.
3. `mark_done` with the item's id and a one-line note (what changed, which file). Done items are never handed out again.
4. An item you cannot do, or that needs Marc: `release_items` with a note saying why; it goes back to the queue.
5. Call `get_open_items` again until it says there is nothing open. In your reply, list the ids you did.

Do not ask Marc which items to do: the open ones are the ones to do. Ask only when an item is ambiguous, and then release
it with the question as the note.

## Without the MCP

Sessions are folders in `~/Point/sessions/<id>/`: `instructions.md` or `session.md`, crops in `crops/NN.jpg`, the item
states in `state.json`. Prefer the MCP: it keeps the states right when several agents work.

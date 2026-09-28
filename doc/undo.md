# Undo: declared steps, a history tree, and a tool to walk it

Undo is per-peer and selective, by op inverse (`src/core/undo.zig`'s module
doc): undoing a step applies the inverse of your own commits, transformed
through everything that landed since — your later work and every peer's — so
a collaborator's edits are never undone. This page is about the two things
built on that: what ONE step is, and the shape history takes.

## 1. What one step is, is the grammar's to declare

An `UndoLog` coalesces your commits into one unit until something cuts it.
Nothing cuts it by accident any more: a caret motion, a selection change, a
mode change or a completion accept is not an undo boundary. The cut happens in
one place, dispatch (`src/core/step.zig`): wherever a keystroke or a click runs
something — a bound command, an intention, the mode's text commit — `step.begin`
asks the mode the head is in what that means, and the grammar answered in its
`init`:

```zig
weft.runStr2("mode.set-undo-step", "<mode>", "command" | "continue" | "run");
```

| rule       | a dispatch in this mode…                          | declared by |
|------------|---------------------------------------------------|-------------|
| `command`  | begins a new step (the default, every undeclared mode — normal, visual, operator-pending, menus, pickers) | — |
| `continue` | continues the step that entered the mode          | vim `insert`, helix `helix-insert` |
| `run`      | continues the step only if it runs the same command as the last one | ide `ide`, emacs `emacs` |

The rule is read down the mode's fallback chain, like its other declarations,
and core names no mode and no grammar. What falls out:

- vim/helix: `cw…Esc`, `o…Esc`, `i…Esc`, helix `c…Esc` are one `u`; `d` then
  `P` are two whatever the caret did in between; a motion between commands is
  no step at all; `.` replays keys through the same dispatch, so a repeat is
  the step it repeats; a macro's replayed keys cut as typed ones do (each
  change its own step, as vim).
- ide/emacs: a word typed is one step, a run of Backspaces another; moving the
  caret, clicking, or any other command ends the run.

A cut closes the open unit of every text entry, so a step that edits several
entries is one step in each. `edit.seal-undo` remains as an explicit cut in
the middle of a step, for a command that means one; nothing needs it to end a
step.

## 2. History is a tree

`UndoLog` keeps a tree of steps (`Node`), rooted at the state before your
first edit. Undo walks to the parent; redo to the child last walked from
(undo of an undo — the machinery is symmetric); a new step after an undo is a
new child beside the undone one, a branch, and nothing is discarded.
`UndoLog.jump(node)` reaches any step: undo up to the common ancestor, then
redo down the other branch, each move through the same gated apply as a typed
`u` — a narrowed principal can reach no further by jumping. A refusal stops
the walk where it was refused, the document consistent.

Two command doors expose it (no ABI import):

- `edit.undo-tree` — the active entry's tree as text, one line a step
  (`id parent flags inserted removed text`, see `UndoLog.describe`): a data
  source for `weft.callString`.
- `edit.undo-to <step> <entry>` — bring the active entry to a step; `<entry>`
  is the designation the step was read from, and another entry refuses.

## 3. The undo-tree tool

`src/plugins/undo_tree` provides the `undo-tree` projection of an entry, drawn
as a graph with the scene's graph cells (a node whose role leaf is `edge`:
lines to the sides its `links` fact names, and — an action node — a dot, see
`gfx/view/semantic.zig`'s `Graph`). A dot a step, a line down to the steps
taken after it, a branch wherever a step followed an undo; the current step is
the large dot, the path to it filled, the rest hollow; the words beside each
row say what its steps wrote or took away. Every dot is an action node, so a
click or the grammar's own activate (`std.target.activate`, Return) goes there,
and the grammar's up/down walk the steps in the order taken. The move runs in
the primary context, so the tree keeps the focus while the editor changes
under it; the tree watches its subject and redraws when the history moves.

`config/undo.js` docks it on the right, hidden, presenting
`{subject: {context: "entry"}, as: "undo-tree"}` so it follows the editor.
`undo-tree.open` (Edit ▸ Undo History) shows and hides that viewport; with no
viewport configured it presents the active entry's tree in place.
config.js and helix.js bind it to `SPC u`.

## Left, and why

- No pause rule for `run`. A cut on elapsed time would make the step boundary
  depend on the wall clock at dispatch; it wants the input event's own
  timestamp threaded through dispatch, which it does not carry yet.
- vim's insert-mode arrows do not start a new step (vim's do): `insert`
  continues its step through anything it runs. A grammar that wants it can
  bind those keys to a command that runs `edit.seal-undo` first.
- `beginUnit`/`endUnit` and the `wl_undo_unit` door still exist; within one
  dispatch nothing cuts any more, so they are redundant but harmless. Retiring
  the door is an ABI change for its own pass.

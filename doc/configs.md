# The three configs

weft ships three configs, and each one tests a different part of the editor:

| config | grammar | what it tests |
|---|---|---|
| `config/config.js` | vim | the reference setup: every plugin, the leader tree, and the semantic `SPC v` group |
| `config/helix.js` | helix | selection-first editing, and whether the semantic binds hold up under a different grammar |
| `config/ide.js` | ide (new) | the binding and action system itself: mouse, a conventional non-modal keymap, and an adaptive toolbar |

`defaults.js` (picker and which-key keys) and `sidebar.js` (a docked files viewport) are
fragments shared through `weft.use`; they are not standalone configs.

This document is the plan. Each section below lists the work items, and tags each one as
**core-door** or **plugin** under the project rule: every capability defaults to a
plugin, and core adds a door, never a policy.

---

## 0. Shared primitives

Two of the configs are blocked on the same few doors. Building them once, before either
config, avoids building them twice.

### 0.1 Multiple selections — core-door

Today `Editor` has one `cursor` anchor and an optional `mark` (`Editor.zig:32-34`). Helix
is built on multiple selections, and ide's C-d (add next match) needs them too.

Generalize the degenerate case:

- A selection is `{anchor, head}`, both CRDT anchors in `AnchorSet`.
- `Editor` holds `selections: []Selection` and `primary: usize`. The existing
  cursor/mark API stays as a view onto the primary selection, so vim and emacs are
  untouched.
- An empty selection (`anchor == head`) is a caret. Helix's rule that a selection always
  covers at least one character is a grammar policy, not a core rule.
- Every edit path (typing, backspace, delete, `op.*` through `runRange`) applies across
  all selections in reverse offset order, as one undo unit.
- New ABI calls: `wl_selections_count/get/set`, and `runRange` runs once per selection.
- Registers hold one value per selection (a list), and paste distributes the values
  across the selections.
- Rendering: `selectionRects` is called once per selection, and the caret is drawn per
  selection. Peer carets already draw many, so the renderer is ready.

This is the largest item in the arc. It lands first, behind its own gate: vim and emacs
e2e must stay green with one selection.

**Landed.** What the build settled:

- A selection is `{head, anchor?}` (`Editor.Selection`). The anchor is optional rather
  than equal to the head, because the two states move differently: with no anchor, a
  motion moves a caret; with one, it grows a selection. The old `cursor`/`mark` fields are
  gone; they are `selections[primary]`.
- The set is always sorted and disjoint (`Editor.normalize`): overlapping selections, and
  carets that meet, merge. Core motions (`moveTo` and the cursor-* builtins) move only the
  primary. A grammar that moves every selection computes the targets and calls
  `setSelections`.
- Typing, backspace, delete, newline and tab act at every selection through
  `Context.editEach`: one gate check over every range, then one `replaceAll` commit, so
  the edit is one undo unit.
- The ABI:
  - `wl_selections_get`/`wl_selections_set` exchange one u32 record,
    `[primary, anchor0, head0, …]`, in document order. add, remove and collapse are
    SDK compositions over that pair (`addSelection`, `removeSelection`,
    `collapseSelections`), not doors.
  - `wl_run_range_each` runs a motion once per selection, with that selection as the
    primary.
  - `wl_run_range_arg_each` runs an operator once per range, in reverse offset order,
    inside `UndoLog.beginUnit`/`endUnit`, so barriers the operator raises cannot split
    the unit.
- Registers hold one value per selection (`wl_yank_each`). The distribution rule
  (`Register.pasteSpan`): when the register holds exactly as many values as there are
  selections, selection *i* pastes value *i*. Otherwise every selection pastes the joined
  text: all the values, with a `\n` between two values when the first doesn't already
  end in one. `wl_register_paste_value` and `wl_paste_value_at` answer that rule, so no
  grammar re-derives it.
- The view draws a wash for every selection and a caret for every head. Presence still
  publishes only the primary.

### 0.2 Regex — plugin library

Helix needs regex for `s S K A-K / * n N`. ide needs it for find and replace. Neither
should cost core a regex engine.

A guest-side library (a `plugin_lib` tier), a Pike VM over UTF-8. It covers the helix
and ide needs; it does not aim to be PCRE. Plugins link it. Core never parses a pattern.

### 0.3 Visible range and label overlay — core-doors

Snipe (config.js) needs these, and so do helix `gw` (goto word) and hint jumps in ide:

- `wl_view_range() -> (start, end)`: the byte range the focused pane shows.
- An `overlay` decoration placement that draws its text over the cell at an anchor
  offset. The renderer draws only `virtual_before` today, and only as a line prefix.
  Drawing the `gutter` placement falls out of the same work, which also fixes the
  invisible breakpoint dot.

### 0.4 Flash — core-door, small

- The flash range becomes a set of ranges, so one flash can cover every selection.
- It is tied to its document rather than to raw offsets.
- `flash-ms` is re-read on config reload.
- Undo and redo report the changed span, so core flashes it when `editor/flash-undo` is
  on. That is the one flash only core can do, because the grammar never sees the span.

### 0.5 Gutter door — core-door

- `GutterLineArgs` gains `caret_line` and `line_count`, the latter for a fixed-width
  column.
- The gutter facts gain `tool` and posture, so a provider can restrict itself to text
  buffers.
- Plugins can bind `ui/gutter-segment` (today `wl_slot_bind` makes a
  `.schema_provider`, which the gutter skips).

---

## 1. config.js

1. **Relative line numbers** — plugin `linenumbers`. It binds `ui/gutter-segment` with
   predicate `posture == text`, reads `weft.set("linenumbers", "style",
   "relative"|"absolute"|"hybrid")`, and pads to the width of `line_count`. Depends on
   0.5.
2. **Flash on every action** — in the vim plugin:
   - `applyOpRange`: after an edit operator, flash the anchored range (`gc`, `gu`, `gU`,
     `>`, `<`, `=`).
   - `visualOp`: the same.
   - paste, `J`, `~`, `r`.
   - Undo and redo through 0.4.
   - The e2e test asserts that the flash range is set after each of these.
3. **Snipe on f/F/t/T** — plugin `snipe`:
   - Reads the character through a `textInput` capture.
   - Searches the visible range (0.3), not only the current line.
   - With one hit it jumps. With several it labels each hit with an overlay (0.3) from a
     home-row alphabet, then a second capture reads the label.
   - Keeps its own `;`/`,` state.
   - Composes with operators: in operator-pending mode (`df<c>`) it returns a range the
     same way `motions` does, so `d`, `c` and `y` work across lines.
   - The vim `find-*` bindings stay in vim; config.js rebinds `f F t T ; ,` in `normal`
     (and the operator-pending mode) to snipe. The e2e tests that pin `f .` then `;` `;`
     `,` (`authoring_test.zig:372`) move to exercising snipe, with a single-hit case
     that still lands exactly.

## 2. helix.js — a working Helix

The helix plugin is 228 lines today. Several of its bound keys are dead without vim
loaded (`dd`, `gg`, `ge`, `p`'s fallback, `SPC SPC`), `y` has no text fallback, and `x`
is wrongly bound. The rewrite targets Helix's default keymap, and wherever a standard
intention covers an operation it binds the intention, with a text fallback.

Phases:

1. **Honest base** (no 0.x dependency):
   - fix the dead binds and give every intention a text fallback;
   - add `helix-structural` to `Buffers.bindingMode`, and move `bindIntentionGroup` and
     `bindActionGroup` into a fragment `semantic.js` used by config.js and helix.js, so
     `SPC v` exists under helix;
   - which-key groups, and the full plugin set (ts, lsp, structural, indent, numbers,
     debug, languages.js);
   - add helix to the grammar mode-leak `posture_cases`;
   - add an e2e test that boots helix.js and asserts that every bound command resolves.
     That test is what lets dead binds slip today.
2. **Selection-first**, on 0.1:
   - motions set anchor and head; `v` select mode extends;
   - `x X % ; A-; A-:`;
   - `d c y p P R` act on the selections;
   - `C A-C , A-, ( )`;
   - flash on every operation.
3. **Minor modes:**
   - `g` goto (`gd gr gi gy` through LSP; `gw` through the 0.3 labels);
   - `m` match: `mm`, `mi*`/`ma*` over `textobjects`, and `ms md mr` surround (new
     plugin `surround`, also bound in vim as `ys ds cs`);
   - `z`/`Z` view mode;
   - `[`/`]` pairs;
   - space mode laid out as Helix's own, not the doom tree.
4. **Regex**, on 0.2: `s S K A-K`, `/ ? n N *`, with the search register shared with vim.
5. **Registers, counts, jumplist (`C-o C-i C-s`), macros (`q Q`).** The jumplist and
   macros are core-doors (per-head position history; a replay built on the dot
   recorder). Registers and counts stay in the grammar.
6. **Tree-sitter selection:** `A-o A-i A-p A-n` over the `ts` plugin, with multi-selection
   aware versions.

"The semantic binds earn their keep" means this, concretely:

- in a structural buffer (files, git), helix's own keys (`d`, `y`, `p`, `x`, `Return`,
  `-`) do the structural thing through intentions, with no files-specific or git-specific
  helix code;
- the e2e test drives the files listing and a git status buffer under helix.js with the
  same assertions config.js already passes.

## 3. ide.js — the binding and action stress test

This is conventional, mouse-and-keyboard, and not modal. The sidebar is open by default
(`weft.use("sidebar")`).

Its point is to exercise the dispatch tiers the other configs barely touch: pointer
input through the keymap, offers enumerated for a context the user is not focused in,
and chrome that changes with what is possible.

### 3.1 Pointer input — core-doors

1. **Pointer events.** Every button with modifiers, click count (double and triple),
   wheel (wiring the dead `consumeWheel`), and motion/hover. Today the platform samples
   pointer state rather than queuing events.
2. **Pointer keyspecs through the keymap.** `mouse-1`, `S-mouse-1`, `double-mouse-1`,
   `triple-mouse-1`, `mouse-3`, `wheel-up/down`, `C-wheel-up`. The hit point is carried
   as facts (pane, offset, scene node). The caret-placement and drag policy hardcoded in
   `app/dispatch.zig:63-139` moves out into default bindings, where config.js and
   helix.js get it too.
3. **A click can act in a pane that isn't focused** (click through), and scene `action`
   nodes can be activated by click and by keyboard through the same action reference.
4. **Hit rects** for tabs, status segments and surface rows.

### 3.2 The ide grammar — plugin `ide`

Built in the emacs mold: a resting mode `ide` that falls back to `default`, plus
`ide-structural`.

- Shift-arrow and Shift-Home/End extend the selection; a plain move collapses it.
- `C-Left/Right` move by word; `Home` is smart home.
- `Tab`/`S-Tab` indent or dedent the selection.
- `C-/` toggles a comment; `A-Up/Down` moves the line.
- `C-d` adds the next match (on 0.1); `C-S-l` selects all matches.
- Double-click selects a word, triple-click a line, and a drag selects.
- Every operation goes through `std.*` intentions first, so the same keys act in the
  sidebar.

### 3.3 Clipboard — core-door plus plugin

The system clipboard over `wl_data_device` is a door. Which register mirrors it is the
grammar's choice: ide mirrors the unnamed register, and vim keeps `"+`.

### 3.4 Find and replace — plugin `find`

An incremental find bar (a bottom surface) on the 0.2 regex: C-f, F3/S-F3, C-h replace,
and highlight of every match. Before 0.2 lands, C-f falls back to `consult-line`.

### 3.5 Action system doors — core-doors

1. Config `weft.provide` accepts `role`, `tool` and `locality` predicates, not only
   `mode` and `lang`.
2. **Offers for a chosen context.** An enumeration door keyed to the primary focus (the
   last text pane) rather than to the active pane. A toolbar that takes focus must still
   describe the editor, not itself.
3. **An offers-changed event** (the catalog revision moved), so chrome redraws without
   polling.
4. **Offer metadata:** label, group and ordering, i.e. the affordance contributions of
   `contextual-workspace-architecture.md` §11.3-11.4. Node actions that aren't standard
   are published as offers too.
5. **Real availability.** Undo and redo report disabled when there is nothing to undo.

### 3.6 Chrome — plugins, on small core-doors

1. **Viewport extent in rows** (core-door), so a one-row top dock is expressible.
2. **Toolbar** (plugin `toolbar`, the "adaptive toolbar"): a semantic view of `action`
   nodes docked at the top.
   - Its content is `static entries from ide.js` ∪ `offers for the primary focus`,
     grouped and ordered by the offer metadata.
   - It redraws on the offers-changed event.
   - It is adaptive by construction: in a .zig file it shows build, test, debug and
     format; in the files sidebar it shows new file and rename; in git it shows stage and
     commit.
   - No toolbar code knows any of those tools.
3. **Context menu** (plugin `contextmenu`) on `mouse-3`: the offers plus node actions at
   the pointer's hit point, as a caret-placed surface.
4. **Clickable tabs** (activate and close), a clickable status line, a problems panel (a
   bottom dock over the diagnostics layer), a terminal panel (a bottom dock), and
   breadcrumbs (focus feed plus LSP symbols).
5. A **menubar** is deliberately left out of this arc. The palette (C-S-p) plus the
   toolbar is the discovery surface; a menubar is the next consumer of the same offer
   metadata.

### 3.7 ide.js keys

- C-s, C-S-s, C-o, C-p (quick open), C-S-p (palette), C-w, C-Tab.
- C-z, C-S-z/C-y, C-x/C-c/C-v, C-a, C-f/C-h, C-g (goto line).
- F2 rename, F12 definition, S-F12 references, C-. code actions, C-SPC completion.
- F5/F9/F10/F11 debug, C-` terminal, C-b toggle sidebar, C-j toggle bottom panel.

Every one of these is either an intention or an action with context providers, so the
same key does the right thing in text, the sidebar, git, and a picker.

The e2e stress test asserts that resolution: one key, many contexts, and the expected
provider in each, with `explain` answering the same way.

### 3.8 Order

1. The ide grammar with keyboard only, plus ide.js with the sidebar. This ships on
   existing doors, with C-f through consult-line.
2. Pointer events and keyspecs (3.1.1-2), then double/triple-click and drag bindings.
3. Action doors (3.5), then the toolbar and context menu (3.6.2-3).
4. Clipboard, then find/replace (on 0.2), then C-d (on 0.1).
5. Panels, tabs and breadcrumbs.

---

## Sequencing across the arc

```
0.5 gutter ──► 1.1 linenumbers
0.4 flash  ──► 1.2 flash coverage ─────────────┐
0.3 overlay ─► 1.3 snipe ──► helix gw          │
helix phase 1 (no deps)                        │
ide 3.8 step 1 (no deps)                       │
0.1 multi-selection ──► helix 2,3,6 ──► ide C-d ◄┘
0.2 regex ──► helix 4, ide find
3.1 pointer ──► 3.5 action doors ──► 3.6 toolbar / context menu
```

The work that has no dependency starts in parallel: config.js 1.1-1.3 with their small
doors, helix phase 1, and ide step 1. Multi-selection (0.1) is the critical path and
starts alongside them in its own worktree.

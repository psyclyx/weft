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
  carets that meet, merge. The single-selection API means ONE selection: every write
  through it (`moveTo` and the cursor-* builtins, `placeCursor`, `setMark`,
  `clearSelection`, `selectRange`, so `wl_jump`, `wl_set_selection` and a click) first
  collapses the set to the primary. A grammar that moves every selection computes the
  targets and calls `setSelections`. The one exception is a VISIT
  (`Editor.beginVisit`/`visit`): inside `wl_run_range_each` and `wl_run_range_arg_each`
  the single-selection API addresses the visited selection alone.
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
  - `wl_undo_unit(open)` (SDK `weft.undoUnit(f, args)`) brackets anything a grammar does
    as one unit. Units nest and the outermost owns the unit, so helix's `3>` (a count
    loop over `run_range_arg_each`) and find's replace-all are one undo each. A unit is
    scoped to the command dispatch that opened it: one a guest leaves open ends as that
    dispatch returns.
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

**Built.** `wl_view_range(out) -> i32` (SDK `weft.viewRange() ?Range`) reads
`Head.view_range`, which the frame build writes after laying out the focused pane; it
answers `-1` when that pane showed a different entry. `overlay` is placement 5 on both
`wl_decorate` and `wl_annotate_span`; the view substitutes the covered cells' glyphs and
leaves stops (and so the caret) alone, and a label running past the line end continues
into the empty cells. `gutter`-placed spans draw in a sign column whose width is fixed
per frame (the widest mark plus a blank), so a marked row and an unmarked one start
their text in the same column. `virtual_after` and `eol` still do not draw.

### 0.4 Flash — core-door, small

- The flash range becomes a set of ranges, so one flash can cover every selection.
- It is tied to its document rather than to raw offsets.
- `flash-ms` is re-read on config reload.
- Undo and redo report the changed span, so core flashes it when `editor/flash-undo` is
  on. That is the one flash only core can do, because the grammar never sees the span.

**Built.** `core/flash.zig`: a `flash` layer per document (anchored spans) plus a
generation and a source on `Caps.flash`. `wl_flash` replaces the set, `wl_flash_add`
adds to it (SDK `flash`, `flashAdd`, `flashRanges`). `undo`/`redo` always record the
span their commits changed (`flash.changedSince`) as an `undo` flash; the frame shows it
only when `editor/flash-undo` is `on`, and re-reads `editor/flash-ms` whenever a new
flash starts.

### 0.5 Gutter door — core-door

- `GutterLineArgs` gains `caret_line` and `line_count`, the latter for a fixed-width
  column.
- The gutter facts gain `tool` and posture, so a provider can restrict itself to text
  buffers.
- Plugins can bind `ui/gutter-segment` (today `wl_slot_bind` makes a
  `.schema_provider`, which the gutter skips).

**Built.** `core/gutter.zig` declares the slot with a schema: an `ask` names a window of
lines (`first`, `count`), the caret line and the line count; a `tell` answers one
`{text, role}` cell per line. The view fetches a window lazily the first time a row
outside the current one asks (`ui_mesh.GutterBatch`), so a frame costs one slot round,
not one per visible row. The gutter facts carry `tool` and a new `posture` fact and
predicate leaf. The guest half is the `gutter` plugin library.

---

## 1. config.js

1. **Relative line numbers** — plugin `linenumbers`. It binds `ui/gutter-segment` with
   predicate `posture == text` and no `tool` (an editable projection rests as text
   too), reads `weft.set("linenumbers", "style",
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

**Built.** `linenumbers` has two styles: `absolute`, and `relative`, which shows the
caret line's own number the way vim's `number relativenumber` does (`hybrid` is
accepted as a synonym). config.js sets `relative`. The vim flashes are in place, `=` has
no operator to flash yet. Snipe's operator-pending commands are `snipe-op-*`: the range
goes to the command named by `weft.set("snipe", "operator", …)`, which config.js sets to
vim's new `vim-operate` (apply the pending operator over a range argument). A motion
that reads keys before it knows its target cannot be a synchronous range command like
`motions`', so it hands the range back instead. Snipe is not bound in `visual`; there
`f` falls through to `normal`'s binding and leaves visual, as vim's `find-*` did.
The e2e coverage is `src/e2e/visual_aids_test.zig`.

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

**Phases 2, 3 and 6 landed.** What the build settled:

- The plugin is four files: `selection.zig` (the set, and every verb that reshapes it),
  `edit.zig` (every verb that edits), `text.zig` (the motions, as pure functions from one
  selection to the next) and `state.zig` (the count and register prefixes).
- A selection is core's `{anchor, head}`, and the cursor a motion starts from is the head,
  where core draws the caret. Helix's "at least one character" rule is `span()`: a caret
  acts on the character under it. Helix draws its cursor ON the last selected character,
  where core draws at the head, one past it on a forward selection; phase 4's round added
  the declaration that closes the gap (below).
- Each motion is generated twice, `hx/n/<m>` (move: the motion's own selection) and
  `hx/x/<m>` (extend: the anchor stays). `helix-normal` binds the first, `helix-select`
  (`v`) the second. `helix-op` is gone: a verb acts on the selections.
- Every edit is one mechanism: `putEach` anchors a range per selection and runs helix's
  own operator `hx-op-put` over them through `run_range_arg_each`, so each verb is one undo
  unit. The operator receives only its range, so the plan (which job, what to write) is
  set before the run and claimed by start offset. `d c p P R r ~ \` A-\` o O` are all
  `putEach` with a different source; `J` has its own operator, and `> <` and `SPC c` run
  `op.indent`/`op.dedent`/`op.comment` over merged line blocks.
- Per-selection reads of other plugins go through `run_range_each`: `mi`/`ma` over
  `textobjects`, `mm` over `motion.match-pair`, and `A-o A-i A-n A-p ]f [f` over new
  range forms in `ts` (`ts.expand`, `ts.shrink`, `ts.sibling-next/prev`,
  `ts.function-next/prev`). `A-i` first retraces the sets `A-o` replaced, then asks for a
  child.
- `surround` is a new plugin of operators (`surround.add/delete/replace`), with the pair
  chosen by an earlier `surround-pair <c> [r]`. helix captures the characters (`ms md mr`)
  and runs the operators per selection. vim's `ys ds cs` are not bound: vim has no capture
  that feeds an operator yet.
- Counts (`3w`, `5gg`, `2x`, `3C`) and registers (`"a`) live in the grammar and die with
  the command that used them (the manifest's `after` hook).
- The new doors are commands, not ABI: `buffer-previous` (core) for `gp`, and
  `scroll-line-to-top/bottom` and `scroll-goto-view-top/middle/bottom` (app, beside the
  scroll family) for `zt zb gt gc gb`. The lsp plugin grew `goto-type-definition` and
  `goto-implementation` for `gy gi`.
- Space mode is Helix's (`f F b e k s a r h c g / ? y p P R w`). weft's other groups moved
  to keys Helix leaves free: `SPC O` open & save, `SPC B` buffers, `SPC V` version control,
  `SPC l` project, `SPC i`/`SPC m` code, `SPC A` agents, `SPC G` debug, `SPC x` share.

**Phases 4 and 5 landed**, with most of what phases 2 and 3 left open. What the build
settled:

- `s S K A-K / ?` share one prompt (`helix-regex`, the `prompt` library) that previews as
  you type: every keystroke recomputes from the set the prompt opened on, the selections
  are the preview, and Escape restores that set. The prompt library grew the two hooks
  this needed, `on_change` and `trim = false` (a pattern's blanks are pattern). `S` drops
  empty pieces; `K`/`A-K` count an empty match as a match. `/ ? n N` put the match in
  place of the primary, or in select mode add it as a new primary, wrapping with helix's
  "Wrapped around document". `*` joins the selections' escaped texts with `|`, `\b` on a
  side that sits on a word edge; `A-*` without.
- The query language is the find bar's: its pure half moved from `plugins/find/search.zig`
  to a plugin library, `search` (on `regex`), which both link. Smart case, the literal
  prefilter and the wrap planning are one code path.
- The last pattern lives in core's register bank, slot 27 (`register.Bank.search`), not in
  helix. A new door `wl_register_set` (SDK `registerSet`) writes typed bytes as one value
  without touching unnamed. `n` reads it back, `"/` names it in helix, and vim's `"/p`
  pastes it (vim's `/` stays consult-line; vim has no `n`).
- `gw` labels every word of two or more word characters in view with two letters, nearest
  first, alternating after and before the cursor; the first key narrows the labels to the
  one still to type. The label machinery is a plugin library, `labels`, which snipe now
  links too (one-character labels, its behaviour unchanged).
- The caret door: `cursor-place <mode> head|inside` sits beside `set-cursor`, and the view
  draws every caret through `View.caretDrawOffset`. helix declares `inside` for its normal,
  select, capture, prompt and label modes; insert, vim, emacs and ide keep `head`.
- The flash marks every selection (`flashAll`, one `flashRanges` over the set).
- `&` pads with spaces before each selection so the n-th selection of every line lines up
  (columns in characters: a tab counts one). `gm` goes to the buffer helix last edited
  other than this one — only helix's own edits count. `mi`/`ma` gained `< a c T m` in
  `textobjects`: `angle`, `argument` (the node directly inside an argument or parameter
  list, by kind name), `comment`, `test` (tree nodes whose kind says so) and `pair` (the
  innermost bracket or quote pair).
- Phase 5 is on core's doors (§3.3): `weft.jumpPush()` before `/ ? n N *`, `gg`, `ge`, `gw`
  and `gd gy gr gi`; `C-o` (`std.navigation.back` first) / `C-i` walk the jumplist with a
  count, `C-s` saves the place, `SPC j` picks. `Q` toggles recording into the typed
  register (`@` by default), `q` plays it with a count. `SPC y` yanks and hands the
  unnamed register to the clipboard; `SPC p P R` paste the clipboard, or the unnamed
  register when the clipboard still holds its text, so a ferried identity survives.
- `SPC d` is a new lsp command, `diagnostics`: a picker over this file's diagnostics.
- Not yet: `A-u`/`A-U` (core undo is linear: a new edit drops the redo stack, so there is
  no branch to walk), `]g`/`[g` (no plugin knows a file buffer's hunks; git's hunks live in
  its status projection), `SPC S` and `SPC D` (lsp tracks one document, and its picker
  cannot open a location in another file), and `SPC '` (no door reopens the last picker).

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

Items 1-3 are done. The platform queues `PointerEvent`s through a shared
gesture reducer (`platform/pointer.zig`: click counting, wheel steps). The
shell names each one as a keyspec and dispatches it through `dispatchSpec`
(`app/pointer.zig`). The grammar and the generic commands (`pointer-click`,
`pointer-drag-select`, `pointer-extend-selection`, `pointer-activate`,
`pointer-focus-pane`, `scroll-wheel-up/down`, `activate-focused-action`) live
in `core/pointer.zig`, and `config/defaults.js` binds them. The hit facts sit
on `Head.pointer`, which guests read through `wl_pointer` / `weft.pointer()`.
Every pane's geometry from the last frame is hit-testable (`View.pane_maps`),
so a click-through lands where it points. Pointer specs resolve in the
focused pane's binding mode, not in the mode of the pane under the pointer.

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

**Built.** The clipboard is the dispatching head's (`Head.clipboard`, in memory until
the shell installs the window as its backend). Wayland reads each foreign selection
eagerly through non-blocking pipes in one epoll set (`platform/clipboard.zig`), so
`wl_clipboard_get` answers synchronously. Both doors need the `clipboard` grant, which
is config-only: declaring it in `describe()` confers nothing. vim has `"+`/`"*` (one
clipboard; primary selection is not bound). For the grammar lanes:

- helix `SPC y`: yank as usual, then `weft.clipboardSet(weft.registerTextIn(0))`;
  `SPC p`/`SPC P`: `weft.clipboardGet()` and insert it; `SPC R`: replace the
  selection with it.
- ide `C-c`/`C-x`: yank into slot 0, then `weft.clipboardSet(weft.registerTextIn(0))`;
  `C-v`: if `weft.clipboardGet()` equals `weft.registerTextIn(0)`, paste slot 0 (keeps
  ferried identity), else insert the clipboard text.
- the configs already `weft.grant("helix" | "ide", "clipboard")`.

The jumplist and macros of §2 phase 5 are core too. Grammars call `weft.jumpPush()`
before a jump (search, goto, big motion; core already records moves between entries)
and bind `jump-back`/`jump-forward` (count as `runStr`), `jumplist-pick`. Macros are
`macro-record-start <reg>`, `macro-record-stop`, `macro-record-toggle [reg]` (default
`@`, helix's `Q`), `macro-play [reg] [count]` (default: the last played or recorded,
helix's `q`), and `weft.macroRecording()` for a status chip.

### 3.4 Find and replace — plugin `find`

An incremental find bar (a bottom surface) on the 0.2 regex: C-f, F3/S-F3, C-h replace,
and highlight of every match. Before 0.2 lands, C-f falls back to `consult-line`.

**Built.** `src/plugins/find`: a `find` text-input mode plus a `.bottom` surface. Each
keystroke re-searches and selects the first match at or after where the search began,
paints the matches around it on a `find` annotation layer (closed with the bar), and
shows `n/m`. Enter/F3 and S-Enter/S-F3 step and wrap; M-r, M-c (smart → on → off) and
M-w toggle regex, case and whole word; Up/Down walk the history. C-h adds the
replacement field (`$0`–`$9` in regex mode): Enter replaces one, C-M-Return replaces all
as one undo unit, and M-Return makes every match a selection. The pure half
(now the `search` plugin library, shared with helix) is tested natively. Speed on 1 MiB comes from not re-reading the
document per keystroke (one copy, refreshed when a snapshot witness says it moved) and
from not stepping the VM per byte: the plugin prefilters on a pattern's literal lead
with a substring search and asks the library's new anchored `Regex.matchAt`, and the
library now jumps between the bytes a match can begin with (`Regex.first`). Measured on
~1 MiB: ~5 ms per literal keystroke, ~22 ms for `\d`. The one core change: the window-
bottom dock is carved for a plugin's `.bottom` surface too (`View.dockHeight`), not only
for the picker. Before that, a plugin's bottom surface drew into a zero-height strip.

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

**Landed.** What the build settled:

- `weft.provide(action, when, cmd, prio | opts)`: the shim sends `when` and the options
  as JSON, and `core/quickjs/provide.zig` parses them into the same `facts.Predicate`
  `wl_provide` decodes. `when` takes `mode`, `lang`, `tool`, `role` and `locality`; a key
  no fact answers is refused with an echo rather than widening the provider. `opts` is
  `{priority, label, group, order}`. `posture` is sayable too (`text`, `structural`,
  `field`, `capture`); the action facts and `explain-binding` carry it, so ide.js keys its
  source-only actions on `{posture: "text", locality}`. ide.js's
  F2 listing provider keys on `{ tool: "files" }`: the sidebar is a scene entry, and
  `role` is only derived for text projections today.
- Chosen contexts: `intent.Where` is `active` or `primary`. `Head.primary_focus` is
  recorded in the layout phase, beside the focus-feed publish and by the same
  `focus_source` attribute. `Plane.snapshotAt(ctx, where)` feeds one builder a `Scope`
  (the entry, its saved mode and semantic focus, and its own catalog clock), so the
  primary context isn't a second resolver. `Plane.invokeNamedAt` runs an offer in the
  primary entry by bringing it to the head for the call and restoring it afterwards.
- Doors: `wl_offers_list(where, out, cap)` writes the whole enumeration as one record,
  with the presentation already completed. `wl_intent_invoke_at(where, name, out, cap)`
  is head-gated. `wl_provide_affordance(action, label, group, order)` is the wasm twin of
  `opts`. The SDK wraps them as `offersIn`, `invokeIntentionIn` and `provideAffordance`.
- Offers-changed: the export `on_offers_changed`. `Application` fires it after the
  layout phase, at most once per wake and never inside a dispatch. It fires when
  `Plane.signatureAt(.primary)` changes. That signature is a content hash of the rows
  (intention, owner, availability, presentation) and of the context (entry, mode), not
  the catalog epoch, so a caret move or focusing a companion fires nothing.
- Metadata: `catalog.Affordance {label, group, order}` rides on `Offer` and `Candidate`
  and is never a ranking key. `intent.presentation` fills in what a provider left out.
  The label comes from `intentions.zig`'s new per-intention `label`, the group is the
  package segment, and the order is the table position. Non-standard node actions on
  the focus path are published by `core.view` as `plugin.<action id>` (for example
  `plugin.fs.entry.create-file`, labelled "New file").
- Availability: core's table is computed from an entry `Shape`. Undo and redo are
  disabled with `nothing-to-undo` or `nothing-to-redo`. `std.persistence.save` is absent
  unless some `save` provider is eligible. Core's `save-file` now excludes
  `locus == tool` (priority -1, so it is still the floor), so a git status listing isn't
  offered save, and a files listing (which provides `files-apply`) is.
- ide: `C-d` selects the word, then adds the next literal occurrence. `C-S-l` selects
  every occurrence. Both flash what they select, and Escape collapses back to one caret.

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

**Landed (2 and 3).** The doors, all generic:

- Viewport attributes `takesFocus` and `statusLine`, and `extent: {rows: n}`. A row
  extent is resolved against the view's row height at every layout
  (`window_layout.Rows`), so a zoom keeps a one-row strip one row. A pane that takes no
  focus is skipped by the window commands and by focus recovery, and the pointer's
  pane-focus door refuses it.
- A click on such a pane acts through it: `pointer-click` runs an `action` node there
  by reference (`Services.invokeActionNode`) and leaves the head's focus alone. An
  action node is clickable whether or not it is in the focus order.
- `weft.present(v, {command})`: a viewport shows the entry a command leaves active,
  which is how a plugin entry with no path is presented.
- `pointer-focus-point`: focus the pane and the node or caret under the pointer, and
  keep a selection the point is inside. It is what "the context under the pointer"
  means.
- The bundled presenter hangs an interaction with `presentation: "pointer"` or
  `"caret"` below that point.

The plugins:

- **`toolbar`** (`config/toolbar.js`) lists the pinned entries (`weft.set("toolbar",
  "pinned", ...)`) plus every non-`std.*` offer of the primary context. It arranges them
  with the shared `affordances` plugin library (groups by their most urgent `order`,
  separators between). It redraws only on `on_offers_changed`. A click runs
  `invokeIntentionIn(.primary)`, and a refusal is echoed. A disabled offer is greyed by
  a `tone` fact and stays clickable so it can say why. Measured in ide.js: a Zig file
  shows `Save Undo Redo Palette | Build Test Debug | Format Rename`; a files listing
  in the primary pane shows its node actions (New file, New directory, Rename, …); git
  status shows `Stage Diff Commit Push Pull Fetch Refresh` (git now labels its verbs
  with `provideAffordance`).
- **`contextmenu`** (mouse-3; S-F10 and Menu open it at the caret) runs
  `pointer-focus-point`, then lists `offersIn(.active)` as a head-local interaction.
  The menu hides the key-only words (navigation, input, gesture, line break); set
  `weft.set("contextmenu", "hide", [...])` to change that. Its keys (Up, Down,
  Return, Escape) and its clicks are the interaction's own bindings, so no mode is
  entered. A click on an item runs it; a click anywhere else closes the menu.
  config.js binds it on mouse-3 as well.
- ide.js's actions are intention-named (`plugin.ide.build/test/debug/format/rename`),
  because only intentions are offers, and so only they reach chrome. Each is provided
  "in source" (`posture: "text"` and `locality` local or remote), so a git status
  buffer, which is text but a tool projection, is offered none of them.
- The ide grammar reads the pointer facts: double-click selects a word (on a scene row
  it opens the row), triple-click selects the line, and C-click adds a caret. It also
  mirrors the unnamed register to the clipboard when ide.js sets `weft.set("ide",
  "clipboard", "unnamed")` next to the grant. That setting is needed because the
  clipboard doors trap without the grant. C-Home/C-End, C-g and F12 push a jump, and
  M-Left/M-Right walk the jumplist.

Not done: hover dispatches nothing, so there are no tooltips (the reason and provider
ride on each button as scene facts). A strip wider than the window is clipped, with no
overflow menu. A docked companion never becomes the primary context, so while the
sidebar has focus the toolbar still describes the editor; the context menu covers the
sidebar.

**Landed (4, and 3.1.4).** The doors, all generic:

- Chrome hits. The view records a hit rect for each tab's body, each tab's close
  glyph (`×`, drawn after every name), and each status segment
  (`View.PaneMap.chrome`). A point on one sets `Head.pointer.hit.chrome`
  (`core.pointer.Chrome`: tab or status, index, part, the tab's entry, the segment's
  command) instead of an offset or node. `pointer-click` reads it: a tab's body shows
  that entry, its glyph closes it, a segment runs its command (`name [argument]`).
  `pointer-close-tab` closes the tab under the pointer; defaults.js binds it to
  mouse-2.
- A docked viewport's entry is chrome, not a document: `Registry.holdsEntry`, from
  the entry each docked declaration last showed. The tab strip skips those entries,
  so the sidebar listing, the toolbar and the panel's entry are never tabs.
- `weft.statusSegment(text, role, priority, command)`. `ui/statusline-seg` is
  declared with a schema (`core.status_segment`), so a plugin binds it like the
  gutter. It is asked once per pane per built frame with the caret and whether the
  pane is focused, and it answers segments with a role, a side and a click command.
  The guest half is the `statusline` plugin library.
- `viewport-take <name>`: the active entry goes into a declared viewport, which is
  shown and focused, replacing what it showed. `weft.viewport(..., {shown: false})`
  starts one hidden. A hidden viewport keeps its entry for when it is shown again.
- Named signals: `wl_signal_emit(name)` and `wl_signal_subscribe(name)` →
  `on_signal(id)`, delivered at the frame boundary like `on_offers_changed`. Core
  knows no signal names and carries no payload.
- `wl_outline`: the active entry's outline symbols from the grammar's `outline.scm`.
- A REPL session strips terminal controls (CSI, OSC, other escapes, CR, BEL) from
  what it streams into its buffer, even when a sequence straddles two reads.

The plugins:

- **`panel`** (`config/panel.js`) is a bottom viewport, 12 rows, persistent, out of
  the cycle, not a focus source, hidden at start. `panel-toggle` is C-j.
- **`problems`** (C-S-m) reads a source command's rows (`path\tline\tcol\tseverity\t
  message`, default `diagnostics-list`, which `lsp` now answers from every session)
  into a semantic view of `action` rows under a heading per file. It re-reads on the
  `diagnostics` signal, which `lsp` raises when a publish lands or a set is released.
  Return or a click opens the file at the line and column. The open lands in the
  editor pane, and the panel keeps the list.
- **`terminal`** (C-`) is a LINE-MODE shell. It is the REPL session with `exec
  "${SHELL:-sh}" -i` on the other end, plus a `terminal` mode that keeps the input
  line, echoes it, and sends it on Return. It does no VT100 emulation: full-screen
  programs do not work, and colors are stripped.
- **`breadcrumbs`** is a status-line provider for text entries. It shows ` › outer ›
  inner` after the path, from the outline, cached against the document's snapshot
  witness, so a caret move is a span scan and only an edit re-reads the outline. A
  crumb's command is `breadcrumbs-jump <offset>`.
- config.js loads all four (SPC o p, SPC o t, SPC o P). helix.js loads them with no
  keys.

Not done: breadcrumbs read the grammar outline only, not LSP document symbols. The
problems list shows what `lsp` holds, which is one document per server. The terminal
has no interrupt: C-c cannot reach a piped child as a signal.

**Polish.** What screenshots of ide.js showed, and the fixes:

- A popup paints over the text beneath it. A pane's build draws its rects and then its
  glyphs, so a menu's fill used to sit under the pane's own text. Everything a build adds
  from its surfaces on is now a second layer (`render.Layers`), drawn after the first.
- A menu hung at a point (`pointer`, `caret`) is placed and clamped against the frame
  (`Hud.float_bounds`), not the pane it opened over, so a menu opened on the sidebar
  floats over the editor beside it. The box is filed with its pane
  (`View.PaneMap.float`), and a click inside it is that pane's, whichever pane is beneath.
- The context menu lists only offers that can run; the toolbar still greys them. A group
  of one joins its neighbours instead of standing between two rules. A files row's
  "Insert Before/After" stays: the listing itself advertises them (a new pending entry).
- Each pane's status line and gutter are asked with that pane's facts, built by
  `intent.entryFacts` (the builder the offers use). The mode is the head's for the entry
  the head is on, and the entry's resting mode for every other pane. Before this, every
  pane showed the focused pane's mode.
- The `weft.status` chip belongs to its system (`Buffers.status`), not the process. A
  debug session that ended in one editor used to leave "○ \*debug\* · done" in the next
  editor started in the same process.
- The terminal stays line-mode. The shell's stderr was already merged, and partial lines
  were already delivered as they were read; the prompt-less shots came from a test shell
  that was not interactive. A carriage return not followed by a newline now starts the
  line over, so zsh's end-of-output mark no longer runs into the prompt. bash with
  readline echoes the input line a second time; `--noediting` avoids it.
- Every block caret flips the glyph under it to `cursor_text`, a label's included, not
  only the primary's.

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

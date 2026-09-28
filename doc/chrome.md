# Chrome: commands, menus, status, focus, and how it looks

Status: ACCEPTED (2026-09-27); decisions in §7. Builds on doc/model.md (projections, context,
extent sets) and doc/presentation.md D2 (core-only chrome primitives). Every
claim about today's code below was surveyed at 9a1ca45.

The user's asks, restated as the problems they are instances of:

| Ask | The underlying problem |
|---|---|
| A conventional File / Edit / … menu that shows keybindings | Commands have no human identity or placement; nothing can answer "which key runs this here" |
| Palette names are inconsistent | ~500 command ids in four separator styles and several synonym families; 300 have no summary; plumbing leaks into the palette |
| The UI is text everywhere: `[Save]`, text tabs, text status | Chrome is drawn as text runs; core has only flat rects, glyphs and one stroked path; no hover |
| The status bar has a strange margin, and in the sidebar it's cut off | The status row is drawn inside the pane's 8px inset; segments have no priority, shrinking or ellipsis; the mode chip prints the raw mode id |
| A click in the ide sidebar shows a caret you can't type into | Focusing a listing row *is* entering a text field; the caret is drawn for any focused field; nothing asks whether typing would insert |
| The context menu doesn't look like one | There is no menu widget; a menu is a semantic overlay in a box |

None of these should be solved per plugin or per config. Each is one missing
concept.

## 1. Commands have an identity for machines and one for people

### 1.1 Ids: one grammar

Every command id becomes `<namespace>.<verb>[-<object>]`: lowercase, words
joined by `-`, one `.` between namespace and verb.

- The namespace is the owning plugin, or a core domain (`buffer`, `window`,
  `view`, `edit`, `selection`, `pointer`, `scroll`, `jump`, `macro`, `pick`).
- Direction words are fixed: `next`/`prev`, `left`/`right`/`up`/`down`,
  `start`/`end`, `forward`/`back` only for history. No `fwd`, `previous`,
  `backward`, `big-word` vs `WORD`.
- The standard intentions keep `std.<domain>.<verb>`.

Examples: `buffer-next` → `buffer.next`; `buf-pick` → `buffer.pick`;
`win-vsplit`, `window-vsplit`, `vsplit` → one `window.split-right`;
`hx-goto-definition`, `ide-goto-definition`, `goto-definition` → one
`lsp.goto-definition` (grammars push the jump through arity, not a wrapper).

Grammar plumbing — `vim/n/w`, `hx-count-3`, `vim-register-a`, generated
prompt `-type`/`-backspace` commands — is renamed into the grammar's namespace
and marked `internal` (§1.2). It is keymap machinery, not something a person
runs.

Duplicates collapse to one id. The survey lists them: `open` and
`buffer-close` bound twice, `cursor-up`/`scroll-page-up` registered in two
places, four split commands, four format commands, three `find-file`s, three
macro toggles, the dashed/dotted semantic-action pairs.

**All at once, no aliases.** The three configs and the tests are the only
callers in the tree. Keeping old names as aliases is the dual mechanism
doc/model.md forbids.

### 1.2 Presentation metadata

A command (and an action, and an offer — `catalog.Affordance` already has
three of these fields) carries:

| Field | Meaning | Example |
|---|---|---|
| `label` | What a person reads, Title Case | `Split Editor Right` |
| `summary` | One sentence, capitalised, full stop | `Split the focused editor, opening the same file to the right.` |
| `menu` | Where it lives in the menubar | `View/Editor Layout` |
| `group`, `order` | Separator groups and position within a menu | `layout`, `20` |
| `icon` | An icon name from the theme's set | `split-right` |
| `prompts` | It asks for more input, so the label ends in `…` (UX convention) | `Open File…` |
| `toggle` | A context key whose value shows a check mark | `viewport.sidebar.shown` |
| `internal` | Never listed in palette, menus or which-key | grammar plumbing |

The palette, which-key, menus, toolbar and context menu all show `label`, not
the id, and hide `internal`. The palette's regex hide list is deleted.

### 1.3 "Which key runs this, here"

A core query, `keysFor(target, context)`: the keys that resolve to a command,
action or intention in a given context's binding mode, shortest first,
including intention arms (C-s shows next to Save because C-s is bound to
`std.persistence.save`, whose provider there is `save`). This replaces
marginalia's context-blind scan. Menus, the palette, tooltips and which-key
all use it, so the key shown is always the one that would actually work in
the focused pane.

### 1.4 Landed (2026-09-27, branch `arc/chrome`)

All of §1.

- **One grammar.** Every command, action and semantic action is
  `<namespace>.<verb>[-<object>]` — 941 ids across the three shipped configs
  (977 before, in four spellings). `weft_membrane.command_id` is the grammar,
  direction vocabulary included (`fwd`, `previous`, `backward`, `rev` are
  refused by name; `WORD` is `big-word`); `weft.plugin` checks every entry at
  the plugin's comptime, and `e2e/identity` holds every id the configs
  register to it. An action a config offers is spelled as an intention
  (`plugin.code.format`), the other grammar a bound name may take; the std
  vocabulary follows the same directions (`std.navigation.word-prev`).
  Grammar plumbing is in its grammar's namespace (`vim.move-word-next`,
  `helix.count-3`, `vim.register-a`, `lsp.rename-type`); prompts, ex lines
  and transients derive their commands from one grammar id and their mode
  from it.
- **Duplicates collapsed, one registration each.** The window family is
  `window.*` (the `windows` plugin is gone); `files.find` is the one file
  picker (vim, helix, emacs, ide and the dashboard each had one); `lsp.*`
  pushes its own jump, so the `hx-`/`ide-goto-*` wrappers are gone; the
  dashed semantic wrappers are their dotted actions; `palette.open`,
  `buffer.pick`, `buffer.scratch`, `ts.node-kind` are single; `eval`/
  `format` and ide.js's `plugin.ide.*` are `plugin.code.*` in every config.
  Core's `file.open` and `buffer.close-*` are registered once and answered by
  the shell through an `EntryShell` door; `cursor.up`/`down` move by visual
  line through a `Panes.vertical` door; `main()`'s second `scroll.page-*`
  is gone. The registry counts a bind over a bound id, and the identity gate
  refuses any — which found `offers` loaded twice by ide.js and its toolbar
  fragment (a manifest now loads each plugin once).
- **Presentation** (`weft_membrane.presentation`: label, summary, menu,
  group, order, icon, prompts, toggle, internal, one text form both ends
  parse). Declared by `command.define(…).present(.{…})` in core, by
  `CommandEntry` fields in a wasm plugin (`wl_declare_command_meta`), by
  `weft.command(name, fn, {…})` in a JS plugin (`qjs_declare_command_meta`,
  the same body), and at the config tier by `weft.command(id, {…})`, which
  wins field by field (`Presentations`). `presentations.of(ctx, name)` is the
  one reading — an intention's is its provider's here, else the std label —
  served by `wl_command_meta`/`qjs_command_meta`. Every command has a
  one-sentence summary and every one a person runs has a label. `internal`
  means never offered to a person anywhere: a count's digits, a prompt's
  editing keys, the letter naming a register or a macro's register, a
  mode's leave, a range provider another command calls. A key pressed
  inside a chord is a person's: vim's motions after an operator (`To End of
  Line`), its text objects (`d i w` is `Inner Word`, `d a p` `A Paragraph`,
  one command each, under `op-inner`/`op-around`), helix's `g` and `[`/`]`
  leaves, snipe's operator targets. `e2e/identity` holds every key in a
  chord or a menu mode to that (transients paint their own menus). Menu paths use File, Edit, Selection, View, Go, Run, Terminal,
  Help. The icon set grew to 94 Lucide drawings. Viewports publish
  `viewport.<name>.shown`, which the sidebar and panel toggles name.
- **keysFor** (`core/keys_for.zig`): the keys that run a command, action or
  intention in a binding mode, shortest first, each key's arms walked as
  dispatch walks them — an intention arm counts through the command its
  winning offer runs (`Invokers.commandOf`), a refused one only for the
  intention. "Here" is the focused context's binding mode, or the mode a
  picker was opened from. `wl_keys_for`/`qjs_keys_for`; the chrome tooltip's
  `KeyHints` hook is filled with it.
- **Consumers.** The palette lists labels (`Open File…`), with the id, shape
  and summary as secondary text and the key beside it; its regex hide list is
  gone. which-key shows labels and hides internal commands. marginalia's
  context-blind table scan is replaced by `keysFor`, and the two doors that
  fed it (`wl_mode_names`, `wl_binding_table`) are retired. Offers take a
  plugin intention's label and every icon from the command they run, so the
  toolbar's buttons carry icons.

- **The `:` line reads short names** (`weft_invoke`, so vim's and helix's
  alike): after vim's own words (`w`, `q`, `e`, `wq`, `:N`, `s/…/…/`), a
  typed name is an id exactly; else the id whose part after a `.` it is,
  when only one (`listen` → `collab.listen`); else the command whose label
  it is, case and `…` aside, `-` for a space (`split-editor-right`). Two
  answers are listed, never guessed. Tab completes the same reading, then by
  prefix, and shows the candidates when there are several. Not aliases:
  nothing is registered twice, and `internal` commands are never offered by
  a short name or a label.

Found on the way: which-key's page clamp, stepping 12 but clamping to a
multiple of 32, cycled a short menu (0, 12, 0, …) under repeated page-down;
ide.js pinned a toolbar button to a command that no longer existed.

## 2. Menus are one widget over one model

### 2.1 The model

A menu is a projection, like everything in doc/model.md §2.4:

- `weft://here/menu/main` — the menubar: every non-internal command and
  action with a `menu` path, plus config-declared items
  (`weft.menuItem("Help/Weft Manual", "help.manual")`). Top-level order is
  conventional: File, Edit, Selection, View, Go, Run, Terminal, Help, and
  Window on macOS-style configs. Plugins place into these; they don't add
  top-level menus unless a config asks.
- `weft://here/offers/at-pointer` — the context menu, already built:
  offers for the thing under the pointer.

Both render through **one menu widget**: item rows with an icon column, the
label, the key hint right-aligned, a submenu chevron, disabled items greyed
with their reason as a tooltip, check marks for `toggle` items, separators
between groups, keyboard navigation (arrows, Enter, Escape, type-to-jump,
mnemonics), and click-away to close. The context menu looks right once the
menubar does, because they are the same widget.

### 2.2 Where menus appear

- **ide.js:** a menubar viewport along the top (above the toolbar), `F10` or
  `Alt` focuses it, `Alt+<mnemonic>` opens a menu.
- **config.js / helix.js:** no menubar by default (the palette and which-key
  are the discovery surfaces), but `weft.use("menubar")` adds the same one.
  The context menu is on for every config.

### 2.3 Landed (2026-09-27, branch `arc/chrome`)

All of §2, with two departures (below).

- **The widget** (`gfx/view/menu.zig`) is a presenter of a small scene
  vocabulary, so a menu's look is one place and its behaviour another. A
  `menu` node is a panel; its children are `menu-item` action rows,
  `separator`s, and at most one nested `menu` — the open submenu of the row
  before it. A row's facts: `keys`, `icon`, `reason` (greyed; the tooltip
  says why), `checked` and `radio`, `submenu` (a chevron), `mnemonic` (the
  underlined codepoint), `lit`. The root hangs below the node its
  `anchor-view`/`anchor-node` facts name in another view (a menubar title),
  else at the pointer or the caret, and every panel is placed against the
  frame: clamped, a submenu beside its row and flipped to the other side at
  the edge, a panel too long for the frame packed to the text grid. Rows
  paint through the `menu_item` role — the lit row's wash included, so the
  presenter's sharp focus highlight no longer reaches a menu — and the bar's
  titles through `menu_title`. `text` and `text-icons` keep a clean cell
  box; `widget` pads, rounds and shadows. The old overlay-in-a-box menu
  path is gone.
- **The behaviour** (`plugin_lib/menu`, `weft_menu`) is plain data with host
  tests (`cascade.zig`): Up/Down skip rules, headings and greyed rows and
  wrap; Right/Left open and close submenus and, at the cascade's edge, move
  across the bar; Enter/Space choose; Escape closes one level; a letter runs
  its row's mnemonic (an `&` in a label marks one, else the first free
  word-start letter) or steps through rows starting with it. The library
  also builds the scene and the interaction: the menu keys, `mouse-1`, Alt
  with a letter, `hover`, and `*`. Two generic interaction inputs made that
  possible: `*` captures every input the interaction binds nothing else to
  (a menu's keys never leak into the editor beneath), and `hover` is handed
  to an interaction that binds it by name whenever the pointer comes to
  rest on a new target — the keymap still never sees hover. Underlines show
  once the keyboard drives a menu (a click-opened one has none, as on the
  desktop).
- **The model** is the `menu` plugin's projection, `weft://here/menu/main`,
  presented `as: "menubar"` (a viewport, `config/menubar.js`) or
  `as: "menu"` (the same menus at the caret, what F10 opens where no bar is
  shown). Every non-internal command with a `menu` path, under File, Edit,
  Selection, View, Go, Run, Terminal, Help (`weft.set("menu", "menus", […])`
  replaces the list); rows sorted by group — each menu has a default group
  order, `weft.set("menu", "groups", ["File\tnew open …"])` — then order,
  then label, a rule where the group changes, and a verb named once per
  menu (the row a key runs wins: ide's Copy over core's). Config places any
  command with the config tier's `weft.command(id, {menu, group, order})`;
  rows that run a command WITH an argument are the plugin's own config,
  `weft.set("menu", "items", ["View/Appearance\tToolbar\tviewport.toggle
  toolbar\tviewport.toolbar.shown"])`.
- **Here is the primary context.** A row's key hint, its greying and its
  run are all of the primary context — the editor, even while the sidebar
  has the keys. One reading door serves the first two: `wl_command_at`
  (`core/standing.zig`) says whether a command, action or intention would
  run in a chosen context and why not, in words, and which keys run it
  there; `keys_for.keysForAt` asks intention arms of that context, and a
  command whose key is refused for the moment shows the key that means it (a
  greyed Undo shows C-z). Running is `wl_intent_invoke_at`, which now runs
  a name that is no intention as a command in the chosen context. A row
  with an argument still to give asks for it, as the palette does, and runs
  in the primary context too once it has it (`weft_invoke`'s
  `invokeLineIn(.primary, …)` over `wl_run_argv_at`, `wl_run_argv` in a
  chosen context through the same `intent.runAt`): File ▸ Save As… from the
  sidebar saves the editor, as does a config `items` row carrying its own
  argument. A menu's rows are asked about when it opens, never kept.
- **Toggles and choices.** A `toggle` context key checks its row; the form
  `key=value` is one choice among several (a dot). The frame publishes the
  style it draws as `theme.chrome`, and View ▸ Appearance ▸ Chrome Style's
  Text / Text with Icons / Widgets are commands checked by it. Sidebar,
  Panel, Menu Bar and Toolbar are checked by `viewport.<name>.shown`.
- **Keys.** ide.js docks the bar above the toolbar. Alt+F, Alt+E, … run
  `menu.open-file`, … (one command per conventional menu, "File Menu" in
  the palette — a key never runs an internal command). F10 lights the bar;
  in ide.js F10 is `[plugin.debug.step-over, menu.focus-bar]`, and dap.js
  publishes `dap.session`, so F10 steps while a session is live and opens
  the menubar otherwise. S-F10 and Menu open the context menu at the caret
  in config.js as in ide.js.
- **The context menu** is the same widget: `offers` builds `weft_menu`
  entries (labels, icons, keys in the context it describes, its rules), so
  it has hover, letters and keyboard cues too; greyed offers stay omitted.
- **Content.** File (New File, Open File… C-p, Open Path…, Browse Files,
  Open Recent Project, Open…, Save C-s, Save As…, Close Editor, Close
  Without Saving, Notes ▸, Quit), Edit (history, clipboard, find, Find in
  Files, refactor, format, comment, Insert ▸, Lines ▸, Macros ▸,
  Transform ▸), Selection, View (Command Palette, Sidebar, Panel, Problems,
  Source Control, Appearance ▸, Editor Layout ▸), Go (Back/Forward, buffers,
  Go to Line, symbols, definition and references, Next/Previous Problem),
  Run (Run, Test, the build targets, Start/Stop Debugging, Continue, Step
  Over/Into/Out, breakpoints, Agents ▸, REPL ▸, Tools ▸), Terminal, Help
  (Show Key Hints, Explain Binding, and the permissions and identity rows the
  windowed app registers).

Departures, and what is left:

- **No bare Alt.** Alt pressed and released alone does not light the bar:
  a bare modifier is state, swallowed at dispatch, and the platform delivers
  no key releases. F10 lights it; Alt with a letter opens a menu.
- **`weft.menuItem` is plugin config**, not a new config verb: rows with
  arguments are the menu plugin's `items` list, beside the config tier's
  `weft.command` for placing any command. A second fragment setting `items`
  replaces the first's list (ide.js lists the menubar's toggle with its own).
- No dynamic submenus (Open Recent is the project picker, not a ▸ of
  recent files), no Revert for a file (there is no such command), no
  Outline toggle (ide.js composes no outline), and nothing scrolls: a panel
  taller than the frame packs its rows and, past that, loses its tail.

## 3. How chrome looks: two styles, chosen by theme

### 3.1 Roles, not text

Chrome nodes stop being text runs. Every chrome node carries a **role**
(`button`, `tab`, `menu-item`, `status-segment`, `chip`, `separator`, `row`,
`header`) and **state** (`hover`, `pressed`, `disabled`, `selected`,
`focused`, `checked`). A **chrome style** turns role + state + content (label,
icon, key hint) into draw items. Plugins never choose how a button looks;
they say it is a button.

### 3.2 Two styles

- **`text`** (the default for config.js and helix.js): cell-aligned, still
  keyboard-first, but no brackets. Buttons and tabs are padded cells with a
  subtle background; the focused tab is emphasised by colour; status
  segments are separated by spacing and colour, not `│`.
- **`widget`** (ide.js): not cell-aligned. Rounded pills for buttons, real
  tabs with close glyphs that appear on hover, icons beside labels, hover and
  pressed states, shadows under menus, 1px dividers.

The style is a theme value (`weft.set("theme", "chrome", "widget")`), so a
vim user can pick widgets and an ide user can pick text. It is never a
per-plugin choice.

**Trying another style must be a one-line change, and live.** There are three
settings, not two: `text`, `text-icons` (cell-aligned text plus small
monochrome icons in tabs, status and buttons), and `widget`. The value is
read at draw time from the theme slot, so `set-color`-style runtime
rebinding (`:set-theme chrome widget`, or a palette toggle) switches the
whole UI without a restart or a config edit. A test switches all three
styles on one frame and checks every chrome role renders under each.

### 3.3 What core must add

- **Draw primitives** (already decided as D2 in doc/presentation.md, not yet
  built): rounded rect (fill and stroke), clip, and image or icon.
- **Icons:** a bundled icon set as vector paths (a permissively licensed
  set such as Lucide, ISC), drawn through the path primitive and tinted by
  theme. Icons are named in metadata; a theme can swap the set.
- **Hover:** pointer motion updates a hover target in the frame input
  (doc/model.md §2.7 snapshot), not a command dispatch. Hover state reaches
  the chrome style; a tooltip appears after a delay with the label, key hint
  and, for a disabled item, the reason.

*Landed (2026-09-27, branch `arc/chrome`).* All of §3.

- **Primitives.** `scene.DrawItem` grew `rrect` (uniform radius; a fill, or
  an outline when `stroke_width > 0`; `blur` for shadows) and `clip`
  (replaces the clip for what follows, never nests; every item list starts
  and ends unclipped), and `PathVerb` grew `close`. Skia is the only
  backend in the build and implements all three. No plugin door emits them.
  The view's `Rect` carries a `shape` (fill, rounded, icon) so a pill, its
  icon and a highlight keep paint order in one list; a `Run` carries an
  optional clip. `bench-raster`'s bare frames are byte-identical (same
  hashes); its new chrome cases put the cost of a style at +0.03 ms (`text`)
  and +0.11 ms (`text-icons`, `widget`) on a 1600×1000 frame.
- **Icons.** `gfx/icons.zig` parses stroke-style SVG (every path command,
  arcs to cubics; circle, ellipse, rect, line, poly) into path commands at
  load. The bundled set is 47 Lucide icons, the upstream SVG files unchanged
  in `src/gfx/icons/lucide/` beside Lucide's `LICENSE` (ISC, with the
  Feather MIT notice it carries). Chrome asks for icons by chrome name
  (`save`, `split-right`, `error`); `theme/icons` picks the set (`lucide`,
  or `none` to turn icons off).
- **Roles and styles.** `gfx/view/chrome.zig`: `Role`, `State`, `Content`,
  and one painter per role under each of `text`, `text-icons` and `widget`.
  Action nodes are buttons (a menu's are menu items across the row); tabs are
  `tab` roles laid out per style, the close part always hit-testable and,
  under `widget`, drawn only on the active or hovered tab; popup and menu
  frames are panels (the text styles keep the old outlined box, so no popup
  golden moved; `widget` rounds, outlines softly and shadows menus); pane
  dividers and the offers plugin's separators (now `role = "separator"`)
  are separators; status segments and chips go through roles, and the
  bracketed save and fetch warnings are chips in the same columns. The
  status line's layout and the menu's structure are unchanged — §4 and §2.
- **The style is a theme value, live.** `theme/chrome` is read at the top of
  every frame. config.js and helix.js set `text`, ide.js `widget`;
  `theme.set-chrome <style>` and `theme.cycle-chrome` bind it at the
  transient tier, so the next frame is in the new style.
- **Hover.** `app/pointer.zig`'s `Hover` is frame input: motion updates the
  target (pane, chrome part or scene node) and dirties the frame only when
  the target changes — no keyspec, no dispatch. Each pane's `Hud.pointer`
  carries the target, `pressed` and `tooltip`. The tooltip delay is a loop
  timer (`tooltip_delay`); the pane built last paints the frame's tooltip
  above every pane. Its key hint is frame input (`Hud.key_hint`): when the
  pointer settles — the wake the delay ripens — the shell asks §1.3's
  `keysFor` for what the element under it runs (`View.hoveredCommand`, what
  the last frame's hovered element offered) and keeps the answer on the
  `Hover` until the target changes. Building a frame asks nothing: it
  syncs no intent plane (`Plane.syncs` holds still across a build) and
  times nothing — a message's showing is noted at the wake's boundary
  (`EchoTiming.note`, `Application.observe`), so one frame input drawn twice
  draws the same lists.

What this leaves for the later lanes, and two things found on the way:

- A button's icon comes from an `icon` fact on its node. Nothing supplies
  one yet: §1.2's `icon` metadata has to reach the offers projection's
  nodes. Status segments likewise have `icon` and `tooltip` fields no
  producer fills.
- A menu's focused row is still washed by the scene presenter's row
  highlight, sharp in every style; §2's menu widget should route focus
  through `menu_item` too, as hover already is. (Done: §2.3.)
- `widget` tabs sit in a strip one text row tall, which is cramped for real
  tabs. A taller strip is a carve (layout) change, for §4's layout pass.
- `theme/chrome` and `theme/icons` share the `theme/<leaf>` family with
  row-role styling, so a producer naming a row role `chrome` or `icons`
  would read them. Harmless (an unknown class reads as `normal`), but a
  sign the family holds two kinds of value.
- `set-color` bound at the transient tier under one owner and never
  unbound, so a second `set-color` of the same name tied with the first and
  lost (`Container.betterThan` keeps the earlier). Fixed for the class:
  `Container.bind` at the transient tier replaces the same owner's binding
  on that slot, so the chrome switch no longer unbinds first.

## 4. The status bar

### 4.1 Status is a projection too

A status bar is a projection of the status segments of a context:
`weft://here/status/primary` (the primary context) or the per-pane status of
one entry. Two placements, chosen by config:

- **Per pane** (config.js, helix.js): today's status line, fixed (§4.2).
- **One global bar** (ide.js): a bottom viewport, full window width,
  presenting `status/primary`. Panes have no status line of their own
  (`statusLine: false` is already a viewport attribute), and the sidebar
  never has one.

### 4.2 Layout rules

- **Flush:** the status row is drawn edge to edge across the pane or window,
  not inside the content inset.
- **Sides:** segments declare `left` or `right`.
- **Priority and shrinking:** each segment has a priority, a full form and a
  compact form. When space runs out, lower-priority segments shrink to their
  compact form, then drop; text that still doesn't fit ends in `…`. Nothing
  is cut mid-glyph.
- **Mode chip:** grammars declare a display name per mode (`NORMAL`,
  `INSERT`, `SELECT`). A mode with no display name shows no chip, so the
  modeless ide shows none; nobody ever sees `ide-structural`.
- **Clickable:** every segment can carry a command, a tooltip and an icon.

### 4.3 What the global bar shows (ide.js)

Left: place (project or peer name), branch, problems count (errors and
warnings, click opens the problems panel), running tasks. Right: `Ln 12,
Col 4`, selection count when several, indentation, encoding, line endings,
language, notifications. Each is an ordinary segment a plugin publishes
(git publishes branch, lsp publishes problems), so none of this is ide code.

### 4.4 Landed (2026-09-27, branch `arc/chrome`)

All of §4.

- **Flush.** `View.carve` cuts the status row off the pane's frame before
  the content inset: edge to edge, the pane's last row, no margin and no
  leftover cell; the body keeps its margins and its row count. The text sits
  on the body's columns inside the bar. A docked viewport may declare
  `extent: { rows: 0 }` when it has a status line — a pane that is only its
  status row, with no body margins (`Rows.px`).
- **Layout** (`gfx/view/status_layout.zig`, pure, unit-tested). A segment
  has a side, a priority, a full and a compact form, and whether its text
  may be cut (`elide`, at its start for a path, its end for a message). Both
  clusters share one budget; segments yield lowest priority first, each as
  little as makes the row fit: a cuttable one is cut to exactly what fits
  (ending or starting in `…`, never below six cells, always between
  codepoints), else it takes its compact form if that fits, else it goes
  whole and the next one yields. Equal priorities yield later-drawn first.
  Widths are measured in the frame's chrome style (a chip's padding, an
  icon's cells), so nothing is clipped at a pane's edge. An icon stands in
  for a leading glyph that stands alone (`● `, `✦ 2`, `E 2`), else takes
  two cells before the text where the style draws icons.
- **Every status fact is a segment.** The save and fetch chips, the
  modified mark, the message, the plugin chip (`weft.status`), the peers
  and the link left the `Hud` and became core providers beside the mode
  chip and the path, joined by the place, `Ln 12, Col 4` (compact `12:4`,
  click → `jump.line`), the selection count and the language. The wire
  (`core.status_segment`, restated in `weft_statusline`) carries the compact
  form, priority, icon and tooltip; `surface.Role` learned `warning` and
  `danger` (the problems counts were the third user of those colours).
- **Notices are not a plugin's chip.** The chip (`weft.status`,
  `Buffers.status`) is only ever what a plugin published for itself. What
  no head asked for — a plugin's background echo, a spawn or render refusal
  — is a NOTICE (`Buffers.notices`, `status_feed.Notices`): a feed of its
  own that counts its sayings, drawn as its own segment beside the head's
  message under the same timing rule as an echo (`editor/echo-ms` from the
  wake that sees it said, then gone). `renderInto`, `applyActionResult` and
  the transcript fill take a `Notices`, so a refusal cannot be written into
  the chip: a background lsp refusal no longer replaces dap's `● *debug* ·
  running` for the rest of the session.
- **Mode names.** A grammar declares a mode's name and tone
  (`weft.modeDisplay`, `wl_mode_display`): vim `NORMAL`, `INSERT`,
  `VISUAL`/`V-LINE`, `O-PENDING`, `REPLACE`; helix `NOR`, `INS`, `SEL`;
  emacs and ide none. A mode no grammar named shows no chip — so ide shows
  none — except that a transient mode left unnamed (a count, a menu, the
  picker) shows the entry's resting mode's name, so the chip holds still
  through a chord. The chip's colour is the theme's for the tone
  (`Theme.modeChipColor(tone)`); the prefix sniffing is gone.
- **Status as a projection.** `weft://here/status/primary|active`, produced
  by core (`status_projection.zig`). A pane presenting one draws that
  context's segments on its one row (`Hud.status_of`), and a click on a
  segment acts in the context it describes (`Chrome.acts_in`).
  `config/statusbar.js` docks it along the bottom, `{ rows: 0 }`, and sets
  `weft.set("editor", "pane-status", "off")` so no pane — tiled or docked —
  carries a line of its own; ide.js uses it, last among its docks. A
  viewport docked later stays outermost however late an earlier one is
  shown (`Layout.dockWithin`), so the panel opens above the bar.
- **Owners.** git publishes the branch (one `git rev-parse` per place, said
  as `git.branch`; click → `git.status`); problems the error and warning
  counts (`problems.count`; click → `problems.open`); make and run what is
  running (`make.running`, `run.running`, through `output.Running`); indent
  its unit (`Spaces: 2`). Core's are the place, Ln/Col, the selection count,
  the language, the link and the notifications. Encoding and line endings
  are OMITTED: weft keeps no encoding (it reads UTF-8) and no line-ending
  style, and the bar does not invent one. The language has no click: there
  is no language picker. repl, terminal and dap publish no running segment
  yet (terminal and repl already say `*.session`; a segment is theirs to
  add).
- **Go to Line** is core's `jump.line [n]` (every grammar has it); ide's
  `ide.goto-line` was its duplicate and is gone.

Found on the way:

- The status answers are cached by a key that includes the facts' digest,
  whose open keys hash the context store's REVISION. A plugin whose segment
  changes between entry edits (git's branch, a build ending) invalidates by
  publishing a context key — honest, since each is a real fact — but any
  publish anywhere re-asks every pane's status. Coarse, cheap today.
- Panels were found by their edge (`dockedPanel(.bottom)`), which stops
  identifying one once a panel and a bar share an edge; the e2e harness
  finds a viewport by its name now (`viewportPane`).
- The which-key host fallback panel still headlines the raw menu mode id;
  that panel is which-key's.

## 5. Focus in structural views

This is the hard one. The goal: the files listing knows nothing about vim or
ide, and every grammar gets behaviour its users expect, without per-grammar
code in any projection.

### 5.1 What goes wrong today

A listing row's only focusable node is its name field. Focusing the row
therefore means focusing a text field, which sets the `field` posture, and
the renderer draws a caret for any focused field. It never asks whether a
keystroke would insert. ide then makes that caret a blinking bar. So a click
produces the universal "type here" signal in a place where typing does
nothing.

### 5.2 The model

Three rules, each small, which together remove the mismatch for every
grammar:

1. **Focusing a row and editing its text are different states.** A row
   focus is a `rows` extent (doc/model.md §2.6). Editing is a `text` extent
   inside one of the row's fields. The `field` posture means *editing*, not
   "a row whose leaf is a field is focused". A projection marks one field
   per row as its **primary field** (a file's name); it knows nothing else.
2. **The grammar declares its structural focus granularity:**
   - `text` — oil/dired style. Focusing a row immediately edits its primary
     field (today's behaviour). vim, helix and emacs declare this.
   - `row` — list-control style. Focus is the row: a highlight, no caret.
     Editing is entered explicitly, with the standard intention
     `std.editing.begin` (F2, or a slow second click on the focused row, the
     platform convention), committed with Enter or by moving focus away, and
     cancelled with Escape. Printable keys do **type-ahead**: jump to the next
     row whose label starts with what you typed, a core behaviour over any
     rows, needing nothing from files. ide declares this, and it is the
     default for a grammar that declares nothing, because it can never show a
     misleading caret.
3. **The caret shape is derived, not chosen.** A bar caret is drawn only
   where printable input inserts (the binding mode has a commit command); a
   block caret where the position matters but typing doesn't insert (vim
   normal). A grammar can no longer draw a bar where typing does nothing,
   which is exactly ide's bug today.

Pointer follows the same declaration: in `row` granularity a click selects
the row, a double-click activates it, a slow second click renames; in `text`
granularity a click places the caret, as now.

### 5.3 Why this generalises

- The files plugin changes by one declaration (its primary field). Git
  status, the problems panel, the outline and the dashboard get the same
  behaviour for free.
- A new grammar gets correct list behaviour with no work, and opts into
  oil-style text editing with one line.
- vim and helix keep modal editing of listings: in `text` granularity their
  normal mode already shows a block caret, which is honest.

### 5.4 Landed (2026-09-27)

What the build settled:

- **The states.** `Head.SceneSelection.edit` is the field being *edited*
  together with the text it began from (`origin`, for cancel) — one
  optional value; a row focus leaves it null. `core/scene_edit.zig` is the
  one place a focus lands (`land`): every focus path (`Services.focusView`,
  `moveHeadFocus`, a provider's focus request, the row mapping in
  `selection.zig`) goes through it, and it alone reads the granularity.
  Under `row` every edit is a begun one (`scene_edit.begun`): it takes
  printable input, answers activate and cancel, and commits when the focus
  leaves. A field, a `began` flag and an origin were three fields once, and
  a commit that failed partway (or a buffer switch, or a `text`→`row`
  switch) could leave a field edited that nothing typed into; commit and
  cancel now end the edit before anything that can fail.
- **The declaration** is a command, `mode.set-structural-focus <mode>
  text|row`, stored PER MODE in the keymap (`Keymap.granularityOf`, like a
  mode's display name) and read down the fallback chain, else from the mode
  the active entry rests in (a menu, the picker), else `row`
  (`Services.granularityFor`). vim declares `text` for `normal`, helix for
  `helix-normal`, emacs for `emacs`; ide `row` for `ide`. It was one
  system-wide value, so the last grammar loaded set every listing's
  granularity (loading ide's plugin beside vim turned vim's listings into
  rows); per mode, each grammar keeps its own. The files projection's one change
  is `.primary = true` on the name field (`scene.Content.field.primary`,
  carried in the field's flags byte on the wire, so older encoders decode
  unchanged).
- **Editing under `row`.** `std.editing.begin` is in the vocabulary; the
  scene adapter offers it on a row that holds a field (labelled as the
  provider labels `field.edit`, "Edit name"), routed to `field-edit`, which
  selects the whole name. While an edit is begun the adapter offers
  `std.target.activate` as *commit* (so every grammar's Return commits
  without a binding) and `std.gesture.cancel` as *cancel*; ide binds Escape
  to `["std.gesture.cancel", "ide-escape"]`. A begun edit takes printable
  input itself (`scene_edit.textCommit`: the mode's commit command, else core's
  `insert-text` while an edit is begun), so ide stays in `ide-structural`
  and needs no field-resting mode. Committing ends the edit and, when the
  text changed, runs the view's `view.apply`. Whether that asks is the files
  listing's policy, read off the draft (`Model.applyAsks`): one name typed —
  a row renamed in place, a new row named — applies as typed; a delete, a
  paste, several rows, or a name a sibling holds asks first. Moving the
  focus off the edited row commits the same way, and so does the head
  leaving the entry by any door — a pane switch, a buffer switch, an open
  (`Buffers.switchTo` runs `leave_edit`) — so no edit is saved half-typed
  into an entry to resume later. Delete mid-edit deletes text, never the row.
- **Type-ahead** (`core/type_ahead.zig`) runs where rows take the key —
  ONE predicate, `rowsTakeKeys`, which dispatch asks before any row moves
  and the frame asks to show a focused row instead of a caret: `row`
  granularity, no picker or interaction holding the keys, no edit begun,
  and no text commit claiming the key (a picker's query, a prompt's line,
  snipe's character; a resting mode's own typing yields to a focused
  scene, which holds none of its entry's text). Type-ahead ran before the
  commit was looked up, so a palette or a rename prompt opened over a
  focused sidebar row lost its letters to the rows. It is a 1 s prefix
  searched from the focused row, one repeated key stepping through the rows
  it starts, wrapping, case-insensitive. A scene row's label is its primary
  field's text, else its focusable node's label. A text projection's rows
  (git status, grep results) are its visible focusable nodes, and a row's
  label is its subject (`projection.Node.label`: the last keyed part, else
  the editable part, else the row) — so git declares each file row's path
  as its subject part, and type-ahead matches `f.txt`, not `modified`.
- **Pointer.** The platform marks a press `slow` when it follows the
  previous press of its button after the double-click interval
  (`multi_click_ms`) but within `slow_click_ms` (3×). `pointer-click` under
  `row` begins an edit on a slow second click that lands on the focused row
  the previous press also hit, and activates on a double click; a double
  click whose first half began an edit ends it first. A double click
  inside a name ALREADY being edited is the field's: `pointer.activate`
  (where ide's `double-mouse-1` sends a scene) selects the word at the
  field's caret and neither commits nor opens — it used to commit the
  half-typed name (a rename on disk) and open the row. Scene hits carry no
  byte offset inside a field yet, so the word is the caret's, not the
  pointer's.
- **The caret** is derived in `CursorConfig.styleFor(mode, inserts)`: where
  typing inserts, the declared shape or a bar; where it does not, a block
  (an `underline` a grammar keeps). ide no longer declares a shape for
  `ide-structural`. The scene renderer draws a field's caret only for
  `Document.editing`. A text projection focused by rows (the status
  listing) sets `Hud.row_focus`: its line is washed as a focused row and no
  caret is drawn.
- **For free:** the problems list, outline, dashboard and places are scenes
  of focusable labels and action rows, so they get the row focus, the
  highlight and type-ahead; the status listing gets the row focus through
  `row_focus`, and type-ahead over its rows. Action rows keep acting on a
  single click (a button is its action).
- Found on the way: the files apply dialog bound `enter`/`escape`, which no
  key is spelled; they are `Return`/`Escape` now.

## 6. Order

1. **Command identity:** the id grammar and rename, presentation metadata,
   `keysFor`, palette and which-key switched to labels and real keys.
   Everything else depends on this.
2. **Focus granularity** (§5): independent of the visual work, and the most
   visible fix for the ide sidebar.
3. **Chrome primitives and hover** (§3.3), then the `text` and `widget` chrome
   styles over roles (§3.1-3.2).
4. **Menus** (§2): the menu model and widget, the menubar in ide.js, the
   context menu restyled through the same widget.
5. **Status** (§4): layout rules and mode display names for per-pane lines;
   the global bar for ide.js.

## 7. Decisions (2026-09-27, all accepted)

1. **Rename every command id at once, no aliases** (§1.1).
2. **Default structural focus is `row`** for grammars that declare nothing;
   vim, helix and emacs declare `text` (§5.2).
3. **Menubar on in ide.js only**; available to the others by fragment (§2.2).
4. **Chrome style is a theme value**, `text` for config.js and helix.js and
   `widget` for ide.js (§3.2). The user asked for clean text in vim/helix,
   with the other styles a quick, live switch away (`text-icons`, `widget`).
5. **Status placement:** per-pane for config.js and helix.js, one global bar
   for ide.js (§4.1).
6. **Icon set:** bundle a permissively licensed vector icon set (e.g.
   Lucide, ISC) rather than draw our own (§3.3).

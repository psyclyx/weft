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
  above every pane. Its key hint is a `chrome.KeyHints` hook that §1.3's
  `keysFor` fills; until then hints are absent.

What this leaves for the later lanes, and two things found on the way:

- A button's icon comes from an `icon` fact on its node. Nothing supplies
  one yet: §1.2's `icon` metadata has to reach the offers projection's
  nodes. Status segments likewise have `icon` and `tooltip` fields no
  producer fills.
- A menu's focused row is still washed by the scene presenter's row
  highlight, sharp in every style; §2's menu widget should route focus
  through `menu_item` too, as hover already is.
- `widget` tabs sit in a strip one text row tall, which is cramped for real
  tabs. A taller strip is a carve (layout) change, for §4's layout pass.
- `theme/chrome` and `theme/icons` share the `theme/<leaf>` family with
  row-role styling, so a producer naming a row role `chrome` or `icons`
  would read them. Harmless (an unknown class reads as `normal`), but a
  sign the family holds two kinds of value.
- `set-color` binds at the transient tier under one owner and never unbinds,
  so a second `set-color` of the same name ties with the first and loses
  (`Container.betterThan` keeps the earlier). The chrome switch unbinds its
  last binding first; `set-color` should too.

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

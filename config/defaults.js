// defaults.js — shared, editor-agnostic key BINDINGS every config pulls in with
// `weft.use("defaults")` at its top. Core ships the COMMANDS + the interactive
// modes (pick, which-key); the key→command bindings are config data, so they're
// rebindable like everything else and the core carries no key policy. An
// including config's own later binds override these (higher priority / last-wins).

// ── The fuzzy picker / command palette (the "pick" mode) ──────────────
// An authored fallback list (doc/configuration.md §5.2): accept the
// highlighted candidate, else accept whatever was typed.
weft.bind("pick", "Return", ["pick-accept", "pick-accept-input"]);
weft.bind("pick", "Escape", "pick-cancel");
weft.bind("pick", "C-g", "pick-cancel");
weft.bind("pick", "BackSpace", "pick-backspace");
weft.bind("pick", "Down", "pick-next");
weft.bind("pick", "Up", "pick-prev");
weft.bind("pick", "C-n", "pick-next");
weft.bind("pick", "C-p", "pick-prev");
weft.bind("pick", "Tab", "pick-complete");
weft.bind("pick", "C-j", "pick-accept-input");
weft.bind("pick", "S-Return", "pick-accept-input");

// ── which-key navigation keys ─────────────────────────────────────────
// META keys that act on the which-key hint while you're mid-chord, WITHOUT
// dead-ending the sequence: dispatch consults this "menu-nav" layer before
// feeding the key, so paging a long menu keeps the chord `pending` and the
// popup open. Backspace steps back a level (handled in core). These are the
// convenient defaults — rebind them here, they're just config data:
//   C-n / C-p  — page the hint down / up (finger-friendly; the primary keys)
//   PageDown / PageUp — the same, for the keys that have them
weft.bind("menu-nav", "C-n", "which-key-page-down");
weft.bind("menu-nav", "C-p", "which-key-page-up");
weft.bind("menu-nav", "PageDown", "which-key-page-down");
weft.bind("menu-nav", "PageUp", "which-key-page-up");

// How you LEAVE a menu, and how you ask for the hint now. `weft.menu(name)`
// used to bind these three into every menu mode from inside core — including
// F1 to `which-key-now`, a command core does not own and cannot know exists.
// Declaring a menu is a fact about the mode; what keys it answers is this
// file's business. Every menu inherits "menu", so once covers all of them.
//
// These sit on "menu" and not "menu-nav" because the two layers do different
// jobs: a "menu-nav" key acts on the hint and KEEPS the chord pending, which
// is right for paging and wrong for Escape. "menu" falls back to "menu-nav",
// so a menu reaches both.
weft.bind("menu", "Escape", "menu-escape");
weft.bind("menu", "C-g", "menu-escape");
weft.bind("menu", "F1", "which-key-now");

// ── The pointer ────────────────────────────────────────────────────────
// A click is a key (`src/core/pointer.zig` has the grammar): `mouse-1` is the
// primary button going down, `double-`/`triple-` the second and third quick
// press, `drag-mouse-1` motion with it held, `up-mouse-1` its release,
// `wheel-up`/`wheel-down` one wheel step, and `C-`/`M-`/`S-` modifiers go in
// front. These are the everyday meanings, on the global layer so every
// grammar gets them; a config or a mode rebinds any of them like any key.
//
// `pointer-click` focuses the pane under the pointer first, so a click in an
// unfocused pane lands where it points (click-through). A double or triple
// click re-places the caret until a grammar gives it a meaning of its own.
weft.bind("global", "mouse-1", "pointer-click");
weft.bind("global", "double-mouse-1", "pointer-click");
weft.bind("global", "triple-mouse-1", "pointer-click");
// A click on a tab shows it and one on its close glyph closes it (pointer-click
// reads the chrome under the pointer); a middle click anywhere on a tab closes
// it. A status segment that names a command runs it on a click.
weft.bind("global", "mouse-2", "pointer-close-tab");
weft.bind("global", "drag-mouse-1", "pointer-drag-select");
weft.bind("global", "S-mouse-1", "pointer-extend-selection");
weft.bind("global", "wheel-up", "scroll-wheel-up");
weft.bind("global", "wheel-down", "scroll-wheel-down");

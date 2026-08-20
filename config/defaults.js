// defaults.js — shared, editor-agnostic key BINDINGS every config pulls in with
// `weft.use("defaults")` at its top. Core ships the COMMANDS + the interactive
// modes (pick, which-key); the key→command bindings are config data, so they're
// rebindable like everything else and the core carries no key policy. An
// including config's own later binds override these (higher priority / last-wins).

// ── The fuzzy picker / command palette (the "pick" mode) ──────────────
weft.bind("pick", "Return", "pick-accept");
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


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

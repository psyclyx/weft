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


// ── Syntax grammars ───────────────────────────────────────────────────
// Weft ships NO languages. Core knows how to load a tree-sitter grammar and
// highlight with it; which grammars exist is config data, exactly like the
// bindings above — so adding a language is a line here, never a rebuild.
//
// `grammar-add <exts> <grammar> <symbol> [query] [outline]`:
//   exts     comma-separated file extensions
//   grammar  a NAME resolved along the grammar search path
//            (WEFT_GRAMMAR_PATH, like PATH), or an absolute package dir
//   symbol   the grammar's `tree_sitter_*` entry point
//   query    optional; defaults to <package>/queries/highlights.scm
//   outline  optional; defaults to <package>/queries/outline.scm — the
//            document-symbol query, capturing "item" and "name"
//
// Both queries come from the grammar package, so a language needs nothing
// here beyond its name.
weft.run("grammar-add", ".zig", "zig", "tree_sitter_zig");
weft.run("grammar-add", ".fnl", "fennel", "tree_sitter_fennel");
weft.run("grammar-add", ".lua", "lua", "tree_sitter_lua");
weft.run("grammar-add", ".nix", "nix", "tree_sitter_nix");
weft.run("grammar-add", ".js,.jsx,.mjs,.cjs", "javascript", "tree_sitter_javascript");
weft.run("grammar-add", ".html,.htm", "html", "tree_sitter_html");

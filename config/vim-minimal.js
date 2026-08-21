// vim-minimal.js — a leaner, more traditional vim config. Load with:
//   weft --config config/vim-minimal.js
//
// Demonstrates: vim modal editing, a FLAT space-leader (no nested submenus, the
// which-key hint is a single flat list), the instant which-key (no idle delay),
// and reusing vim's own `window` chord (C-w) for splits. Compare with the
// default doom config (nested submenus) and helix.js (a different editor).

// A compact catalog — modal editing + the everyday tools.
[
  "edit", "complete", "project", "palette", "motions", "textobjects", "operators", "vim",
  "comment", "autopair", "consult", "git", "grep", "make", "run", "fmt", "buffers",
  "windows", "modes", "dired", "which_key",
].forEach((p) => weft.plugin(p));
weft.use("defaults"); // shared pick/editing/menu-nav bindings

// which-key: no delay here (show the flat leader map the moment you press SPC).
// F1 forces it (and the leader menu) from anywhere via the global layer.
weft.set("which_key", "delay-ms", "0");
weft.bind("global", "F1", "which-key-now");

// Actions: one key, resolved by the buffer's language. `eval` runs the buffer
// (a .zig buffer builds, else the language runner); `format` formats it. A
// language plugin can weft.provide another provider without touching this keymap.
weft.action("eval");
weft.provide("eval", {}, "run-line");
weft.provide("eval", { lang: "zig" }, "make-build");
weft.action("format");
weft.provide("format", {}, "format-buffer");

// Flat leader (SPC) as one-key SEQUENCES: every `space X` is a single action, so
// the which-key popup is one flat list (the simplest menu shape — no groups).
weft.bind("normal", "SPC :", "pick-commands"); // SPC : — run a command (M-x)
weft.bind("normal", "SPC SPC", "find-file"); //     SPC SPC — find file
weft.bind("normal", "SPC ,", "buf-pick"); //      SPC , — switch buffer
weft.bind("normal", "SPC /", "grep"); //          SPC / — search project
weft.bind("normal", "SPC f", "find-file"); //         SPC f — find file
weft.bind("normal", "SPC b", "buf-pick"); //          SPC b — switch buffer
weft.bind("normal", "SPC s", "save"); //              SPC s — save
weft.bind("normal", "SPC g", "git-status"); //        SPC g — git
weft.bind("normal", "SPC e", "consult-line"); //      SPC e — jump to a line
weft.bind("normal", "SPC d", "dired"); //             SPC d — dired
weft.bind("normal", "SPC c", "comment-line"); //      SPC c — toggle comment
weft.bind("normal", "SPC =", "format"); //        SPC = — format (the action)
weft.bind("normal", "SPC r", "eval"); //              SPC r — eval/run by language
weft.bind("normal", "SPC p", "project-recent"); //    SPC p — recent files
weft.bind("normal", "SPC m", "make-build"); //        SPC m — build
weft.bind("normal", "SPC M", "make-test"); //         SPC M — test
weft.bind("normal", "SPC q", "quit"); //              SPC q — quit

// Splits: use vim's own C-w chord (C-w s / v / w / o), plus vim goggles-style
// increment/decrement kept on the vim defaults. Insert-mode autopair:
weft.bind("insert", "parenleft", "pair-paren");
weft.bind("insert", "braceleft", "pair-brace");
weft.bind("insert", "bracketleft", "pair-bracket");
weft.bind("insert", "quotedbl", "pair-quote");
weft.bind("insert", "apostrophe", "pair-quote-single");
weft.bind("normal", "C-a", "increment-number");
weft.bind("normal", "C-x", "decrement-number");

// Completion — the at-caret popup (buffer-word here; add the lsp plugin for more).
weft.bind("insert", "C-SPC", "complete");
weft.bind("normal", "C-SPC", "complete");

weft.echo("weft: vim-minimal (flat SPC leader; SPC r eval, SPC p recents)");

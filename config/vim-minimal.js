// vim-minimal.js — a leaner, more traditional vim config. Load with:
//   weft --config config/vim-minimal.js
//
// Demonstrates: vim modal editing, a FLAT space-leader (no nested submenus, the
// which-key hint is a single flat list), the instant which-key (no idle delay),
// and reusing vim's own `window` chord (C-w) for splits. Compare with the
// default doom config (nested submenus) and helix.js (a different editor).

// A compact catalog — modal editing + the everyday tools.
[
  "edit", "complete", "palette", "motions", "textobjects", "operators", "vim",
  "comment", "autopair", "consult", "git", "grep", "make", "fmt", "buffers",
  "windows", "modes", "dired", "which_key",
].forEach((p) => weft.plugin(p));

// which-key: no delay here (show the flat leader map the moment you press SPC).
weft.set("editor", "which-key-delay-ms", "0");

// Flat leader (SPC). No submenus — every leader key is one action, so the
// which-key popup is one flat list (the simplest menu shape).
weft.bind("leader", "colon", "pick-commands"); // SPC : — run a command (M-x)
weft.bind("leader", "space", "find-file"); //     SPC SPC — find file
weft.bind("leader", "comma", "buf-pick"); //      SPC , — switch buffer
weft.bind("leader", "slash", "grep"); //          SPC / — search project
weft.bind("leader", "f", "find-file"); //         SPC f — find file
weft.bind("leader", "b", "buf-pick"); //          SPC b — switch buffer
weft.bind("leader", "s", "save"); //              SPC s — save
weft.bind("leader", "g", "git-status"); //        SPC g — git
weft.bind("leader", "e", "consult-line"); //      SPC e — jump to a line
weft.bind("leader", "d", "dired"); //             SPC d — dired
weft.bind("leader", "c", "comment-line"); //      SPC c — toggle comment
weft.bind("leader", "equal", "format-buffer"); // SPC = — format
weft.bind("leader", "m", "make-build"); //        SPC m — build
weft.bind("leader", "M", "make-test"); //         SPC M — test
weft.bind("leader", "q", "quit"); //              SPC q — quit

// Splits: use vim's own C-w chord (C-w s / v / w / o), plus vim goggles-style
// increment/decrement kept on the vim defaults. Insert-mode autopair:
weft.bind("insert", "parenleft", "pair-paren");
weft.bind("insert", "braceleft", "pair-brace");
weft.bind("insert", "bracketleft", "pair-bracket");
weft.bind("insert", "quotedbl", "pair-quote");
weft.bind("insert", "apostrophe", "pair-quote-single");
weft.bind("normal", "C-a", "increment-number");
weft.bind("normal", "C-x", "decrement-number");

weft.echo("weft: vim-minimal config loaded (flat SPC leader, vim binds)");

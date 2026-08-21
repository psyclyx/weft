// helix.js — Helix editing instead of vim. Load with:
//   weft --config config/helix.js
//
// Demonstrates: the helix plugin (selection-then-action, its OWN mode namespace
// helix-normal/helix-insert/…), a doom-style NESTED leader bound in helix's own
// helix-leader menu, the which-key popup CENTERED (a different placement), a
// longer idle delay, and a gruvbox-ish theme. This is the same leader machinery
// as the default config, just over a different editor and menu — proof that the
// editor and the keymap tree are both swappable data.

// Catalog + helix (NOT vim). helix composes the same motions/operators.
[
  "edit", "complete", "project", "palette", "motions", "textobjects", "operators", "helix",
  "comment", "autopair", "consult", "git", "grep", "make", "run", "fmt", "buffers",
  "windows", "modes", "dired", "which_key",
].forEach((p) => weft.plugin(p));
weft.use("defaults"); // shared pick/editing/menu-nav bindings

// which-key: centered popup, a longer hold before it appears.
weft.set("which_key", "placement", "center");
weft.set("which_key", "delay-ms", "350");
weft.bind("global", "F1", "which-key-now");

// A gruvbox-dark-ish theme (theme is data — a colorscheme is just a block).
weft.set("theme", "background", "#282828");
weft.set("theme", "foreground", "#ebdbb2");
weft.set("theme", "accent", "#b8bb26");
weft.set("theme", "cursor", "#fe8019");
weft.set("theme", "selection", "#504945");
weft.set("theme", "heading", "#fabd2f");
weft.set("theme", "status", "#a89984");

// Doom-style leader as key SEQUENCES in helix-normal — `space f f`, etc. A menu
// (`space f`) is just a prefix of longer sequences; which-key completes it. No
// menu modes: the same sequence machinery the default config uses, over helix.
weft.bind("helix-normal", "SPC :", "pick-commands"); // SPC : — M-x
weft.bind("helix-normal", "SPC SPC", "find-file"); //    SPC SPC — find file
weft.bind("helix-normal", "SPC ,", "buf-pick"); //     SPC , — switch buffer

// Actions: abstract intents resolved by CONTEXT. `eval` runs the buffer by
// language (a .zig buffer builds, else the language runner); `format` formats
// it. A language plugin can weft.provide another provider without touching this
// keymap or the helix editor.
weft.action("eval");
weft.provide("eval", {}, "run-line"); //             default: run the current line
weft.provide("eval", { lang: "zig" }, "make-build"); // .zig builds the project
weft.action("format");
weft.provide("format", {}, "format-buffer");

weft.bind("helix-normal", "SPC f f", "find-file");
weft.bind("helix-normal", "SPC f s", "save");
weft.bind("helix-normal", "SPC f r", "project-recent"); // recent files
weft.bind("helix-normal", "SPC f d", "dired");
weft.bind("helix-normal", "SPC b b", "buf-pick");
weft.bind("helix-normal", "SPC b d", "buffer-close");
weft.bind("helix-normal", "SPC b n", "buffer-next");
weft.bind("helix-normal", "SPC g g", "git-status");
weft.bind("helix-normal", "SPC g i", "git-init"); // start version control (git init)
weft.bind("helix-normal", "SPC g l", "git-log");
weft.bind("helix-normal", "SPC g b", "git-blame");
weft.bind("helix-normal", ".", "repeat-change"); // dot-repeat
weft.bind("helix-normal", "/", "consult-line"); // vim/helix `/` — search in buffer
weft.bind("helix-normal", "SPC s s", "consult-line");
weft.bind("helix-normal", "SPC s p", "grep");
weft.bind("helix-normal", "SPC s w", "grep-word");
weft.bind("helix-normal", "SPC c c", "comment-line");
weft.bind("helix-normal", "SPC c f", "format"); // the format action
weft.bind("helix-normal", "SPC c e", "eval"); //   SPC c e — eval/run by language
weft.bind("helix-normal", "SPC c b", "make-build");
weft.bind("helix-normal", "SPC c t", "make-test");
weft.bind("helix-normal", "SPC o d", "dired");
weft.bind("helix-normal", "SPC o c", "console-open");
weft.bind("helix-normal", "SPC w v", "win-vsplit");
weft.bind("helix-normal", "SPC w s", "win-split");
weft.bind("helix-normal", "SPC w w", "win-focus");
weft.bind("helix-normal", "SPC q q", "quit");

// Autopair (in helix's insert mode).
weft.bind("helix-insert", "parenleft", "pair-paren");
weft.bind("helix-insert", "braceleft", "pair-brace");
weft.bind("helix-insert", "bracketleft", "pair-bracket");
weft.bind("helix-insert", "quotedbl", "pair-quote");
weft.bind("helix-insert", "parenright", "pair-close-paren"); // type-over
weft.bind("helix-insert", "braceright", "pair-close-brace");
weft.bind("helix-insert", "bracketright", "pair-close-bracket");

// Completion — the at-caret popup (buffer-word + LSP race + merge-rank).
weft.bind("helix-insert", "C-SPC", "complete");
weft.bind("helix-normal", "C-SPC", "complete");

weft.echo("weft: helix config (centered which-key; SPC c e eval, SPC f r recents)");

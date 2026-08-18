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
  "edit", "complete", "palette", "motions", "textobjects", "operators", "helix",
  "comment", "autopair", "consult", "git", "grep", "make", "fmt", "buffers",
  "windows", "modes", "dired", "which_key",
].forEach((p) => weft.plugin(p));

// which-key: centered popup, a longer hold before it appears.
weft.set("which_key", "placement", "center");
weft.set("editor", "which-key-delay-ms", "350");
weft.bind("helix-normal", "F1", "which-key-now");

// A gruvbox-dark-ish theme (theme is data — a colorscheme is just a block).
weft.set("theme", "background", "#282828");
weft.set("theme", "foreground", "#ebdbb2");
weft.set("theme", "accent", "#b8bb26");
weft.set("theme", "cursor", "#fe8019");
weft.set("theme", "selection", "#504945");
weft.set("theme", "heading", "#fabd2f");
weft.set("theme", "status", "#a89984");

// Doom-style nested leader, bound in helix's own leader menu (SPC in
// helix-normal). Submenu modes are shared with any config.
[
  "leader-file", "leader-buffer", "leader-git", "leader-search",
  "leader-code", "leader-open", "leader-window", "leader-quit",
].forEach((m) => weft.menu(m));

weft.bind("helix-leader", "colon", "pick-commands"); // SPC : — M-x
weft.bind("helix-leader", "space", "find-file"); //     SPC SPC — find file
weft.bind("helix-leader", "comma", "buf-pick"); //      SPC , — switch buffer
weft.bind("helix-leader", "f", "leader-file");
weft.bind("helix-leader", "b", "leader-buffer");
weft.bind("helix-leader", "g", "leader-git");
weft.bind("helix-leader", "s", "leader-search");
weft.bind("helix-leader", "c", "leader-code");
weft.bind("helix-leader", "o", "leader-open");
weft.bind("helix-leader", "w", "leader-window");
weft.bind("helix-leader", "q", "leader-quit");

weft.bind("leader-file", "f", "find-file");
weft.bind("leader-file", "s", "save");
weft.bind("leader-file", "d", "dired");
weft.bind("leader-buffer", "b", "buf-pick");
weft.bind("leader-buffer", "d", "buffer-close");
weft.bind("leader-buffer", "n", "buffer-next");
weft.bind("leader-git", "g", "git-status");
weft.bind("leader-git", "l", "git-log");
weft.bind("leader-git", "b", "git-blame");
weft.bind("leader-search", "s", "consult-line");
weft.bind("leader-search", "p", "grep");
weft.bind("leader-search", "w", "grep-word");
weft.bind("leader-code", "c", "comment-line");
weft.bind("leader-code", "f", "format-buffer");
weft.bind("leader-code", "b", "make-build");
weft.bind("leader-code", "t", "make-test");
weft.bind("leader-open", "d", "dired");
weft.bind("leader-open", "c", "console-open");
weft.bind("leader-window", "v", "win-vsplit");
weft.bind("leader-window", "s", "win-split");
weft.bind("leader-window", "w", "win-focus");
weft.bind("leader-quit", "q", "quit");

// Autopair (in helix's insert mode).
weft.bind("helix-insert", "parenleft", "pair-paren");
weft.bind("helix-insert", "braceleft", "pair-brace");
weft.bind("helix-insert", "bracketleft", "pair-bracket");
weft.bind("helix-insert", "quotedbl", "pair-quote");

weft.echo("weft: helix config loaded (helix binds, centered which-key)");

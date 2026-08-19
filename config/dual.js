// dual.js — vim AND helix loaded at once, switchable per buffer. Load with:
//   weft --config config/dual.js
//
// Demonstrates: two modal editors coexisting via per-buffer keymap mode. Each
// buffer is independently in `normal` (vim) or `helix-normal` (helix); `\`
// toggles the current buffer between them. The SAME doom leader tree is bound in
// both editors' leader menus, so the leader UX is identical whichever engine a
// buffer uses — the editor is data, the leader is data, and they compose.

// Catalog + BOTH editors. helix loads first, vim last, so vim's init runs last
// and the editor starts in vim's `normal`.
[
  "edit", "complete", "palette", "motions", "textobjects", "operators",
  "helix", "vim",
  "comment", "autopair", "consult", "git", "grep", "make", "fmt", "buffers",
  "windows", "modes", "dired", "which_key",
].forEach((p) => weft.plugin(p));

// `\` switches the current buffer's editor (mode is per-buffer, so buffers can
// differ). vim-normal / helix-mode are each editor's "enter my normal" command.
weft.bind("normal", "backslash", "helix-mode"); // vim  -> helix
weft.bind("helix-normal", "backslash", "vim-normal"); // helix -> vim

weft.set("editor", "which-key-delay-ms", "200");
weft.bind("global", "F1", "which-key-now");

// One doom leader tree, applied to BOTH editors' leader menus.
[
  "leader-file", "leader-buffer", "leader-git", "leader-search",
  "leader-code", "leader-window", "leader-quit",
].forEach((m) => weft.menu(m));

function leaderMap(leader) {
  weft.bind(leader, "colon", "pick-commands");
  weft.bind(leader, "space", "find-file");
  weft.bind(leader, "comma", "buf-pick");
  weft.bind(leader, "f", "leader-file");
  weft.bind(leader, "b", "leader-buffer");
  weft.bind(leader, "g", "leader-git");
  weft.bind(leader, "s", "leader-search");
  weft.bind(leader, "c", "leader-code");
  weft.bind(leader, "w", "leader-window");
  weft.bind(leader, "q", "leader-quit");
}
leaderMap("leader"); //        vim's SPC
leaderMap("helix-leader"); //  helix's SPC

// Submenu contents (editor-agnostic — bound once).
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
weft.bind("leader-window", "v", "win-vsplit");
weft.bind("leader-window", "s", "win-split");
weft.bind("leader-window", "w", "win-focus");
weft.bind("leader-quit", "q", "quit");

weft.echo("weft: dual config — `\\` toggles vim/helix per buffer");

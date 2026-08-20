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
  "edit", "complete", "project", "palette", "motions", "textobjects", "operators",
  "helix", "vim",
  "comment", "indent", "autopair", "consult", "git", "grep", "make", "run", "fmt", "buffers",
  "windows", "modes", "dired", "which_key",
].forEach((p) => weft.plugin(p));
weft.use("defaults"); // shared pick/editing/menu-nav bindings

// `\` switches the current buffer's editor (mode is per-buffer, so buffers can
// differ). vim-normal / helix-mode are each editor's "enter my normal" command.
weft.bind("normal", "backslash", "helix-mode"); // vim  -> helix
weft.bind("helix-normal", "backslash", "vim-normal"); // helix -> vim

weft.set("editor", "which-key-delay-ms", "200");
weft.bind("global", "F1", "which-key-now");

// Actions: abstract intents resolved by CONTEXT, shared by both editors. `eval`
// runs the buffer by language (a .zig buffer builds, else the language runner);
// `format` formats it. Declared once — a language plugin can weft.provide
// another provider without touching either editor's keymap.
weft.action("eval");
weft.provide("eval", {}, "run-line"); //             default: run the current line
weft.provide("eval", { lang: "zig" }, "make-build"); // .zig builds the project
weft.action("format");
weft.provide("format", {}, "format-buffer");

// One doom leader tree as key SEQUENCES, applied to BOTH editors' base modes. A
// menu (`space f`) is just a prefix of longer sequences; which-key completes it.
// Same tree, bound in `normal` (vim) and `helix-normal` (helix) — the editor is
// data, the leader is data, and they compose with no menu modes at all.
function leaderMap(m) {
  weft.bind(m, "SPC :", "pick-commands"); // SPC : — M-x
  weft.bind(m, "SPC SPC", "find-file"); //     SPC SPC — find file
  weft.bind(m, "SPC ,", "buf-pick"); //      SPC , — switch buffer
  weft.bind(m, "SPC f f", "find-file");
  weft.bind(m, "SPC f s", "save");
  weft.bind(m, "SPC f r", "project-recent"); // recent files
  weft.bind(m, "SPC f d", "dired");
  weft.bind(m, "SPC b b", "buf-pick");
  weft.bind(m, "SPC b d", "buffer-close");
  weft.bind(m, "SPC b n", "buffer-next");
  weft.bind(m, "SPC g g", "git-status");
  weft.bind(m, "SPC g i", "git-init"); // start version control (git init)
  weft.bind(m, "SPC g l", "git-log");
  weft.bind(m, "SPC g b", "git-blame");
  weft.bind(m, ".", "repeat-change"); // vim dot-repeat (composes w/ all plugins)
  weft.bind(m, "/", "consult-line"); // vim `/` — search in this buffer
  weft.bind(m, "SPC s s", "consult-line");
  weft.bind(m, "SPC s p", "grep");
  weft.bind(m, "SPC s w", "grep-word");
  weft.bind(m, "SPC c c", "comment-line");
  weft.bind(m, "SPC c f", "format"); // the format action
  weft.bind(m, "SPC c e", "eval"); //  SPC c e — eval/run by language
  weft.bind(m, "SPC c b", "make-build");
  weft.bind(m, "SPC c t", "make-test");
  weft.bind(m, "SPC w v", "win-vsplit");
  weft.bind(m, "SPC w s", "win-split");
  weft.bind(m, "SPC w w", "win-focus");
  weft.bind(m, "SPC q q", "quit");
}
leaderMap("normal"); //        vim's SPC
leaderMap("helix-normal"); //  helix's SPC

weft.echo("weft: dual config — `\\` toggles vim/helix; SPC c e eval, SPC f r recents");

// helix.js — the same editor under Helix's grammar instead of vim's. Load with:
//   weft --config config/helix.js
//
// What it tests: whether everything config.js shows still holds when the
// input grammar changes underneath it — and whether the editor holds up
// under a grammar built on MANY selections. The plugin set and the
// structured-view group (SPC v, from config/semantic.js) are the reference
// config's; the keymap is Helix's own, and every mode it binds in is a name
// the helix plugin DECLARES:
//
//   helix-normal      where a buffer rests (text and listings alike)
//   helix-select      `v`: the same keys, with motions that extend
//   helix-insert      where text is typed (at every caret at once)
//   helix-source      helix-normal's layer in a file-backed document
//   helix-structural  helix-normal's layer in a listing or a focused scene
//
// Selection-first, on every selection: `w` selects the word ahead, `x` the
// line, `C` copies the selection onto the next line, `%` selects everything;
// `d`/`c`/`y`/`p`/`R`/`r`/`~`/`J`/`>` act on every selection as one undo unit,
// and a yank of N selections pastes back one value each. Every key helix
// shares with a structured view — j/k, y/p/d, Return, `-`, Tab, u/U — binds
// the standard intention first, so the same key does the listing's thing in
// *files* and the text thing in a file. src/e2e/config_test.zig boots this
// file and fails the build on a key that names nothing.
//
// The config plane itself is documented at the top of config.js.

// ── The plugins ──────────────────────────────────────────────────────
// config.js's set, with `helix` where it loads `vim`. helix composes the same
// shared textobjects/ts/surround vim does.
[
  "edit", "complete", "project", "dashboard", "structural", "region", "shell",
  "palette", "motions", "textobjects", "operators", "surround", "helix", "ts",
].forEach((p) => weft.plugin(p));
weft.set("languages", "query-root", "assets");
weft.plugin("languages.js"); // parser packages + explicit query paths
[
  "comment", "indent", "whitespace", "numbers", "autopair", "consult", "git",
  "grep", "run", "make", "notes", "fmt", "buffers", "modes",
  "snippets", "direnv", "llm", "console", "repl", "net", "http", "which_key",
  "files", "lsp", "debug", "marginalia", "linenumbers",
  // The bottom panel and what shows in it (config/panel.js), and the caret's
  // symbol trail on the status line. No keys: the palette reaches
  // `problems`, `terminal` and `panel.toggle`.
  "panel", "problems", "terminal", "breadcrumbs",
  // What a context offers, as mouse-3's menu (the keys below).
  "offers",
].forEach((p) => weft.plugin(p));

// Grants, exactly as config.js reasons about them: the file browser goes
// wherever you point it; the two `.js` plugins get what they declare and no
// more.
weft.grant("files", "fs_read", { root: "/" });
weft.grant("files", "fs_write", { root: "/" });
// The system clipboard (`SPC y` / `SPC p`): config-only, like every read of
// what you copied elsewhere.
weft.grant("helix", "clipboard");
weft.grant("terminal", "clipboard"); // C-S-v / S-Insert paste into the shell
weft.grant("dap", "proc");
weft.plugin("dap.js");
weft.grant("acp", "proc");
weft.grant("acp", "fs_read");
weft.grant("acp", "fs_write");
weft.plugin("acp.js");

// ── Fragments ────────────────────────────────────────────────────────
weft.use("defaults"); // picker and which-key navigation keys
weft.use("semantic"); // SPC v, bound into helix-structural (and vim's layer)
weft.use("panel");    // a hidden bottom panel the problems list and terminal take
weft.use("undo");     // the undo history as a tree, docked right when shown (SPC u)
// weft.use("menus"); weft.use("menubar"); // File, Edit, … with helix's keys beside each row (F10, Alt+letter)

// ── Values ───────────────────────────────────────────────────────────
weft.set("lsp", "zig", "zls");
// which-key: centered popup, a longer hold before it appears.
weft.set("which_key", "placement", "center");
weft.set("which_key", "delay-ms", "350");
weft.set("editor", "flash-ms", "150");
weft.set("editor", "flash-undo", "on"); // undo/redo flash what they put back
weft.set("linenumbers", "style", "relative");
weft.set("dashboard", "sections", [
  "start\tStart\t\t\t0",
  "files\tRecent files\tproject.recent\tfile.open\t5",
  "projects\tProjects\tproject.recent-roots\tfile.open\t4",
]);
weft.set("dashboard", "items", [
  "start\tOpen file\tfiles.find",
  "start\tNew buffer\tbuffer.scratch",
]);
weft.set("palette", "arguments", "ask");
weft.set("palette", "signature", "on");

// A gruvbox-dark-ish theme (theme is data — a colorscheme is just a block).
weft.set("palette", "background", "#282828");
weft.set("palette", "foreground", "#ebdbb2");
weft.set("palette", "accent", "#b8bb26");
weft.set("palette", "cursor", "#fe8019");
weft.set("palette", "selection", "#504945");
weft.set("palette", "heading", "#fabd2f");
weft.set("palette", "status", "#a89984");
// How chrome looks: clean, cell-aligned text. `text-icons` adds small icons,
// `widget` draws pills and real tabs; `theme.set-chrome widget` (or
// `theme.cycle-chrome`) tries one live.
weft.set("theme", "chrome", "text");

// ── Actions: abstract intents resolved by CONTEXT ────────────────────
weft.action("plugin.code.run");
weft.provide("plugin.code.run", {}, "run.line"); //             default: run the current line
weft.provide("plugin.code.run", { lang: "zig" }, "make.build"); // .zig builds the project
weft.provide("plugin.code.run", { lang: "py" }, "modes.run");
weft.action("plugin.code.format");
weft.provide("plugin.code.format", {}, "fmt.format-buffer");

// ── Keys ─────────────────────────────────────────────────────────────
weft.bind("global", "F1", "which-key.show");
// The context menu, as in every config (doc/chrome.md §2.2): the pointer's
// secondary button presents what the thing under it offers — over text,
// Cut, Copy and Paste are helix's own d, y and p — and S-F10 or the Menu key
// the focused context's, at the caret.
weft.bind("global", "mouse-3", "offers.menu");
weft.bind("global", "S-F10", "offers.menu-at-caret");
weft.bind("global", "Menu", "offers.menu-at-caret");

// The helix plugin binds Helix's own keymap: motions that select, `v` select
// mode, the verbs, and the minor modes `g` `m` `z`/`Z` `[` `]` and `space`,
// all as key SEQUENCES in helix-normal. This config names the groups and
// lays weft's own tools into the space-mode keys Helix leaves free.
weft.group("helix-normal", "g", "Goto");
weft.group("helix-normal", "m", "Match & surround");
weft.group("helix-normal", "m i", "Select inside");
weft.group("helix-normal", "m a", "Select around");
weft.group("helix-normal", "z", "View");
weft.group("helix-normal", "[", "Previous");
weft.group("helix-normal", "]", "Next");
weft.group("helix-normal", "C-w", "Window");

// Space mode is Helix's: f/F files, b buffers, e explorer, s symbols, k hover,
// a code actions, r rename, h references, d this file's diagnostics, c
// comment, g changed files, j the jumplist, `/` search, `?` commands,
// y/p/P/R the system clipboard, w windows. Not yet: S (workspace symbols) and
// D (workspace diagnostics) — lsp knows one file at a time — and ' (last
// picker: no door reopens one). weft's own groups sit on the keys Helix
// leaves free.
weft.group("helix-normal", "SPC", "Space");
weft.group("helix-normal", "SPC w", "Window");
weft.group("helix-normal", "SPC B", "Buffers");
weft.group("helix-normal", "SPC O", "Open & save");
weft.group("helix-normal", "SPC V", "Version control");
weft.group("helix-normal", "SPC l", "Project");
weft.group("helix-source", "SPC i", "Inspect code");
weft.group("helix-source", "SPC m", "Make & run");
weft.group("helix-normal", "SPC o", "External tools");
weft.group("helix-normal", "SPC A", "Coding agents");
weft.group("helix-normal", "SPC G", "Debug session");
weft.group("helix-normal", "SPC n", "Notes & embeds");
weft.group("helix-normal", "SPC x", "Share & connect");
weft.group("helix-normal", "SPC q", "Quit editor");
weft.group("helix-normal", "SPC H", "Help & permissions");
weft.group("helix-normal", "SPC t", "Text toggles");

weft.bind("helix-normal", "SPC SPC", "files.find");
weft.bind("helix-normal", "SPC :", "palette.open");
weft.bind("helix-normal", "SPC ,", "buffer.pick");
weft.bind("helix-normal", "SPC u", "undo-tree.open"); // the undo history as a tree (config/undo.js)

// SPC O — `O s` asks the focused entry for the persistence intention first:
// in a *git-commit* draft that commits, in a note it saves.
weft.bind("helix-normal", "SPC O f", "files.find");
weft.bind("helix-normal", "SPC O s", ["std.persistence.save", "file.save"]);
weft.bind("helix-normal", "SPC O S", "file.save-as");
weft.bind("helix-normal", "SPC O r", "project.open-recent");
weft.bind("helix-normal", "SPC O d", "files.browse");

weft.bind("helix-normal", "SPC B d", "buffer.close");
weft.bind("helix-normal", "SPC B D", "buffer.close-force");
weft.bind("helix-normal", "SPC B n", "buffer.next");
weft.bind("helix-normal", "SPC B p", "buffer.prev");
weft.bind("helix-normal", "SPC B N", "buffer.scratch");

weft.bind("helix-normal", "SPC V g", "git.status");
weft.bind("helix-normal", "SPC V i", "git.init");
weft.bind("helix-normal", "SPC V l", "git.log");
weft.bind("helix-normal", "SPC V d", "git.diff");
weft.bind("helix-normal", "SPC V D", "git.diff-staged");
weft.bind("helix-source", "SPC V b", "git.blame");

weft.bind("helix-normal", ".", "edit.repeat");
// `/ ? n N *` are helix's own search (the plugin binds them); the pattern
// lands in the `/` register vim reads too. `C-o`/`C-i` walk the jumplist, a
// focused view's own history first — the plugin binds those as well.

weft.bind("helix-normal", "SPC l p", "project.open-recent");
weft.bind("helix-normal", "SPC l f", "files.find");
weft.bind("helix-normal", "SPC l R", "project.show-root");
weft.bind("helix-normal", "SPC l /", "grep.search");
weft.bind("helix-normal", "SPC l w", "grep.search-word");
weft.bind("helix-source", "SPC l i", "consult.imenu");

// SPC i / SPC m — code, in documents only.
weft.bind("helix-source", "SPC i f", "plugin.code.format");
weft.bind("helix-source", "SPC i F", "lsp.format");
weft.bind("helix-source", "SPC i k", "lsp.signature-help");
weft.bind("helix-source", "SPC i i", "lsp.toggle-inlay-hints");
weft.bind("helix-source", "SPC i n", "ts.select-node");
weft.bind("helix-source", "SPC m b", "make.build");
weft.bind("helix-source", "SPC m t", "make.test");
weft.bind("helix-source", "SPC m r", "modes.run");
weft.bind("helix-source", "SPC m x", "run.line");
weft.bind("helix-source", "SPC m e", "plugin.code.run");

// Completion — the at-caret popup (buffer-word + LSP race + merge-rank).
weft.bind("helix-insert", "C-SPC", "complete.show");
weft.bind("helix-normal", "C-SPC", "complete.show");

weft.bind("helix-normal", "SPC o e", "direnv.status");
weft.bind("helix-normal", "SPC o r", "repl.start");
weft.bind("helix-normal", "SPC o R", "repl.send-line");
weft.bind("helix-normal", "SPC o q", "repl.quit");
weft.bind("helix-normal", "SPC o c", "console.open");
weft.bind("helix-normal", "SPC o C", "console.send");
weft.bind("helix-normal", "SPC o a", "llm.ask-line");
weft.bind("helix-normal", "SPC o h", "http.get");

weft.bind("helix-normal", "SPC A a", "acp.start");
weft.bind("helix-normal", "SPC A s", "acp.send");
weft.bind("helix-normal", "SPC A f", "acp.focus");

weft.bind("helix-source", "SPC G b", "debug.toggle-breakpoint");
weft.bind("helix-normal", "SPC G c", "debug.clear-breakpoints");
weft.bind("helix-normal", "SPC G l", "debug.list-breakpoints");
weft.bind("helix-normal", "SPC G d", "dap.start");
weft.bind("helix-normal", "SPC G r", "dap.continue");
weft.bind("helix-normal", "SPC G n", "dap.step-over");
weft.bind("helix-normal", "SPC G i", "dap.step-into");
weft.bind("helix-normal", "SPC G o", "dap.step-out");
weft.bind("helix-normal", "SPC G q", "dap.stop");
weft.bind("helix-normal", "F5", "dap.continue");
weft.bind("helix-source", "F9", "debug.toggle-breakpoint");
weft.bind("helix-normal", "F10", "dap.step-over");
weft.bind("helix-normal", "F11", "dap.step-into");

weft.bind("helix-normal", "SPC n n", "notes.open");
weft.bind("helix-normal", "SPC n c", "notes.capture");
weft.bind("helix-normal", "SPC n h", "notes.capture-here");
weft.bind("helix-normal", "SPC n e", "notes.show-embeds");
weft.bind("helix-normal", "SPC n E", "notes.hide-embeds");

weft.bind("helix-normal", "SPC x s", "collab.share");
weft.bind("helix-normal", "SPC x o", "collab.open-shared");
weft.bind("helix-normal", "SPC x f", "collab.peer-files");
weft.bind("helix-normal", "SPC x p", "collab.peers");
weft.bind("helix-normal", "SPC x l", "collab.listen");
weft.bind("helix-normal", "SPC x c", "collab.connect");
weft.bind("helix-normal", "SPC x x", "collab.disconnect");

// Windows: helix's `C-w` window mode, and the same keys under `SPC w` —
// both straight to the core window-layout commands.
[
  ["v", "window.split-right"], ["s", "window.split-below"], ["w", "window.focus-next"],
  ["C-w", "window.focus-next"], ["q", "window.close"], ["o", "window.close"],
  ["h", "window.focus-left"], ["j", "window.focus-down"],
  ["k", "window.focus-up"], ["l", "window.focus-right"],
  ["H", "window.move-left"], ["J", "window.move-down"],
  ["K", "window.move-up"], ["L", "window.move-right"],
].forEach((b) => {
  weft.bind("helix-normal", "C-w " + b[0], b[1]);
  weft.bind("helix-normal", "SPC w " + b[0], b[1]);
});

weft.bind("helix-normal", "SPC q q", "app.quit");
weft.bind("helix-normal", "SPC q Q", "app.quit-force");
weft.bind("helix-normal", "SPC H h", "palette.open");
weft.bind("helix-normal", "SPC H g", "grants.show");
weft.bind("helix-normal", "SPC t w", "whitespace.trim-buffer");

// Numbers: helix's own increment/decrement keys.
weft.bind("helix-normal", "C-a", "numbers.increment");
weft.bind("helix-normal", "C-x", "numbers.decrement");

// Autopair (in helix's insert mode).
weft.bind("helix-insert", "parenleft", "autopair.open-paren");
weft.bind("helix-insert", "braceleft", "autopair.open-brace");
weft.bind("helix-insert", "bracketleft", "autopair.open-bracket");
weft.bind("helix-insert", "quotedbl", "autopair.quote-double");
weft.bind("helix-insert", "apostrophe", "autopair.quote-single");
weft.bind("helix-insert", "parenright", "autopair.close-paren");
weft.bind("helix-insert", "braceright", "autopair.close-brace");
weft.bind("helix-insert", "bracketright", "autopair.close-bracket");

weft.echo("weft: helix.js loaded");

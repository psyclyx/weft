// helix.js — the same editor under Helix's grammar instead of vim's. Load with:
//   weft --config config/helix.js
//
// What it tests: whether everything config.js shows still holds when the
// input grammar changes underneath it. The plugin set, the leader tree and
// the structured-view group (SPC v, from config/semantic.js) are the
// reference config's; only the modes they bind in differ, and every one of
// those is a name the helix plugin DECLARES:
//
//   helix-normal      where a buffer rests (text and listings alike)
//   helix-insert      where text is typed
//   helix-source      helix-normal's layer in a file-backed document
//   helix-structural  helix-normal's layer in a listing or a focused scene
//
// Selection-first, on the one selection core holds today: `x` selects the
// line, `d`/`c`/`y` act on the selection (or the character under the
// cursor), `p`/`P` place after/before it, `;` collapses it. `d` with nothing
// selected waits for a motion (`dw`, `dd`). Every key helix shares with a
// structured view — j/k, y/p/d, Return, `-`, Tab, u/U — binds the standard
// intention first, so the same key does the listing's thing in *files* and
// the text thing in a file. src/e2e/config_test.zig boots this file and
// fails the build on a key that names nothing.
//
// The config plane itself is documented at the top of config.js.

// ── The plugins ──────────────────────────────────────────────────────
// config.js's set, with `helix` where it loads `vim`. helix composes the same
// shared motions/textobjects/operators vim does.
[
  "edit", "complete", "project", "dashboard", "structural", "region", "shell",
  "palette", "motions", "textobjects", "operators", "helix", "ts",
].forEach((p) => weft.plugin(p));
weft.set("languages", "query-root", "assets");
weft.plugin("languages.js"); // parser packages + explicit query paths
[
  "comment", "indent", "whitespace", "numbers", "autopair", "consult", "git",
  "grep", "run", "make", "notes", "fmt", "buffers", "windows", "modes",
  "snippets", "direnv", "llm", "console", "repl", "net", "http", "which_key",
  "files", "lsp", "debug", "marginalia", "linenumbers",
].forEach((p) => weft.plugin(p));

// Grants, exactly as config.js reasons about them: the file browser goes
// wherever you point it; the two `.js` plugins get what they declare and no
// more.
weft.grant("files", "fs_read", { root: "/" });
weft.grant("files", "fs_write", { root: "/" });
weft.grant("dap", "proc");
weft.plugin("dap.js");
weft.grant("acp", "proc");
weft.grant("acp", "fs_read");
weft.grant("acp", "fs_write");
weft.plugin("acp.js");

// ── Fragments ────────────────────────────────────────────────────────
weft.use("defaults"); // picker and which-key navigation keys
weft.use("semantic"); // SPC v, bound into helix-structural (and vim's layer)

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
  "files\tRecent files\tproject-recent\topen\t5",
  "projects\tProjects\tproject-recent-roots\topen\t4",
]);
weft.set("dashboard", "items", [
  "start\tOpen file\tdashboard-open-file",
  "start\tNew buffer\tdashboard-new",
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

// ── Actions: abstract intents resolved by CONTEXT ────────────────────
weft.action("eval");
weft.provide("eval", {}, "run-line"); //             default: run the current line
weft.provide("eval", { lang: "zig" }, "make-build"); // .zig builds the project
weft.provide("eval", { lang: "py" }, "lang-run");
weft.action("format");
weft.provide("format", {}, "format-buffer");

// ── Keys ─────────────────────────────────────────────────────────────
weft.bind("global", "F1", "which-key-now");

// The leader is the reference config's doom-style tree, as SEQUENCES in
// helix-normal. (Helix's own space-mode layout is a later phase.)
weft.group("helix-normal", "SPC", "Workspace");
weft.group("helix-normal", "SPC f", "Find & save");
weft.group("helix-normal", "SPC b", "Switch & close buffers");
weft.group("helix-normal", "SPC g", "Version control");
weft.group("helix-normal", "SPC s", "Search & jump");
weft.group("helix-normal", "SPC p", "Project navigation");
weft.group("helix-source", "SPC c", "Edit & inspect code");
weft.group("helix-normal", "SPC o", "External tools");
weft.group("helix-normal", "SPC a", "Coding agents");
weft.group("helix-normal", "SPC d", "Debug session");
weft.group("helix-normal", "SPC n", "Notes & embeds");
weft.group("helix-normal", "SPC C", "Share & connect");
weft.group("helix-normal", "SPC w", "Split & focus windows");
weft.group("helix-normal", "SPC q", "Quit editor");
weft.group("helix-normal", "SPC h", "Help & permissions");
weft.group("helix-normal", "SPC t", "Text toggles");
weft.group("helix-normal", "g", "Goto");
weft.group("helix-normal", "C-w", "Window");

weft.bind("helix-normal", "SPC SPC", "find-file");
weft.bind("helix-normal", "SPC :", "pick-commands");
weft.bind("helix-normal", "SPC ,", "buf-pick");

// SPC f — `f s` asks the focused entry for the persistence intention first:
// in a *git-commit* draft that commits, in a note it saves.
weft.bind("helix-normal", "SPC f f", "find-file");
weft.bind("helix-normal", "SPC f s", ["std.persistence.save", "save"]);
weft.bind("helix-normal", "SPC f S", "save-as");
weft.bind("helix-normal", "SPC f r", "project-recent");
weft.bind("helix-normal", "SPC f d", "files");

weft.bind("helix-normal", "SPC b b", "buf-pick");
weft.bind("helix-normal", "SPC b d", "close");
weft.bind("helix-normal", "SPC b D", "buffer-close-force");
weft.bind("helix-normal", "SPC b n", "buffer-next");
weft.bind("helix-normal", "SPC b N", "buf-scratch");

weft.bind("helix-normal", "SPC g g", "git-status");
weft.bind("helix-normal", "SPC g i", "git-init");
weft.bind("helix-normal", "SPC g l", "git-log");
weft.bind("helix-normal", "SPC g d", "git-diff");
weft.bind("helix-normal", "SPC g D", "git-diff-staged");
weft.bind("helix-source", "SPC g b", "git-blame");

weft.bind("helix-normal", ".", "repeat-change");
weft.bind("helix-normal", "/", "consult-line");
// `C-o` — back where you came from (helix's jump-backward key). A focused
// view that knows its own history answers the intention; else buffer-back.
weft.bind("helix-normal", "C-o", ["std.navigation.back", "navigate-back"]);

weft.bind("helix-normal", "SPC s s", "consult-line");
weft.bind("helix-source", "SPC s i", "consult-imenu");
weft.bind("helix-normal", "SPC s p", "grep");
weft.bind("helix-normal", "SPC s w", "grep-word");

weft.bind("helix-normal", "SPC p p", "project-recent");
weft.bind("helix-normal", "SPC p f", "find-file");
weft.bind("helix-normal", "SPC p R", "project-root");
weft.bind("helix-normal", "SPC p /", "grep");

// SPC c — code, in documents only. Helix's own goto keys too: gd/gr, ]d/[d.
weft.bind("helix-source", "SPC c c", "comment-line");
weft.bind("helix-source", "SPC c f", "format");
weft.bind("helix-source", "SPC c d", "goto-definition");
weft.bind("helix-source", "SPC c h", "hover");
weft.bind("helix-source", "SPC c s", "symbols");
weft.bind("helix-source", "SPC c F", "lsp-format");
weft.bind("helix-source", "SPC c R", "references");
weft.bind("helix-source", "SPC c k", "signature-help");
weft.bind("helix-source", "SPC c i", "inlay-hints");
weft.bind("helix-source", "SPC c a", "code-actions");
weft.bind("helix-source", "SPC c e", "ts-expand-selection");
weft.bind("helix-source", "SPC c n", "ts-select-node");
weft.bind("helix-source", "SPC c b", "make-build");
weft.bind("helix-source", "SPC c t", "make-test");
weft.bind("helix-source", "SPC c r", "lang-run");
weft.bind("helix-source", "SPC c x", "run-line");
weft.bind("helix-source", "SPC e", "eval");
weft.bind("helix-source", "g d", "goto-definition");
weft.bind("helix-source", "g r", "references");
weft.bind("helix-source", "] d", "next-diagnostic");
weft.bind("helix-source", "[ d", "prev-diagnostic");

// Completion — the at-caret popup (buffer-word + LSP race + merge-rank).
weft.bind("helix-insert", "C-SPC", "complete");
weft.bind("helix-normal", "C-SPC", "complete");

weft.bind("helix-normal", "SPC o d", "files");
weft.bind("helix-normal", "SPC o e", "direnv-status");
weft.bind("helix-normal", "SPC o r", "repl-start");
weft.bind("helix-normal", "SPC o R", "repl-send-line");
weft.bind("helix-normal", "SPC o q", "repl-quit");
weft.bind("helix-normal", "SPC o c", "console-open");
weft.bind("helix-normal", "SPC o C", "console-send");
weft.bind("helix-normal", "SPC o a", "llm-ask-line");
weft.bind("helix-normal", "SPC o h", "http-get");

weft.bind("helix-normal", "SPC a a", "agent-start");
weft.bind("helix-normal", "SPC a s", "agent-send");
weft.bind("helix-normal", "SPC a f", "agent-focus");

weft.bind("helix-source", "SPC d b", "debug-toggle-breakpoint");
weft.bind("helix-normal", "SPC d c", "debug-clear-breakpoints");
weft.bind("helix-normal", "SPC d l", "debug-list-breakpoints");
weft.bind("helix-normal", "SPC d d", "debug-start");
weft.bind("helix-normal", "SPC d r", "debug-continue");
weft.bind("helix-normal", "SPC d n", "debug-step-over");
weft.bind("helix-normal", "SPC d i", "debug-step-into");
weft.bind("helix-normal", "SPC d o", "debug-step-out");
weft.bind("helix-normal", "SPC d q", "debug-stop");
weft.bind("helix-normal", "F5", "debug-continue");
weft.bind("helix-source", "F9", "debug-toggle-breakpoint");
weft.bind("helix-normal", "F10", "debug-step-over");
weft.bind("helix-normal", "F11", "debug-step-into");

weft.bind("helix-normal", "SPC n n", "notes-open");
weft.bind("helix-normal", "SPC n c", "notes-capture");
weft.bind("helix-normal", "SPC n h", "notes-capture-here");
weft.bind("helix-normal", "SPC n e", "notes-embeds");
weft.bind("helix-normal", "SPC n E", "notes-embeds-off");

weft.bind("helix-normal", "SPC C s", "share");
weft.bind("helix-normal", "SPC C o", "open-shared");
weft.bind("helix-normal", "SPC C f", "peer-files");
weft.bind("helix-normal", "SPC C p", "peers");
weft.bind("helix-normal", "SPC C l", "listen");
weft.bind("helix-normal", "SPC C c", "connect");
weft.bind("helix-normal", "SPC C x", "disconnect");

// Windows: the doom leaves, and helix's own `C-w` window mode — both straight
// to the core window-layout commands.
weft.bind("helix-normal", "SPC w v", "win-vsplit");
weft.bind("helix-normal", "SPC w s", "win-split");
weft.bind("helix-normal", "SPC w w", "win-focus");
weft.bind("helix-normal", "SPC w c", "win-center");
weft.bind("helix-normal", "SPC w o", "win-close");
weft.bind("helix-normal", "SPC w q", "window-close");
[
  ["h", "window-focus-left"], ["j", "window-focus-down"],
  ["k", "window-focus-up"], ["l", "window-focus-right"],
  ["H", "window-move-left"], ["J", "window-move-down"],
  ["K", "window-move-up"], ["L", "window-move-right"],
].forEach((b) => weft.bind("helix-normal", "SPC w " + b[0], b[1]));
[
  ["v", "window-vsplit"], ["s", "window-split"], ["w", "focus-other"],
  ["q", "window-close"],
  ["h", "window-focus-left"], ["j", "window-focus-down"],
  ["k", "window-focus-up"], ["l", "window-focus-right"],
  ["H", "window-move-left"], ["J", "window-move-down"],
  ["K", "window-move-up"], ["L", "window-move-right"],
].forEach((b) => weft.bind("helix-normal", "C-w " + b[0], b[1]));

weft.bind("helix-normal", "SPC q q", "quit");
weft.bind("helix-normal", "SPC h h", "pick-commands");
weft.bind("helix-normal", "SPC h g", "grants-show");
weft.bind("helix-normal", "SPC t w", "trim-trailing-buffer");
weft.bind("helix-source", "SPC t c", "comment-line");

// Numbers: helix's own increment/decrement keys.
weft.bind("helix-normal", "C-a", "increment-number");
weft.bind("helix-normal", "C-x", "decrement-number");

// Autopair (in helix's insert mode).
weft.bind("helix-insert", "parenleft", "pair-paren");
weft.bind("helix-insert", "braceleft", "pair-brace");
weft.bind("helix-insert", "bracketleft", "pair-bracket");
weft.bind("helix-insert", "quotedbl", "pair-quote");
weft.bind("helix-insert", "apostrophe", "pair-quote-single");
weft.bind("helix-insert", "parenright", "pair-close-paren");
weft.bind("helix-insert", "braceright", "pair-close-brace");
weft.bind("helix-insert", "bracketright", "pair-close-bracket");

weft.echo("weft: helix.js loaded");

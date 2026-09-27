// ide.js — weft as a conventional editor: no modes, the keys every desktop
// editor shares, and a files sidebar open from the start. Load with:
//   weft --config config/ide.js
//
// It is here to STRESS-TEST the binding and action system, not to be the
// friendliest setup. config.js leans on one grammar's leader tree; this file
// binds one flat key per operation and asks that key to mean the right thing
// wherever the focus is — a source file, the sidebar listing, a git status
// buffer, a picker. So nearly every key below names a `std.*` intention or an
// ACTION with context providers, not a plugin command, and the e2e gates
// (src/e2e/ide_test.zig) assert what each resolves to in each of those places.
// A key that would need a sidebar-specific or git-specific command to work is
// a missing door, and the gates are where that shows.
//
// Siblings: config.js is the reference setup under vim; helix.js is the same
// editor under Helix's grammar. The plane itself (weft.plugin, weft.bind, …)
// is documented at the top of config.js.

// ── The plugins ──────────────────────────────────────────────────────
// config.js's set, minus vim and plus `ide`: the grammar that makes shift
// extend a selection, Home smart, Tab indent and C-c/C-x/C-v transfer. It
// composes `motions` and `indent`/`comment` by name, like vim does. The
// dashboard stays out: its keys fall back to vim's `normal`.
weft.plugin("edit");        // line operators: duplicate-line, upcase-line, …
weft.plugin("complete");    // buffer-word completion provider
weft.plugin("project");     // recent files, project history
weft.plugin("structural");  // tree-sitter node ops
weft.plugin("region");      // subbuffer regions
weft.plugin("shell");       // insert shell-command output
weft.plugin("palette");     // command/buffer palette, status line
weft.plugin("motions");     // word/line/doc motions — each returns a range
weft.plugin("textobjects"); // iw/i"/i(/ip … — each returns a range
weft.plugin("operators");   // op.delete/upcase/lowercase — await a range
weft.plugin("ide");         // conventional non-modal editing
weft.plugin("ts");          // tree-sitter navigation
weft.set("languages", "query-root", "assets");
weft.plugin("languages.js"); // parser packages + explicit query paths
weft.plugin("comment");     // toggle line comments (C-/)
weft.plugin("indent");      // indent/dedent operators (Tab / S-Tab)
weft.plugin("whitespace");  // trim trailing whitespace
weft.plugin("numbers");     // increment/decrement the number under the cursor
weft.plugin("autopair");    // auto-close ( { [ " while typing
weft.plugin("consult");     // fuzzy-jump navigation (consult-line, imenu)
weft.plugin("find");        // the incremental find/replace bar (C-f, C-h, F3)
weft.plugin("git");         // git status/log/diff into tool buffers (proc)
weft.plugin("grep");        // ripgrep the project into a tool buffer (proc)
weft.plugin("run");         // run a shell command / the current line (proc)
weft.plugin("make");        // zig build / test into tool buffers (proc)
weft.plugin("notes");       // capture/open notes, and resolve their embeds (fs)
weft.plugin("fmt");         // format-buffer (by extension) + filter (proc)
weft.plugin("buffers");     // buf-pick (fuzzy buffer switch), buf-scratch
weft.plugin("modes");       // language activation (on focus) + lang-run
weft.plugin("snippets");    // expand named templates from a file (fs read)
weft.plugin("direnv");      // direnv status/allow/reload into a tool buffer
weft.plugin("llm");         // ask an llm CLI (minimal agent, proc + fs)
weft.plugin("console");     // a command console — run a line, append output
weft.plugin("repl");        // a stateful interactive REPL (persistent subprocess)
weft.plugin("net");         // raw TCP/TLS transport (net.connect)
weft.plugin("http");        // HTTP/1.0 over that transport
weft.plugin("which_key");   // menu-hint overlay
weft.plugin("files");       // file browser — what the sidebar shows
weft.plugin("lsp");         // language server client (F2, F12, S-F12, C-.)
weft.plugin("debug");       // breakpoints (F9)
weft.plugin("marginalia");  // pick-row annotations
weft.plugin("linenumbers"); // a line-number gutter on text entries
weft.plugin("offers");      // what a context offers: the toolbar's strip, mouse-3's menu

// The same breadth config.js writes down, for the same reasons: the browser
// goes where you point it, and the two `.js` plugins hold exactly what these
// lines grant them.
weft.grant("files", "fs_read",  { root: "/" });
weft.grant("files", "fs_write", { root: "/" });
// C-c / C-x / C-v mirror the unnamed register into the system clipboard,
// which only config can grant — and which register mirrors it is the
// grammar's setting (vim keeps `"+` apart instead).
weft.grant("ide", "clipboard");
weft.set("ide", "clipboard", "unnamed");
weft.grant("dap", "proc");
weft.plugin("dap.js");         // DAP client: F5/F10/F11
weft.grant("acp", "proc");
weft.grant("acp", "fs_read");
weft.grant("acp", "fs_write");
weft.plugin("acp.js");

// ── Fragments ────────────────────────────────────────────────────────
weft.use("defaults"); // picker and which-key keys
// The docked files companion, open by default: the sidebar is part of what
// an IDE looks like, and it is the second context every key below must make
// sense in. C-b hides and shows it.
weft.use("sidebar");
// The adaptive toolbar: one row along the top presenting what the primary
// context offers (`weft://here/offers/primary` as a strip) — a source file's
// build and format, a files listing's "New file", git's stage and commit —
// plus the pinned entries below. It takes no focus, so clicking it acts on
// the editor and leaves the keys there.
weft.use("toolbar");
// The menubar: File, Edit, Selection, View, Go, Run, Terminal, Help — every
// command that says where it lives, with the key that runs it here beside
// it (doc/chrome.md §2). Used AFTER the toolbar, so it docks above it: a
// later top dock wraps the ones before it. Alt with a title's letter opens
// its menu; F10 below lights the bar when no debugger claims the key.
weft.use("menubar");
// The View ▸ Appearance toggles for the chrome this file composes — the
// menubar's own, and the toolbar's.
weft.set("menu", "items", [
  "View/Appearance\tMenu Bar\tviewport.toggle menubar\tviewport.menubar.shown\tviewports\t1",
  "View/Appearance\tToolbar\tviewport.toggle toolbar\tviewport.toolbar.shown\tviewports\t2",
]);

// ── Values ───────────────────────────────────────────────────────────
weft.set("lsp", "zig", "zls");
weft.set("which_key", "delay-ms", "400"); // few chords here; don't pop eagerly
weft.set("editor", "flash-ms", "150");
weft.set("editor", "flash-undo", "on"); // undo/redo flash what they put back
weft.set("linenumbers", "style", "absolute"); // the conventional gutter
weft.set("palette", "arguments", "ask");
// Chrome as widgets: rounded buttons, real tabs whose close glyph shows on
// hover, icons, shadowed menus (doc/chrome.md §3.2).
weft.set("theme", "chrome", "widget");
// Which declared viewport C-b toggles — the fragment above calls it this.
weft.set("ide", "sidebar", "sidebar");
// Always on the toolbar, first: an intention shows its live availability
// (greyed, with the reason, when it cannot run); a command is `name\tLabel`.
weft.set("offers", "pinned", [
  "std.persistence.save\tSave",
  "std.history.undo\tUndo",
  "std.history.redo\tRedo",
  "palette.open\tPalette",
]);

// ── Actions: one key, a provider per context ─────────────────────────
// Spelled as intentions (`plugin.ide.*`), not flat names like config.js's
// `eval`: an intention is an OFFER, so the same word a key binds is what the
// toolbar and the context menu list, labelled and grouped by the options
// object of whichever provider wins here. A flat action name is a command
// alias and no chrome ever sees it.
//
// "In source" is a fact, said twice: a text entry whose bytes are FILES,
// here or on a remote host — never a tool's projection (a git status buffer
// is text too, but its locality is `tool`), and never a listing.
function provideInSource(action, when, cmd, opts) {
  for (const locality of ["local", "remote"])
    weft.provide(action, Object.assign({ posture: "text", locality: locality }, when), cmd, opts);
}

// Building, running, testing and debugging start a process WHERE the source
// is, and processes start only here (a peer's or a shell's place has no
// directory of ours to run in). So those are offered in local source only:
// open a peer's file and the toolbar drops "Build" because the file is
// remote — its locality — and for no other reason.
function provideLocal(action, when, cmd, opts) {
  weft.provide(action, Object.assign({ posture: "text", locality: "local" }, when), cmd, opts);
}

// Build/run by language: the language's provider says more than the
// fallback (one fact more), so it wins where it applies.
weft.action("plugin.code.run");
provideLocal("plugin.code.run", {}, "run.line", { label: "Run line", group: "run", order: 1 });
provideLocal("plugin.code.run", { lang: "zig" }, "make.build", { label: "Build", group: "build", order: 1 });
// Send to REPL: offered only where a REPL is live. The repl plugin publishes
// `repl.session` on the place its interpreter runs in, so this is a fact of
// the context like the language is — the toolbar grows the button while a
// REPL runs and drops it when the REPL quits, and neither the toolbar nor
// this file knows how a REPL is tracked.
weft.action("plugin.code.send-to-repl");
provideInSource("plugin.code.send-to-repl", { context: { "repl.session": "*" } }, "repl.send-line", { label: "Send to REPL", group: "run", order: 2 });
provideLocal("plugin.code.run", { lang: "py" }, "modes.run", { label: "Run", group: "run", order: 1 });
weft.action("plugin.code.test");
provideLocal("plugin.code.test", { lang: "zig" }, "make.test", { label: "Test", group: "build", order: 2 });
weft.action("plugin.code.debug");
provideLocal("plugin.code.debug", { lang: "zig" }, "debug.start", { label: "Debug", group: "build", order: 3 });
weft.action("plugin.code.format");
provideInSource("plugin.code.format", {}, "fmt.format-buffer", { label: "Format", group: "edit", order: 10 });

// F2 renames what the focus is ON: the symbol under the cursor in source (the
// language server), the row's name in a listing. The listing provider keys on
// the entry's TOOL identity — the files listing, whose rows' names are fields
// — not on the mode a text-less entry rests in: that was a grammar detail
// standing in for the fact, and it also claimed git's rows, whose names are
// not fields. A git status buffer is neither source nor the files tool, so
// it is offered no rename at all.
weft.action("plugin.code.rename");
provideInSource("plugin.code.rename", {}, "rename", { label: "Rename", group: "edit", order: 11 });
weft.provide("plugin.code.rename", { tool: "files" }, "field.edit", { label: "Rename", group: "edit", order: 11 });

// Where these actions sit in the menubar: each runs whichever provider
// answers it in the editor, so Run ▸ Run builds a Zig file and runs a line
// elsewhere, and its key is the one bound below.
weft.command("plugin.code.run", { label: "Run", menu: "Run", group: "run", order: 1, icon: "play" });
weft.command("plugin.code.test", { label: "Test", menu: "Run", group: "run", order: 2, icon: "test" });
weft.command("plugin.code.debug", { label: "Start Debugging", menu: "Run", group: "debug", order: 1, icon: "bug" });
weft.command("plugin.code.format", { label: "Format Document", menu: "Edit", group: "format", order: 1, icon: "format" });
weft.command("plugin.code.rename", { label: "Rename Symbol", menu: "Edit", group: "refactor", order: 1, icon: "rename", prompts: true });

// ── Keys ─────────────────────────────────────────────────────────────
// The GRAMMAR binds the editing keys (arrows, shift-selection, Home/End, Tab,
// C-/, A-Up/Down, C-c/C-x/C-v, C-z/C-y, Escape) — see src/plugins/ide. What
// this file binds is the workspace: files, buffers, pickers, the language
// server, the debugger.
//
// Workspace keys are bound twice, on purpose. `ide` falls back to core's
// modeless floor, which claims C-s, C-b and C-Tab itself, so a key meant to
// win in a text or listing entry is bound in `ide`. A tool mode (git's) has
// no fallback at all; the `global` layer is what reaches it.
function bindWorkspace(key, arms) {
  weft.bind("ide", key, arms);
  weft.bind("global", key, arms);
}

// Files and buffers. Save asks the focused entry first: in a commit draft
// C-s commits, in a file it writes.
bindWorkspace("C-s", ["std.persistence.save", "file.save"]);
bindWorkspace("C-S-s", "file.save-as");
bindWorkspace("C-o", "ide.open-path");      // open a typed path (new files too)
bindWorkspace("C-p", "files.find");     // fuzzy-open a project file
bindWorkspace("C-S-p", "palette.open"); // the palette: commands AND live offers
bindWorkspace("C-w", "buffer.close");
bindWorkspace("C-Tab", "buffer.next");
bindWorkspace("C-b", "ide.toggle-sidebar");

// The pointer. mouse-3 presents what the context under it offers
// (`weft://here/offers/at-pointer`) as a menu there — a row of the sidebar,
// the text, a git row — and S-F10 / Menu the focused context's at the caret.
// (The grammar binds what double, triple and C-clicks mean.)
bindWorkspace("mouse-3", "offers.menu");
bindWorkspace("S-F10", "offers.menu-at-caret");
bindWorkspace("Menu", "offers.menu-at-caret");

// Back and forward along the jumplist: M-Left / M-Right, and VS Code's
// C-M-minus / C-S-minus. A view with its own history (a listing) answers
// back first.
bindWorkspace("M-Left", ["std.navigation.back", "jump.back"]);
bindWorkspace("M-Right", "jump.forward");
bindWorkspace("C-M-minus", ["std.navigation.back", "jump.back"]);
bindWorkspace("C-S-minus", "jump.forward");
bindWorkspace("C-underscore", "jump.forward");

// Search and jump. C-f opens the find bar and C-h the same bar with a
// replacement field (doc/configs.md §3.4); F3 / S-F3 step through the last
// search's matches whether the bar is open or not. The bar's own keys
// (Enter, M-r/M-c/M-w, M-Return, C-M-Return, Escape) are the `find` mode's.
weft.bind("ide", "C-f", "find.open");
weft.bind("ide", "C-h", "find.replace");
weft.bind("ide", "F3", "find.next");
weft.bind("ide", "S-F3", "find.prev");
weft.bind("ide", "C-g", "jump.line");

// The language server, in source.
weft.bind("ide", "F2", "plugin.code.rename");
weft.bind("ide", "F12", "lsp.goto-definition");
weft.bind("ide", "S-F12", "lsp.references");
weft.bind("ide", "C-period", "lsp.code-actions");
weft.bind("ide", "C-space", "complete.show");
weft.bind("ide", "C-S-b", "plugin.code.run");   // build / run, by language
weft.bind("ide", "M-S-f", "plugin.code.format");  // format the buffer

// The debugger: the IDE-standard F-keys. F10 steps over while a debug
// session is live — dap.js publishes `dap.session` — and otherwise lights the
// menubar, the other thing F10 conventionally does: an intention is offered
// only where its provider's facts hold, so the key falls through to the
// menubar the moment no session is there to step.
bindWorkspace("F5", "debug.continue");
weft.bind("ide", "F9", "debug.toggle-breakpoint");
weft.action("plugin.debug.step-over");
weft.provide("plugin.debug.step-over", { context: { "dap.session": "*" } }, "debug.step-over", { label: "Step Over", group: "debug", order: 2 });
bindWorkspace("F10", ["plugin.debug.step-over", "menu.focus-bar"]);
bindWorkspace("F11", "debug.step-into");

weft.bind("global", "F1", "which-key.show");

// Auto-close pairs while typing — `ide` commits text, so these fire as you
// type, the way vim's insert-mode binds do.
weft.bind("ide", "parenleft", "autopair.open-paren");
weft.bind("ide", "braceleft", "autopair.open-brace");
weft.bind("ide", "bracketleft", "autopair.open-bracket");
weft.bind("ide", "quotedbl", "autopair.quote-double");
weft.bind("ide", "parenright", "autopair.close-paren");
weft.bind("ide", "braceright", "autopair.close-brace");
weft.bind("ide", "bracketright", "autopair.close-bracket");

// ── Panels ───────────────────────────────────────────────────────────
// The bottom panel (config/panel.js) shows one of two plugins' entries at a
// time: the problems list or the terminal. Each brings its own entry in with
// core's `viewport.take`; C-j shows and hides whichever it holds. The
// breadcrumbs are status-line segments, so they need no viewport at all.
weft.use("panel");
weft.plugin("panel");        // panel-toggle: show or hide the panel
weft.plugin("problems");     // every diagnostic, grouped by file; Return jumps
weft.plugin("terminal");     // a LINE-MODE shell (no terminal emulation)
weft.plugin("breadcrumbs");  // path › symbol › symbol for the caret
bindWorkspace("C-j", "panel.toggle");
bindWorkspace("C-grave", "terminal.open");
bindWorkspace("C-S-m", "problems.open");

// ── The status bar ───────────────────────────────────────────────────
// One bar along the bottom of the window (config/statusbar.js), presenting
// the editor's status: the place, git's branch, the problems counts and a
// running build on the left; Ln/Col, the language and the plugins' chips on
// the right. The panes — the editor, its splits, the sidebar — carry no
// status line of their own. Last among the docked fragments, so it spans
// the whole window, under the sidebar and the panel too.
weft.use("statusbar");

weft.echo("weft: ide.js loaded");

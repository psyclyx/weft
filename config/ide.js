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
weft.plugin("windows");     // win-split/vsplit/focus/close/center
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

// The same breadth config.js writes down, for the same reasons: the browser
// goes where you point it, and the two `.js` plugins hold exactly what these
// lines grant them.
weft.grant("files", "fs_read",  { root: "/" });
weft.grant("files", "fs_write", { root: "/" });
// C-c / C-x / C-v mirror the unnamed register into the system clipboard,
// which only config can grant.
weft.grant("ide", "clipboard");
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

// ── Values ───────────────────────────────────────────────────────────
weft.set("lsp", "zig", "zls");
weft.set("which_key", "delay-ms", "400"); // few chords here; don't pop eagerly
weft.set("editor", "flash-ms", "150");
weft.set("editor", "flash-undo", "on"); // undo/redo flash what they put back
weft.set("linenumbers", "style", "absolute"); // the conventional gutter
weft.set("palette", "arguments", "ask");
// Which declared viewport C-b toggles — the fragment above calls it this.
weft.set("ide", "sidebar", "sidebar");

// ── Actions: one key, a provider per context ─────────────────────────
// `eval` and `format` as config.js declares them.
weft.action("eval");
weft.provide("eval", {}, "run-line");
weft.provide("eval", { lang: "zig" }, "make-build");
weft.provide("eval", { lang: "py" }, "lang-run");
weft.action("format");
weft.provide("format", {}, "format-buffer");

// F2 renames what the focus is ON: the symbol under the cursor in source (the
// language server), the row's name in a listing. The listing provider keys on
// the entry's TOOL identity — the files listing, whose rows' names are fields
// — not on the mode a text-less entry rests in: that was a grammar detail
// standing in for the fact, and it also claimed git's rows, whose names are
// not fields. A git status buffer keeps the source default. The options object
// is how the offer is presented where it wins (a toolbar's label).
weft.action("rename-here");
weft.provide("rename-here", {}, "rename", { label: "Rename", group: "edit" });
weft.provide("rename-here", { tool: "files" }, "field-edit", { label: "Rename", group: "edit" });

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
bindWorkspace("C-s", ["std.persistence.save", "save"]);
bindWorkspace("C-S-s", "save-as");
bindWorkspace("C-o", "open-path");      // open a typed path (new files too)
bindWorkspace("C-p", "quick-open");     // fuzzy-open a project file
bindWorkspace("C-S-p", "pick-commands"); // the palette: commands AND live offers
bindWorkspace("C-w", "close");
bindWorkspace("C-Tab", "buffer-next");
bindWorkspace("C-b", "ide-toggle-sidebar");

// Search and jump. C-f opens the find bar and C-h the same bar with a
// replacement field (doc/configs.md §3.4); F3 / S-F3 step through the last
// search's matches whether the bar is open or not. The bar's own keys
// (Enter, M-r/M-c/M-w, M-Return, C-M-Return, Escape) are the `find` mode's.
weft.bind("ide", "C-f", "find");
weft.bind("ide", "C-h", "find-replace");
weft.bind("ide", "F3", "find-next");
weft.bind("ide", "S-F3", "find-prev");
weft.bind("ide", "C-g", "goto-line");

// The language server, in source.
weft.bind("ide", "F2", "rename-here");
weft.bind("ide", "F12", "goto-definition");
weft.bind("ide", "S-F12", "references");
weft.bind("ide", "C-period", "code-actions");
weft.bind("ide", "C-space", "complete");
weft.bind("ide", "C-S-b", "eval");   // build / run, by language
weft.bind("ide", "M-S-f", "format"); // format the buffer

// The debugger: the IDE-standard F-keys.
bindWorkspace("F5", "debug-continue");
weft.bind("ide", "F9", "debug-toggle-breakpoint");
bindWorkspace("F10", "debug-step-over");
bindWorkspace("F11", "debug-step-into");

weft.bind("global", "F1", "which-key-now");

// Auto-close pairs while typing — `ide` commits text, so these fire as you
// type, the way vim's insert-mode binds do.
weft.bind("ide", "parenleft", "pair-paren");
weft.bind("ide", "braceleft", "pair-brace");
weft.bind("ide", "bracketleft", "pair-bracket");
weft.bind("ide", "quotedbl", "pair-quote");
weft.bind("ide", "parenright", "pair-close-paren");
weft.bind("ide", "braceright", "pair-close-brace");
weft.bind("ide", "bracketright", "pair-close-bracket");

weft.echo("weft: ide.js loaded");

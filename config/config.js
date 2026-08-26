// config.js — the sample user config, run in quickjs.wasm (plan 06B). This is
// the local plane: the reborn init.fnl, now JavaScript. It reaches the editor
// ONLY through the `weft.*` surface the sandbox grants — the same door a plugin
// uses, no core privilege. weft ships modeless; this config brings up the
// reference catalog itself, so the dev entry point needs no --plugin flags.
//
// Available:
//   weft.plugin(name)              — load a reference plugin (or a .wasm path)
//   weft.bind(mode, keys, command) — bind a key or a key SEQUENCE ("SPC f f")
//                                    in a mode; a multi-key sequence is a chord,
//                                    its prefixes are which-key menus for free
//   weft.action(name)              — declare an abstract intent a key can bind to
//   weft.semanticAction(name)      — declare an open focused-view action command
//   weft.provide(name, when, cmd[, prio]) — a provider for an action, chosen by
//                                    {mode, lang} at fire time (the synthetic bind)
//   weft.set(plugin, key, value)   — hand a plugin config data (overrides defaults)
//   weft.run(command, ...args)     — invoke a command now; up to eight bounded
//                                    string args (e.g. grammar-add)
//   weft.echo(message)             — a transient status-line message
//   weft.log(message)              — a line to the editor log

// Bring up the catalog. Each runs sandboxed under wasmtime behind the perm
// handshake; loading is synchronous, so the commands they register exist by
// the time the binds below reference them. Order matters only where one
// plugin's keymap layers over another's commands.
weft.plugin("edit");        // line operators: duplicate-line, upcase-line, …
weft.plugin("complete");    // buffer-word completion provider
weft.plugin("project");     // recent files, project history
weft.plugin("structural");  // tree-sitter node ops
weft.plugin("region");      // subbuffer regions
weft.plugin("shell");       // insert shell-command output
weft.plugin("palette");     // "std" UI: command/buffer palette, status line
weft.plugin("motions");     // word/WORD/line/doc motions — each returns a range
weft.plugin("textobjects"); // iw/i"/i(/ip … — each returns a range
weft.plugin("operators");   // op.delete/upcase/lowercase — await a range
weft.plugin("vim");         // modal editing — composes motions + textobjects + operators
weft.plugin("ts");          // tree-sitter navigation: expand-selection, select-function
weft.plugin("comment");     // toggle line comments (gc operator)
weft.plugin("indent");      // indent/dedent operators (> / <)
weft.plugin("whitespace");  // trim trailing whitespace
weft.plugin("numbers");     // increment/decrement the number under the cursor
weft.plugin("autopair");    // auto-close ( { [ " in insert mode
weft.plugin("consult");     // fuzzy-jump navigation (consult-line, imenu)
weft.plugin("git");         // git status/log/diff into tool buffers (proc)
weft.plugin("grep");        // ripgrep the project into a tool buffer (proc)
weft.plugin("run");         // run a shell command / the current line (proc)
weft.plugin("make");        // zig build / test into tool buffers (proc)
weft.plugin("notes");       // capture/open notes over fs read+write
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
weft.plugin("which_key");   // menu-hint overlay, as a plugin over the surface door
weft.plugin("files");       // file browser; the target handler owns its semantic scene/actions
weft.plugin("lsp");         // language server client (hover/def/… over jsonrpc)
weft.set("lsp", "zig", "zls"); // server per language: weft.set("lsp","<lang>","<cmd>")
weft.plugin("debug");       // breakpoints (gutter markers) — the debugger's first slice
// A `.js` plugin declares nothing about itself, so `weft.grant` is its ONLY
// door to an effect: with no grant it fails closed and every weft.procSpawn /
// weft.fileRead call throws. The DAP client needs `proc` — it drives a debug
// adapter over stdio. (Grants apply as their own pass before any plugin
// loads, so this reads next to the load purely for the reader's sake.)
weft.grant("dap", "proc");
weft.plugin("dap.js");      // DAP client: run/step/inspect (set weft.set("dap","cmd",<adapter>))

// Shared, editor-agnostic key bindings (the picker, and — below — which-key nav):
// core ships the commands + modes; the BINDINGS are config data. Overridable by
// anything bound after this line.
weft.use("defaults");

// ── Doom-Emacs-style leader (SPC). A menu is a prefix KEY SEQUENCE, not a mode:
// `space` is just the first key of chords like `space f f`. The keymap holds the
// chord pending as you type it (which_key shows the next-key completions off the
// pending prefix) and runs the leaf when the sequence completes. No `weft.menu`,
// no mode to enter — `space g g` never touches a `leader-git` mode, it's one key
// sequence bound in `normal`. `space C-w` is inert (a distinct chord), so the
// global window prefix (`C-w …`) can't be reached through the leader.

// which-key: hold a prefix for this long before the hint pops (doom-style idle
// delay). F1 forces it now (a peek at the top-level choices from normal).
weft.set("which_key", "delay-ms", "200"); // owned by which_key, not the old "editor" grab-bag
weft.bind("global", "F1", "which-key-now");

// Top-level leader: quick actions (the group prefixes below are implied by the
// longer sequences — `space f …` makes `space f` a group automatically).
weft.bind("normal", "SPC SPC", "find-file");     // SPC SPC — find file
weft.bind("normal", "SPC :", "pick-commands"); // SPC :   — M-x (run a command)
weft.bind("normal", "SPC .", "find-file");    // SPC .   — find file
weft.bind("normal", "SPC ,", "buf-pick");      // SPC ,   — switch buffer

// SPC f — files
weft.bind("normal", "SPC f f", "find-file");
weft.bind("normal", "SPC f s", "save");
weft.bind("normal", "SPC f S", "save-as");
weft.bind("normal", "SPC f r", "project-recent");
weft.bind("normal", "SPC f d", "files");

// SPC b — buffers
weft.bind("normal", "SPC b b", "buf-pick");
weft.bind("normal", "SPC b d", "buffer-close");
weft.bind("normal", "SPC b k", "buffer-close");
weft.bind("normal", "SPC b n", "buffer-next");
weft.bind("normal", "SPC b s", "save");
weft.bind("normal", "SPC b N", "buf-scratch");

// SPC g — git. `git-status` opens the *git* model buffer, which runs its own
// `git` keymap: j/k move, TAB folds, s/u stage/unstage (file/hunk/region),
// S/U stage-all, g refresh, RET visits a file (or shows a commit), q leaves.
// The Phase-2b/2c transients (which-key renders each menu mode):
//   c  commit dispatch  — c commit · a amend · e extend · w reword ·
//                          f fixup · s squash (fixup/squash target the commit
//                          under point; amend/reword reuse the *git-commit* buffer)
//   b  branch  — b checkout · c create+checkout · n new · d delete · r rename
//   z  stash   — z save · p pop · a apply · l list · k drop
//   l  log     — l oneline graph · a --all
//   r  rebase  — i interactive (edits a *git-rebase* todo) · c/a/s continue/abort/skip
//   x  on a file/hunk discards (confirmed); on a commit opens the reset transient
//   A/V  cherry-pick / revert the commit under point
//   P/F/f  push/pull/fetch — flag transients (toggle -f/-u, --rebase, --all/--prune)
weft.bind("normal", "SPC g g", "git-status");
weft.bind("normal", "SPC g i", "git-init"); // start version control (git init) from the editor
weft.bind("normal", "SPC g l", "git-log");
weft.bind("normal", "SPC g d", "git-diff");
weft.bind("normal", "SPC g D", "git-diff-staged");
weft.bind("normal", "SPC g b", "git-blame");

// `.` — repeat the last change (vim dot-repeat). The recorder is core (it
// records keystrokes through the one dispatch path), so it repeats a change made
// by ANY plugin — vim operators, autopair, comment, structural — not just vim's.
weft.bind("normal", ".", "repeat-change");

// `/` — search in this buffer (vim's search key). consult-line is a fuzzy
// in-buffer jump: type a pattern, Return lands on the match. (A vim user reaches
// for `/`; without this it did nothing — only SPC s s / SPC / were bound.)
weft.bind("normal", "/", "consult-line");

// SPC s — search
weft.bind("normal", "SPC s s", "consult-line");
weft.bind("normal", "SPC s i", "consult-imenu");
weft.bind("normal", "SPC s p", "grep");
weft.bind("normal", "SPC s w", "grep-word");

// SPC p — project
weft.bind("normal", "SPC p p", "project-recent");
weft.bind("normal", "SPC p f", "find-file");
weft.bind("normal", "SPC p r", "project-recent");
weft.bind("normal", "SPC p R", "project-root"); // echo the VCS root (projectile-style)
weft.bind("normal", "SPC p /", "grep");

// SPC c — code
weft.bind("normal", "SPC c c", "comment-line");
weft.bind("normal", "SPC c f", "format"); // the format action (see above)
weft.bind("normal", "SPC c d", "goto-definition");
weft.bind("normal", "SPC c h", "hover");
weft.bind("normal", "SPC c s", "symbols");
weft.bind("normal", "SPC c F", "lsp-format"); // format via the language server
weft.bind("normal", "SPC c R", "references");
weft.bind("normal", "g r", "references"); // vim-style
weft.bind("normal", "g R", "rename"); // rename the symbol under the cursor
weft.bind("normal", "SPC c k", "signature-help");
weft.bind("normal", "SPC c i", "inlay-hints");
weft.bind("normal", "SPC c a", "code-actions");
weft.bind("normal", "] d", "next-diagnostic"); // vim-style diagnostic navigation
weft.bind("normal", "[ d", "prev-diagnostic");

// Completion — trigger the at-caret popup (buffer-word + LSP race + merge-rank).
// C-SPC from insert (where you're typing) and normal (browse from rest).
weft.bind("insert", "C-SPC", "complete");
weft.bind("normal", "C-SPC", "complete");
weft.bind("normal", "SPC c e", "ts-expand-selection");
weft.bind("normal", "SPC c n", "ts-select-node");
weft.bind("normal", "SPC c b", "make-build");
weft.bind("normal", "SPC c t", "make-test");
weft.bind("normal", "SPC c r", "lang-run");
weft.bind("normal", "SPC c x", "run-line");

// ── Actions: abstract intents resolved by CONTEXT (the dispatch middle tier).
// weft.action(name) declares an intent a key binds to; weft.provide(name, when,
// cmd[, prio]) registers a provider chosen by {mode, lang} when it fires. Bind
// the key ONCE — a .zig buffer and a shell script run different commands, and
// any language plugin can weft.provide a new provider without touching this
// keymap. `eval` unifies the old SPC-c r/x split (lang-run vs run-line) into one
// language-aware key; a buffer with no provider echoes "no eval provider here".
weft.action("eval");
weft.provide("eval", {}, "run-line");                 // default: run the current line
weft.provide("eval", { lang: "zig" }, "make-build");  // a .zig buffer builds the project
weft.provide("eval", { lang: "py" }, "lang-run");     // python: the language runner
weft.bind("normal", "SPC e", "eval");               // SPC e — eval/run, by language

// format is likewise an action: fmt handles most languages by extension, but a
// language plugin can weft.provide("format", {lang:"…"}, "…") to override. The
// SPC c f binding below targets this action instead of format-buffer directly.
weft.action("format");
weft.provide("format", {}, "format-buffer");

// vim-style: K shows hover, gd goes to definition, gs lists symbols
weft.bind("normal", "K", "hover");

// ── Coding agents (ACP). Uncomment + point at your agent adapter to enable.
// weft is the harness: the agent's file I/O and tool approvals cross the ABI,
// so each edit is a gated, attributed peer commit. The launch command is YOURS
// (weft assumes nothing about how it's installed — NixOS-friendly):
//   weft.set("acp", "cmd", "codex-acp");   // or claude-agent-acp / gemini --experimental-acp / …
//   weft.set("acp", "prompt", "Summarize this project.");
//   weft.grant("acp", "proc");             // spawn + drive the agent over stdio
//   weft.grant("acp", "fs_read");          // answer the agent's fs/read_text_file
//   weft.grant("acp", "fs_write");         // answer its fs/write_text_file
//   weft.plugin("acp.js");                 // the ACP client (a JS plugin)
//   weft.bind("normal", "SPC o A", "agent-start"); // SPC o A — start the agent
//   weft.bind("normal", "SPC o s", "agent-send");  // SPC o s — send this line

// SPC o — open / tools
weft.bind("normal", "SPC o d", "files");
weft.bind("normal", "SPC o r", "repl-start");
weft.bind("normal", "SPC o c", "console-open");
weft.bind("normal", "SPC o e", "direnv-status");
weft.bind("normal", "SPC o a", "llm-ask-line");

// SPC d — debug. Breakpoints today (gutter markers); run/step/inspect arrive
// with the debug adapter. F9 toggles a breakpoint (the IDE convention).
weft.bind("normal", "SPC d b", "debug-toggle-breakpoint");
weft.bind("normal", "SPC d c", "debug-clear-breakpoints");
weft.bind("normal", "SPC d l", "debug-list-breakpoints");
weft.bind("normal", "F9", "debug-toggle-breakpoint");
// The DAP session (dap.js): start, continue, step, stop. F5/F10/F11 are the IDE
// conventions; the SPC d leaf mirrors them.
weft.bind("normal", "SPC d d", "debug-start");
weft.bind("normal", "SPC d r", "debug-continue");
weft.bind("normal", "SPC d n", "debug-step-over");
weft.bind("normal", "SPC d i", "debug-step-into");
weft.bind("normal", "SPC d o", "debug-step-out");
weft.bind("normal", "SPC d q", "debug-stop");
weft.bind("normal", "F5", "debug-continue");
weft.bind("normal", "F10", "debug-step-over");
weft.bind("normal", "F11", "debug-step-into");

// SPC n — notes
weft.bind("normal", "SPC n n", "notes-open");
weft.bind("normal", "SPC n c", "notes-capture");

// SPC w — window. Split/close via the windows plugin; focus + move go
// straight to the core window-layout commands (a real recursive split
// tree), so h/j/k/l walk panes and H/J/K/L swap them, vim-style.
weft.bind("normal", "SPC w v", "win-vsplit");
weft.bind("normal", "SPC w s", "win-split");
weft.bind("normal", "SPC w w", "win-focus");
weft.bind("normal", "SPC w d", "win-close");
weft.bind("normal", "SPC w c", "win-center");
weft.bind("normal", "SPC w o", "win-close");
weft.bind("normal", "SPC w q", "window-close");
weft.bind("normal", "SPC w h", "window-focus-left");
weft.bind("normal", "SPC w j", "window-focus-down");
weft.bind("normal", "SPC w k", "window-focus-up");
weft.bind("normal", "SPC w l", "window-focus-right");
weft.bind("normal", "SPC w H", "window-move-left");
weft.bind("normal", "SPC w J", "window-move-down");
weft.bind("normal", "SPC w K", "window-move-up");
weft.bind("normal", "SPC w L", "window-move-right");

// SPC q — quit
weft.bind("normal", "SPC q q", "quit");

// SPC h — help (execute/describe a command via the palette)
weft.bind("normal", "SPC h c", "pick-commands");
weft.bind("normal", "SPC h h", "pick-commands");

// SPC t — toggle
weft.bind("normal", "SPC t w", "trim-trailing-buffer");
weft.bind("normal", "SPC t c", "comment-line");

// SPC v — generic structured-view controls. Movement remains an ordinary
// input command; every operation below names the exact open semantic action
// advertised by a directory view, picker, or any other plugin-owned scene.
//
// Keep the declaration data-shaped: adding another generic view action is one
// entry here, and a plugin never needs to know which tool/config supplied the
// binding. Dialog inputs intentionally do not belong in this group; an active
// interaction owns those locally and consumes them before global keymaps.
function bindActionGroup(mode, prefix, bindings) {
  for (var i = 0; i < bindings.length; i++) {
    var binding = bindings[i];
    // Semantic action names are an open plugin/view protocol. Declaring the
    // command here keeps this table data-shaped: a future structured view can
    // add its own action without a core or Vim/file-browser special case.
    weft.semanticAction(binding[1]);
    weft.bind(mode, prefix + " " + binding[0], binding[1]);
  }
}

weft.bind("normal", "SPC v j", "cursor-down");
weft.bind("normal", "SPC v k", "cursor-up");
bindActionGroup("normal", "SPC v", [
  ["o", "target.open"],
  ["-", "target.open-container"],
  ["c", "workspace.set-working-target"],
  ["e", "field.edit"],
  ["y", "selection.copy"],
  ["x", "selection.cut"],
  ["d", "selection.delete"],
  ["m", "fs.permissions.edit"],
  ["n", "fs.entry.create-file"],
  ["N", "fs.entry.create-directory"],
  ["p", "selection.paste-after"],
  ["P", "selection.paste-before"],
  ["r", "view.refresh"],
  ["R", "view.revert"],
  ["a", "view.apply"],
]);

// Numbers: vim-style increment/decrement.
weft.bind("normal", "C-a", "increment-number");
weft.bind("normal", "C-x", "decrement-number");

// Auto-close pairs while typing (insert mode).
weft.bind("insert", "parenleft", "pair-paren");
weft.bind("insert", "braceleft", "pair-brace");
weft.bind("insert", "bracketleft", "pair-bracket");
weft.bind("insert", "quotedbl", "pair-quote");
weft.bind("insert", "apostrophe", "pair-quote-single"); // ' pairs, except in lisps (a quote)
// Type-over: typing the closing delimiter steps over an auto-inserted one, so
// typing balanced `f(x)` stays `f(x)` instead of `f(x))`.
weft.bind("insert", "parenright", "pair-close-paren");
weft.bind("insert", "braceright", "pair-close-brace");
weft.bind("insert", "bracketright", "pair-close-bracket");

// Theme is data: override any Theme field by name with an sRGB hex. (A full
// colorscheme is just a block of these; `set-color` does the same at runtime.)
weft.set("theme", "accent", "#8ec07c");
weft.set("theme", "cursor", "#fabd2f");
weft.set("theme", "selection", "#3c4a5e");

weft.echo("weft: config.js loaded");

// config.js — the sample user config, run in quickjs.wasm (plan 06B). This is
// the local plane: the reborn init.fnl, now JavaScript. It reaches the editor
// ONLY through the `weft.*` surface the sandbox grants — the same door a plugin
// uses, no core privilege. weft ships modeless; this config brings up the
// reference catalog itself, so the dev entry point needs no --plugin flags.
//
// Available:
//   weft.plugin(name)              — load a reference plugin (or a .wasm path)
//   weft.bind(mode, key, command)  — bind a key in a keymap mode
//   weft.menu(name)                — declare a which-key submenu (a prefix mode)
//   weft.set(plugin, key, value)   — hand a plugin config data (overrides defaults)
//   weft.run(command)              — invoke a command now (startup actions)
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
weft.plugin("comment");     // toggle line comments
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
weft.plugin("dired");       // directory editor (proc ls + its own keymap mode)

// ── Doom-Emacs-style leader (SPC). vim provides the `leader` menu mode (SPC
// enters it in normal); which_key shows the tree. Each SPC <group> opens a
// which-key submenu; a group binding whose command NAMES a menu mode enters it.
// weft.menu(name) declares a submenu — the leader tree is config, not baked in.

// Declare the submenu modes first (so the leader keys below can enter them).
[
  "leader-file", "leader-buffer", "leader-git", "leader-search",
  "leader-project", "leader-code", "leader-open", "leader-notes",
  "leader-window", "leader-quit", "leader-help", "leader-toggle",
].forEach((m) => weft.menu(m));

// Top-level leader: quick actions + the group prefixes (doom's SPC map).
weft.bind("leader", "space", "find-file");       // SPC SPC — find file
weft.bind("leader", "colon", "pick-commands");   // SPC :   — M-x (run a command)
weft.bind("leader", "period", "find-file");      // SPC .   — find file
weft.bind("leader", "comma", "buf-pick");        // SPC ,   — switch buffer
weft.bind("leader", "f", "leader-file");         // SPC f   — files
weft.bind("leader", "b", "leader-buffer");       // SPC b   — buffers
weft.bind("leader", "g", "leader-git");          // SPC g   — git
weft.bind("leader", "s", "leader-search");       // SPC s   — search
weft.bind("leader", "p", "leader-project");      // SPC p   — project
weft.bind("leader", "c", "leader-code");         // SPC c   — code
weft.bind("leader", "o", "leader-open");         // SPC o   — open
weft.bind("leader", "n", "leader-notes");        // SPC n   — notes
weft.bind("leader", "w", "leader-window");       // SPC w   — window
weft.bind("leader", "q", "leader-quit");         // SPC q   — quit
weft.bind("leader", "h", "leader-help");         // SPC h   — help
weft.bind("leader", "t", "leader-toggle");       // SPC t   — toggle

// SPC f — files
weft.bind("leader-file", "f", "find-file");
weft.bind("leader-file", "s", "save");
weft.bind("leader-file", "S", "save-as");
weft.bind("leader-file", "r", "project-recent");
weft.bind("leader-file", "d", "dired");

// SPC b — buffers
weft.bind("leader-buffer", "b", "buf-pick");
weft.bind("leader-buffer", "d", "buffer-close");
weft.bind("leader-buffer", "k", "buffer-close");
weft.bind("leader-buffer", "n", "buffer-next");
weft.bind("leader-buffer", "s", "save");
weft.bind("leader-buffer", "N", "buf-scratch");

// SPC g — git (magit-style status has its own s/u/g binds once open)
weft.bind("leader-git", "g", "git-status");
weft.bind("leader-git", "l", "git-log");
weft.bind("leader-git", "d", "git-diff");
weft.bind("leader-git", "D", "git-diff-staged");
weft.bind("leader-git", "b", "git-blame");

// SPC s — search
weft.bind("leader-search", "s", "consult-line");
weft.bind("leader-search", "i", "consult-imenu");
weft.bind("leader-search", "p", "grep");
weft.bind("leader-search", "w", "grep-word");

// SPC p — project
weft.bind("leader-project", "p", "project-recent");
weft.bind("leader-project", "f", "find-file");
weft.bind("leader-project", "r", "project-recent");
weft.bind("leader-project", "slash", "grep");

// SPC c — code
weft.bind("leader-code", "c", "comment-line");
weft.bind("leader-code", "f", "format-buffer");
weft.bind("leader-code", "e", "ts-expand-selection");
weft.bind("leader-code", "n", "ts-select-node");
weft.bind("leader-code", "b", "make-build");
weft.bind("leader-code", "t", "make-test");
weft.bind("leader-code", "r", "lang-run");
weft.bind("leader-code", "x", "run-line");

// SPC o — open / tools
weft.bind("leader-open", "d", "dired");
weft.bind("leader-open", "r", "repl-start");
weft.bind("leader-open", "c", "console-open");
weft.bind("leader-open", "e", "direnv-status");
weft.bind("leader-open", "a", "llm-ask-line");

// SPC n — notes
weft.bind("leader-notes", "n", "notes-open");
weft.bind("leader-notes", "c", "notes-capture");

// SPC w — window
weft.bind("leader-window", "v", "win-vsplit");
weft.bind("leader-window", "s", "win-split");
weft.bind("leader-window", "w", "win-focus");
weft.bind("leader-window", "d", "win-close");
weft.bind("leader-window", "c", "win-center");
weft.bind("leader-window", "o", "win-close");

// SPC q — quit
weft.bind("leader-quit", "q", "quit");

// SPC h — help (execute/describe a command via the palette)
weft.bind("leader-help", "c", "pick-commands");
weft.bind("leader-help", "h", "pick-commands");

// SPC t — toggle
weft.bind("leader-toggle", "w", "trim-trailing-buffer");
weft.bind("leader-toggle", "c", "comment-line");

// Numbers: vim-style increment/decrement.
weft.bind("normal", "C-a", "increment-number");
weft.bind("normal", "C-x", "decrement-number");

// Auto-close pairs while typing (insert mode).
weft.bind("insert", "parenleft", "pair-paren");
weft.bind("insert", "braceleft", "pair-brace");
weft.bind("insert", "bracketleft", "pair-bracket");
weft.bind("insert", "quotedbl", "pair-quote");
weft.bind("insert", "apostrophe", "pair-quote-single"); // ' pairs, except in lisps (a quote)

// Theme is data: override any Theme field by name with an sRGB hex. (A full
// colorscheme is just a block of these; `set-color` does the same at runtime.)
weft.set("theme", "accent", "#8ec07c");
weft.set("theme", "cursor", "#fabd2f");
weft.set("theme", "selection", "#3c4a5e");

weft.echo("weft: config.js loaded");

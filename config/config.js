// config.js — the sample user config, run in quickjs.wasm (plan 06B). This is
// the local plane: the reborn init.fnl, now JavaScript. It reaches the editor
// ONLY through the `weft.*` surface the sandbox grants — the same door a plugin
// uses, no core privilege. weft ships modeless; this config brings up the
// reference catalog itself, so the dev entry point needs no --plugin flags.
//
// Available:
//   weft.plugin(name)              — load a reference plugin (or a .wasm path)
//   weft.bind(mode, key, command)  — bind a key in a keymap mode
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

// Leader (space) bindings for the edit-domain operators — each name is a real
// command one of the plugins above registered.
weft.bind("normal", "space d", "duplicate-line");
weft.bind("normal", "space u", "upcase-line");
weft.bind("normal", "space c", "comment-line");
weft.bind("normal", "space w", "trim-trailing-line");

// Tree-sitter structural selection.
weft.bind("normal", "space l", "consult-line");
weft.bind("normal", "space s", "consult-imenu");
weft.bind("normal", "space n", "ts-select-node");
weft.bind("normal", "space e", "ts-expand-selection");
weft.bind("normal", "space F", "ts-select-function");

// Git (in vim's leader mode: space g → status). More via the palette.
weft.bind("leader", "g", "git-status");

// Numbers: vim-style increment/decrement.
weft.bind("normal", "C-a", "increment-number");
weft.bind("normal", "C-x", "decrement-number");

// Auto-close pairs while typing (insert mode).
weft.bind("insert", "parenleft", "pair-paren");
weft.bind("insert", "braceleft", "pair-brace");
weft.bind("insert", "bracketleft", "pair-bracket");
weft.bind("insert", "quotedbl", "pair-quote");

weft.echo("weft: config.js loaded");

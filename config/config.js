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
weft.plugin("vim");         // modal editing — the default keymap

// Leader (space) bindings for the edit-domain operators — each name is a real
// command one of the plugins above registered.
weft.bind("normal", "space d", "duplicate-line");
weft.bind("normal", "space u", "upcase-line");

weft.echo("weft: config.js loaded");

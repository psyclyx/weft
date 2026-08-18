// config.js — the sample user config, run in quickjs.wasm (plan 06B). This is
// the local plane: the reborn init.fnl, now JavaScript. It reaches the editor
// ONLY through the `weft.*` surface the sandbox grants — the same door a Zig
// config plugin uses, no core privilege. The std keymap (the `vim` catalog
// plugin) is already loaded; here a user layers their own bindings on top.
//
// Available:
//   weft.bind(mode, key, command)  — bind a key in a keymap mode
//   weft.run(command)              — invoke a command now (startup actions)
//   weft.echo(message)             — a transient status-line message
//   weft.log(message)              — a line to the editor log

// Leader (space) bindings for the edit-domain operators (the `edit` plugin)
// and a couple of catalog commands — each name is a real registered command.
weft.bind("normal", "space d", "duplicate-line");
weft.bind("normal", "space u", "upcase-line");
weft.bind("normal", "space j", "join-lines");
weft.bind("normal", "space f", "find-file");

weft.echo("weft: config.js loaded");

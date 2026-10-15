// code.js — what source offers to do with itself — a config FRAGMENT
// (`weft.use("code")`). Run, test, debug, format and rename, each an ACTION
// with a provider per context: the toolbar's buttons, mouse-3's menu, the
// palette and the Run/Edit menus list them, and a config's keys bind the same
// names (ide.js binds F2, C-S-b and M-S-f to them). No keys here, so any
// grammar can use it.

// Spelled as intentions (`plugin.code.*`, as every config spells them), not
// flat names: an intention is an OFFER, so the same word a key binds is what the
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
provideLocal("plugin.code.run", { lang: "go" }, "modes.run", { label: "Run", group: "run", order: 1 });
weft.action("plugin.code.test");
provideLocal("plugin.code.test", { lang: "zig" }, "make.test", { label: "Test", group: "build", order: 2 });
weft.action("plugin.code.debug");
provideLocal("plugin.code.debug", { lang: "zig" }, "dap.start", { label: "Debug", group: "build", order: 3 });
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


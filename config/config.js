// config.js — weft's reference configuration, and the showcase: read it top
// to bottom to learn what the editor can do. Every claim below is held honest
// by the e2e gates (src/e2e/config_test.zig) — a key that names a command
// nobody registers, a plugin the bundle lost, a grant that admits more than
// it declares, all fail the build.
//
// It runs in quickjs.wasm and reaches the editor ONLY through the `weft.*`
// surface — the same door a plugin uses, no core privilege. Evaluation is
// SEALED: nothing here pokes a live editor. The file evaluates to a MANIFEST
// the kernel applies as one value, so load ORDER below is for the reader, not
// for the machine.
//
// Siblings: helix.js is the same editor under Helix's grammar; ide.js is the
// conventional, mouse-and-keyboard, non-modal flow.
//
// The whole config plane:
//   weft.plugin(name)              — load a reference plugin (or a .wasm/.js path)
//   weft.use(name)                 — import a config fragment from this directory
//   weft.grant(who, cap[, {root}]) — delegate an effect; without one, closed
//   weft.bind(mode, keys, cmd)     — bind a key or a key SEQUENCE ("SPC f f");
//                                    a LIST is an authored fallback, tried in order
//   weft.group(mode, prefix, name) — name an implicit chord group in which-key
//   weft.action(name)              — declare an abstract intent a key can bind to
//   weft.provide(name, when, cmd[, prio]) — a provider for one, chosen by
//                                    {mode, lang} at fire time
//   weft.semanticAction(name)      — declare an open focused-view action command
//   weft.command(id, {label, summary, menu, group, order, icon, prompts,
//                     toggle, internal}) — describe how a command is presented
//                                    (palette, which-key, menus); wins over what
//                                    its plugin declared
//   weft.viewport(name, attrs)     — compose the workspace: a pane's attributes
//                                    {edge, extent (a share, or {rows}), cycles,
//                                    persistent, followFocus, takesFocus, statusLine}
//   weft.present(viewport, {subject, as, reveal}) — show a designation, or the
//                                    value of ONE context key ({context: "place"}),
//                                    as a projection, revealing one inside it
//   weft.set(owner, key, value)    — a value binding; every key has an OWNER
//   weft.menu(name)                — declare a prefix-menu keymap mode
//   weft.statusSegment(text, role, prio[, cmd]) — a static status-line segment; a click runs cmd
//   weft.run(command, ...args)     — invoke a command now, up to eight string args
//   weft.echo(message) / weft.log(message)

// ── The plugins ──────────────────────────────────────────────────────
// Reference plugins, each sandboxed under wasmtime behind the perm handshake.
// weft ships modeless; this config brings up the plugins itself, so the dev
// entry point needs no --plugin flags.
weft.plugin("edit");        // line operators: duplicate-line, upcase-line, …
weft.plugin("complete");    // buffer-word completion provider
weft.plugin("project");     // recent files, project history
weft.plugin("dashboard");   // structured welcome view
weft.plugin("structural");  // tree-sitter node ops
weft.plugin("region");      // subbuffer regions
weft.plugin("shell");       // insert shell-command output
weft.plugin("palette");     // "std" UI: command/buffer palette, status line
weft.plugin("motions");     // word/WORD/line/doc motions — each returns a range
weft.plugin("textobjects"); // iw/i"/i(/ip … — each returns a range
weft.plugin("operators");   // op.delete/upcase/lowercase — await a range
weft.plugin("surround");    // add/delete/replace a delimiter pair — operators too
weft.plugin("vim");         // modal editing — composes motions + textobjects + operators
weft.plugin("ts");          // tree-sitter navigation: expand-selection, select-function
weft.set("languages", "query-root", "assets");
weft.plugin("languages.js"); // parser packages + explicit query paths
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
weft.plugin("http");        // HTTP/1.0 over that transport — built in the guest, never native
weft.plugin("which_key");   // menu-hint overlay, as a plugin over the surface door
weft.plugin("files");       // file browser; the target handler owns its semantic scene/actions
weft.plugin("lsp");         // language server client (hover/def/… over jsonrpc)
weft.plugin("debug");       // breakpoints (gutter markers) — the debugger's first slice
weft.plugin("marginalia");  // pick-row annotations (size/age, dirty/lang, the key that runs it)
weft.plugin("linenumbers"); // a line-number gutter on text entries (never on git, files, …)
weft.plugin("snipe");       // evil-snipe: s/S two-char, f/F/t/T one-char, highlighted
weft.plugin("offers");      // what a context offers, as a strip, a list or mouse-3's menu
weft.plugin("panel");       // panel-toggle: the bottom panel (config/panel.js) on and off
weft.plugin("problems");    // every diagnostic in one list, in the panel (SPC o p)
weft.plugin("terminal");    // a LINE-MODE shell in the panel (SPC o t) — no terminal emulation
weft.plugin("breadcrumbs"); // path › symbol › symbol for the caret, on the status line

// ── BREADTH, written down ────────────────────────────────────────────
// A plugin that asks for `fs_read`/`fs_write` in describe() and gets no
// grant here is confined to THE PLACE ITS DISPATCH IS IN — the project the
// focused file belongs to, resolved per call, following you from one project
// to the next. That is the default because the alternative default was "the
// whole filesystem", which is not something anyone should get by omission.
// `notes` and `snippets` run on exactly that: their files are named relative
// to the place, so a notes file is per-project without a line here.
//
// `root: "/"` is how you say UNCONFINED. It is not forbidden — it is just
// something you have to write, so it shows up in the approval diff.
//
// The file browser is the one reference plugin that genuinely means it: you
// point it at a directory and it goes there, including out of the project
// entirely. Its typed target doors need the unconfined form specifically —
// they prove authority against a provider root rather than a path, so there
// is nothing for a path-shaped confinement to compare against. Narrow these
// to a `root:` and the browser refuses to leave it.
weft.grant("files", "fs_read",  { root: "/" }); // browse anywhere you point it
weft.grant("files", "fs_write", { root: "/" }); // …and act there: rename, delete, create

// ── `.js` plugins and their GRANTS ───────────────────────────────────
// A `.js` plugin has no describe() handshake to ask for anything, so
// `weft.grant` is its ONLY door to an effect: with no grant it fails CLOSED
// and every weft.procSpawn / weft.fileRead call throws at the call site.
// Grants mint before any plugin loads, so each pair below reads as one
// thought: what it may do, then what it is.
//
// A grant may also be NARROWED — `weft.grant("dap", "fs_read", {root:
// "./src"})` confines the capability to a filesystem root — or widened to
// the whole machine with `{root: "/"}`, above.
weft.grant("dap", "proc");  // drive a debug adapter over stdio
weft.plugin("dap.js");      // DAP client: run/step/inspect (see weft.set("dap", …) below)

// The ACP agent client. weft is the harness: the agent's file I/O and tool
// approvals cross the ABI, so every agent edit is a gated, attributed peer
// commit. These three lines ARE the agent's authority — delete one and that
// door closes for good.
// The two fs grants carry no `root`, so the agent reads and writes inside
// the place the conversation dispatches in — its project, and not yours.
weft.grant("acp", "proc");     // spawn + drive the agent over stdio
weft.grant("acp", "fs_read");  // answer its fs/read_text_file
weft.grant("acp", "fs_write"); // answer its fs/write_text_file
weft.plugin("acp.js");         // conversations are instances: *agent*, *agent:2*, …

// ── Fragments ────────────────────────────────────────────────────────
// A fragment is an ordinary config file in this directory, imported as a
// manifest. `defaults` holds the editor-agnostic picker/which-key bindings
// core would otherwise have to carry as key policy; anything bound after it
// wins.
weft.use("defaults");

// `sidebar` docks a files browser at the left edge. "Sidebar" is not a kind
// the workspace knows — it is a named bundle of viewport ATTRIBUTES (dock
// edge, out of the cycling rotation, owns its entry, not a focus source) plus
// one `weft.present` line. Read config/sidebar.js: there is no window
// management code in it anywhere, and slotting in document symbols instead of
// files would be a different `weft.present`, not a different plugin.
// Left to you rather than made the default: a docked companion claims a
// quarter of every frame, which is a workspace opinion the reference config
// declines to hold for you.
// weft.use("sidebar");
// The same goes for a menubar (config/menubar.js): File, Edit, … with the
// key that runs each row in vim beside it (`SPC f S` for Save As…). The
// palette (SPC :) and which-key are this config's discovery surfaces; one
// line adds the bar (with menus.js, where core's commands sit in it), and F10
// or Alt with a title's letter opens it.
// weft.use("menus"); weft.use("menubar");

// `panel` docks a bottom panel that starts hidden: the problems list and the
// terminal each bring themselves into it (SPC o p, SPC o t), one at a time.
weft.use("panel");

// ── Values: weft.set(owner, key, value) ──────────────────────────────
// Every value has an OWNER — the plugin (or core namespace) that reads it.
// There is no grab-bag namespace; an unknown owner is refused, not stored.
weft.set("lsp", "zig", "zls");            // a server per language: weft.set("lsp","<lang>","<cmd>")
weft.set("which_key", "delay-ms", "200"); // hold a prefix this long before the hint pops
weft.set("which_key", "placement", "corner"); // or "center"
weft.set("editor", "flash-ms", "150");    // how long an operator flashes its range
weft.set("editor", "flash-undo", "on");   // undo/redo flash what they put back, too
// "relative": distance from the caret, with the caret line's own number —
// vim's `number relativenumber`. Or "absolute".
weft.set("linenumbers", "style", "relative");
// Snipe is evil-snipe, set the way Doom Emacs sets it (modules/editor/evil
// config.el): smart case, a snipe looks along the rest of the line, and `;`/`,`
// repeat over what is visible. (Doom's `char-fold` has no weft equivalent.)
// An operator-pending snipe (`d z a b`, `c t )`) hands its range to vim's
// pending operator, and `3sab` reads vim's typed count.
weft.set("snipe", "operator", "vim.operate");
weft.set("snipe", "count", "vim.count-take");
weft.set("snipe", "smart-case", "on");
weft.set("snipe", "scope", "line");
weft.set("snipe", "repeat-scope", "visible");
weft.set("editor", "font-size", "16");     // startup text size; C-+/C-- adjust, C-0 resets
// Each section gives an id, title, candidate-source command, activation
// command, and maximum count. Source commands return newline-delimited lists.
weft.set("dashboard", "sections", [
  "start\tStart\t\t\t0",
  "files\tRecent files\tproject.recent\tfile.open\t5",
  "projects\tProjects\tproject.recent-roots\tfile.open\t4",
]);
weft.set("dashboard", "items", [
  "start\tOpen file\tfiles.find",
  "start\tNew buffer\tbuffer.scratch",
]);
weft.set("collab", "collab.share-presence", "on"); // "off" hides your caret from peers
// The palette's argument behaviour. A command with parameters can be run two
// ways: type them next to the name (`listen 7777 edit` — the palette accepts
// typed text, not only a listed row), or pick the row and be ASKED for each
// one in turn. "off" refuses instead of asking, echoing the command's shape
// so you can retype the whole call.
weft.set("palette", "arguments", "ask");    // or "off"
weft.set("palette", "signature", "on");     // show each row's <parameters>
// Yours to fill in — weft assumes nothing about how any of these is installed:
// weft.set("acp", "cmd", "codex-acp"); // or claude-agent-acp, gemini --experimental-acp, …
// weft.set("acp", "prompt", "Summarize this project."); // the opening turn
// weft.set("dap", "cmd", "lldb-dap");  // your debug adapter
// weft.set("llm", "cmd", "llm");       // the CLI `SPC o a` asks
// One more value-shaped verb, for when you want a fixed chip in the status
// line (the UI mesh's `ui/statusline-seg` slot, at config priority):
// weft.statusSegment("weft", "muted", 10);

// ── Keys ─────────────────────────────────────────────────────────────
//
// Doom-Emacs-style leader (SPC). A menu is a prefix KEY SEQUENCE, not a mode:
// `space` is just the first key of chords like `space f f`. The keymap holds
// the chord pending as you type it (which_key shows the next-key completions
// off the pending prefix) and runs the leaf when the sequence completes. No
// `weft.menu`, no mode to enter — `space g g` never touches a `leader-git`
// mode, it's one key sequence bound in `normal`. `space C-w` is inert (a
// distinct chord), so the global window prefix (`C-w …`) can't be reached
// through the leader.
//
// INTENTIONS vs COMMANDS. A key may name a `std.*` intention instead of a
// command: the focused view's own vocabulary publishes the offer that answers
// it, so one key means the right thing in a directory, a git buffer, and a
// note. Input GRAMMARS own most of that — vim binds Return, `-`, `u` and
// `C-r` to intentions with a text fallback, and Tab and `q` to intentions
// outright; rebinding any of them here would be overriding the grammar, not
// configuring it. What belongs at THIS tier is the small set below, where the
// intention is the config author's choice: the structured-view group (SPC v),
// persistence, and going back.

weft.bind("global", "F1", "which-key.show"); // force the hint now, mid-chord
// The pointer's secondary button presents what the thing under it offers
// (`weft://here/offers/at-pointer`) as a menu — a row, the text, a git hunk —
// in any mode, vim's included: the menu's own keys (Up/Down/Return/Escape)
// are its interaction's, not a mode.
weft.bind("global", "mouse-3", "offers.menu");
// …and S-F10 or the Menu key the focused context's, at the caret.
weft.bind("global", "S-F10", "offers.menu-at-caret");
weft.bind("global", "Menu", "offers.menu-at-caret");

// The keymap derives groups from longer chords. Give those prefixes names for
// which-key; an unnamed prefix intentionally falls back to "+prefix".
weft.group("normal", "SPC", "Workspace");
weft.group("normal", "SPC f", "Find & save");
weft.group("normal", "SPC b", "Switch & close buffers");
weft.group("normal", "SPC g", "Version control");
weft.group("normal", "SPC s", "Search & jump");
weft.group("normal", "SPC p", "Project navigation");
weft.group("normal-source", "SPC c", "Edit & inspect code");
weft.group("normal", "SPC o", "External tools");
weft.group("normal", "SPC a", "Coding agents");
weft.group("normal", "SPC d", "Debug session");
weft.group("normal", "SPC n", "Notes & embeds");
weft.group("normal", "SPC C", "Share & connect");
weft.group("normal", "SPC w", "Split & focus windows");
weft.group("normal", "SPC q", "Quit editor");
weft.group("normal", "SPC h", "Help & permissions");
weft.group("normal", "SPC t", "Text toggles");

// Top-level leader: quick actions (the group prefixes below are implied by the
// longer sequences — `space f …` makes `space f` a group automatically).
weft.bind("normal", "SPC SPC", "files.find");   // SPC SPC — find file
weft.bind("normal", "SPC :", "palette.open"); // SPC :   — M-x (run a command)
weft.bind("normal", "SPC .", "files.find");     // SPC .   — find file
weft.bind("normal", "SPC ,", "buffer.pick");      // SPC ,   — switch buffer

// SPC f — files. `f s` asks for the persistence INTENTION and falls back to
// the plain command: in a *git-commit* buffer that commits, in a note it
// saves.
weft.bind("normal", "SPC f f", "files.find");
weft.bind("normal", "SPC f s", ["std.persistence.save", "file.save"]);
weft.bind("normal", "SPC f S", "file.save-as");
weft.bind("normal", "SPC f r", "project.recent");
weft.bind("normal", "SPC f d", "files.browse");

// SPC b — buffers
weft.bind("normal", "SPC b b", "buffer.pick");
weft.bind("normal", "SPC b d", "buffer.close");
weft.bind("normal", "SPC b D", "buffer.close-force"); // explicitly discard unsaved edits
weft.bind("normal", "SPC b n", "buffer.next");
weft.bind("normal", "SPC b N", "buffer.scratch");

// SPC g — git. `git-status` opens the *git* model buffer, which runs its own
// `git` keymap: j/k move, TAB folds, s/u stage/unstage (file/hunk/region),
// S/U stage-all, g refresh, RET visits a file (or shows a commit), q leaves.
// The transients (which-key renders each menu mode):
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
weft.bind("normal", "SPC g g", "git.status");
weft.bind("normal", "SPC g i", "git.init"); // start version control from the editor
weft.bind("normal", "SPC g l", "git.log");
weft.bind("normal", "SPC g d", "git.diff");
weft.bind("normal", "SPC g D", "git.diff-staged");
weft.bind("normal-source", "SPC g b", "git.blame");

// `.` — repeat the last change (vim dot-repeat). The recorder is core (it
// records keystrokes through the one dispatch path), so it repeats a change made
// by ANY plugin — vim operators, autopair, comment, structural — not just vim's.
weft.bind("normal", ".", "edit.repeat");

// `/` — search in this buffer (vim's search key). consult-line is a fuzzy
// in-buffer jump: type a pattern, Return lands on the match.
weft.bind("normal", "/", "consult.line");

// Snipe, bound the way Doom binds evil-snipe (both of its modes on):
//   s S       — two-character snipe forward/back (vim's substitute `s`/`S` go),
//               in visual too
//   z Z / x X — the same after an operator, through / up to the match
//               (`d z a b` deletes through "ab", `d x a b` up to it)
//   f F t T   — one-character snipes: vim's find, but highlighted and
//               repeatable by pressing the key again
//   ; ,       — repeat the last snipe, same way / reversed
// Vim's own `vim.find-*-char` commands stay registered, just unbound here.
for (const [key, snipe] of [["s", "pair-next"], ["S", "pair-prev"],
                            ["f", "char-next"], ["F", "char-prev"],
                            ["t", "till-char-next"], ["T", "till-char-prev"]]) {
  weft.bind("normal", key, `snipe.${snipe}`);
}
weft.bind("visual", "s", "snipe.pair-next");
weft.bind("visual", "S", "snipe.pair-prev");
for (const [key, snipe] of [["z", "pair-next"], ["Z", "pair-prev"],
                            ["x", "till-pair-next"], ["X", "till-pair-prev"],
                            ["f", "char-next"], ["F", "char-prev"],
                            ["t", "till-char-next"], ["T", "till-char-prev"]]) {
  weft.bind("op-pending", key, `snipe.operate-${snipe}`);
}
weft.bind("normal", ";", "snipe.repeat");
weft.bind("normal", ",", "snipe.repeat-reversed");
weft.bind("op-pending", ";", "snipe.operate-repeat");
weft.bind("op-pending", ",", "snipe.operate-repeat-reversed");

// `C-o` / `C-i` — vim's jumplist. The intention first: a focused view that
// knows its own history answers it; otherwise the head's jumplist does, which
// core fills on every move between entries and vim fills on `G`, `gg`, `%`.
// `q` in a tool is a different verb (leave it) and stays `buffer.back`.
weft.bind("normal", "C-o", ["std.navigation.back", "jump.back"]);
weft.bind("normal", "C-i", "jump.forward");
weft.bind("normal", "SPC s j", "jump.pick");

// `q<reg>` / `@<reg>` / `@@` — macros are vim's (it binds them); the recorder
// is core, so a macro replays through every plugin a typed key reaches.
// `"+` / `"*` — the system clipboard as a vim register. Reading it reads
// whatever you last copied anywhere, so it is a grant, and only config can
// give it.
weft.grant("vim", "clipboard");

// SPC s — search
weft.bind("normal", "SPC s s", "consult.line");
weft.bind("normal-source", "SPC s i", "consult.imenu");
weft.bind("normal", "SPC s p", "grep.search");
weft.bind("normal", "SPC s w", "grep.search-word");

// SPC p — project
weft.bind("normal", "SPC p p", "project.recent");
weft.bind("normal", "SPC p f", "files.find");
weft.bind("normal", "SPC p R", "project.show-root"); // echo the VCS root (projectile-style)
weft.bind("normal", "SPC p /", "grep.search");

// SPC c — code
weft.bind("normal-source", "SPC c c", "comment.toggle-line");
weft.bind("normal-source", "SPC c f", "plugin.code.format"); // the format action (below)
weft.bind("normal-source", "SPC c d", "lsp.goto-definition");
weft.bind("normal-source", "SPC c h", "lsp.hover");
weft.bind("normal-source", "SPC c s", "lsp.pick-symbol");
weft.bind("normal-source", "SPC c F", "lsp.format"); // format via the language server
weft.bind("normal-source", "SPC c R", "lsp.references");
weft.bind("normal-source", "g r", "lsp.references"); // vim-style
weft.bind("normal-source", "g R", "lsp.rename");     // rename the symbol under the cursor
weft.bind("normal-source", "SPC c k", "lsp.signature-help");
weft.bind("normal-source", "SPC c i", "lsp.toggle-inlay-hints");
weft.bind("normal-source", "SPC c a", "lsp.code-actions");
weft.bind("normal-source", "] d", "lsp.next-diagnostic"); // vim-style diagnostic navigation
weft.bind("normal-source", "[ d", "lsp.prev-diagnostic");
weft.bind("normal-source", "K", "lsp.hover");        // vim-style: K shows hover
weft.bind("normal-source", "SPC c e", "ts.expand-selection");
weft.bind("normal-source", "SPC c n", "ts.select-node");
weft.bind("normal-source", "SPC c b", "make.build");
weft.bind("normal-source", "SPC c t", "make.test");
weft.bind("normal-source", "SPC c r", "modes.run");
weft.bind("normal-source", "SPC c x", "run.line");

// Completion — trigger the at-caret popup (buffer-word + LSP race + merge-rank).
// C-SPC from insert (where you're typing) and normal (browse from rest).
weft.bind("insert", "C-SPC", "complete.show");
weft.bind("normal", "C-SPC", "complete.show");

// ── Actions: abstract intents resolved by CONTEXT ────────────────────
// The dispatch middle tier. weft.action(name) declares an intent a key binds
// to; weft.provide(name, when, cmd[, prio]) registers a provider chosen by
// {mode, lang} when it fires. Bind the key ONCE — a .zig buffer and a shell
// script run different commands, and any language plugin can weft.provide a
// new provider without touching this keymap. `eval` unifies the SPC-c r/x
// split (lang-run vs run-line) into one language-aware key; a buffer with no
// provider echoes "no eval provider here". `:action.explain eval` says which
// provider wins here and why.
weft.action("plugin.code.run");
weft.provide("plugin.code.run", {}, "run.line");                 // default: run the current line
weft.provide("plugin.code.run", { lang: "zig" }, "make.build");  // a .zig buffer builds the project
weft.provide("plugin.code.run", { lang: "py" }, "modes.run");     // python: the language runner
weft.bind("normal-source", "SPC e", "plugin.code.run");          // SPC e — eval/run, by language

// format is likewise an action: fmt handles most languages by extension, but a
// language plugin can weft.provide("plugin.code.format", {lang:"…"}, "…") to override.
weft.action("plugin.code.format");
weft.provide("plugin.code.format", {}, "fmt.format-buffer");

// ── SPC o — tools, and the INSTANCING surface ────────────────────────
// A tool that holds state is instantiable: each start mints its own buffer
// (`*repl*`, `*repl:2*`, …) and that NAME is the instance's identity, so two
// instances never share a sink. A send routes to the instance whose buffer is
// focused, else the most recent — never to "the current one". Lowercase
// starts an instance here; uppercase talks to the focused one.
weft.bind("normal", "SPC o d", "files.browse");
weft.bind("normal", "SPC o e", "direnv.status");
weft.bind("normal", "SPC o r", "repl.start");
weft.bind("normal", "SPC o R", "repl.send-line");
weft.bind("normal", "SPC o q", "repl.quit");
weft.bind("normal", "SPC o c", "console.open");
weft.bind("normal", "SPC o C", "console.send");
weft.bind("normal", "SPC o a", "llm.ask-line"); // one-shot: each ask is its own instance
weft.bind("normal", "SPC o h", "http.get");     // fetch a URL into its own *http* buffer
weft.bind("normal", "SPC o p", "problems.open");     // the diagnostics list, in the bottom panel
weft.bind("normal", "SPC o t", "terminal.open");     // the shell, in the bottom panel
weft.bind("normal", "SPC o P", "panel.toggle"); // hide or show whichever the panel holds

// SPC a — coding agents (ACP). Each `agent.start` is a fresh conversation:
// its own subprocess, transcript buffer and CRDT sub-peer, so selective undo
// separates one agent's edits from another's. Set weft.set("acp", "cmd", …)
// above first; the launch command is yours, weft assumes nothing.
weft.bind("normal", "SPC a a", "agent.start");
weft.bind("normal", "SPC a s", "agent.send");  // send this line to the focused conversation
weft.bind("normal", "SPC a f", "agent.focus"); // choose which conversation that is

// SPC d — debug. Breakpoints are gutter markers the debug plugin owns;
// run/step/inspect are the DAP session (dap.js) over the adapter you named.
// F5/F9/F10/F11 are the IDE conventions; the SPC d leaves mirror them.
weft.bind("normal-source", "SPC d b", "debug.toggle-breakpoint");
weft.bind("normal", "SPC d c", "debug.clear-breakpoints");
weft.bind("normal", "SPC d l", "debug.list-breakpoints");
weft.bind("normal", "SPC d d", "debug.start");
weft.bind("normal", "SPC d r", "debug.continue");
weft.bind("normal", "SPC d n", "debug.step-over");
weft.bind("normal", "SPC d i", "debug.step-into");
weft.bind("normal", "SPC d o", "debug.step-out");
weft.bind("normal", "SPC d q", "debug.stop");
weft.bind("normal", "F5", "debug.continue");
weft.bind("normal-source", "F9", "debug.toggle-breakpoint");
weft.bind("normal", "F10", "debug.step-over");
weft.bind("normal", "F11", "debug.step-into");

// ── SPC n — notes and EMBEDS ─────────────────────────────────────────
// `notes.capture` appends the current line to the notes file; `notes-capture-
// here` appends a link to where you are, as an embed line:
//
//     @embed weft://here/file/src/core/Head.zig?at=1024
//
// That text is both the storage form and the fallback form. `notes.show-embeds`
// resolves every embed in the focused note and renders each live beside its
// own bytes; one that cannot resolve (no grant, gone, no provider) shows its
// reason instead and never errors the note. Return on an embed line opens
// what it designates — the same `std.target.activate` as everywhere else.
weft.bind("normal", "SPC n n", "notes.open");
weft.bind("normal", "SPC n c", "notes.capture");
weft.bind("normal", "SPC n h", "notes.capture-here");
weft.bind("normal", "SPC n e", "notes.show-embeds");
weft.bind("normal", "SPC n E", "notes.hide-embeds");

// ── SPC C — collaboration ────────────────────────────────────────────
// `share` announces the active buffer to every peer. With a PRESET it also
// selects the authority that goes with it — `:share look_together` (read
// along), `:share pair` (edit together), `:share review` (comment) — and the
// confirmation you read is rendered FROM the bundle, so the text approved and
// the authority selected are the same value. Presets and export selections
// take an argument, so they ride the `:` line:
//
//     :share pair              :share-presence off      :share-fs read
//     :listen 7000 edit        :connect host:7000       :grant <fp> edit
//
// `collab.share-fs` selects which surfaces of a `--share-root` peers hold
// (hierarchy | bytes | write, or none/read/rw). Presence is separate from
// sharing a document: it defaults on (see weft.set("collab", …) above) and
// `off` retracts the caret peers are already rendering.
//
// Those same argument-taking verbs are equally reachable from the PALETTE
// now: pick `listen` and it asks for the port, then the access grade. Nothing
// here is `:`-only — the `:` line is just the way to say the whole call at
// once. A session end to end, host then peer:
//
//     :listen 7000 edit         host: accept peers, let them write
//     :connect host:7000        peer: join (matching --token both sides)
//     SPC C p                   compare fingerprints + SAS out of band
//     :verify-peer <fp>         · once they match
//     SPC C s                   host: announce ANOTHER buffer
//     SPC C o                   peer: open a buffer a peer announced
//
// The buffer that was active when `listen` began is already the shared one;
// `share` there answers "already shared" rather than doing it twice.
weft.bind("normal", "SPC C s", "collab.share");
weft.bind("normal", "SPC C o", "collab.open-shared"); // open a buffer a peer shared
weft.bind("normal", "SPC C f", "collab.peer-files");  // browse the peer's shared root
weft.bind("normal", "SPC C p", "collab.peers");       // fingerprints, SAS words, trust
weft.bind("normal", "SPC C l", "collab.listen");      // asks: port, then access grade
weft.bind("normal", "SPC C c", "collab.connect");     // asks: host:port
weft.bind("normal", "SPC C x", "collab.disconnect");

// SPC w — window. Split/close via the windows plugin; focus + move go
// straight to the core window-layout commands (a real recursive split
// tree), so h/j/k/l walk panes and H/J/K/L swap them, vim-style. The sidebar
// is out of the cycling rotation by declaration, so directional focus is how
// you reach it.
weft.bind("normal", "SPC w v", "window.split-right");
weft.bind("normal", "SPC w s", "window.split-below");
weft.bind("normal", "SPC w w", "window.focus-next");
weft.bind("normal", "SPC w c", "scroll.center-line");
weft.bind("normal", "SPC w o", "window.close");
weft.bind("normal", "SPC w q", "window.close");
weft.bind("normal", "SPC w h", "window.focus-left");
weft.bind("normal", "SPC w j", "window.focus-down");
weft.bind("normal", "SPC w k", "window.focus-up");
weft.bind("normal", "SPC w l", "window.focus-right");
weft.bind("normal", "SPC w H", "window.move-left");
weft.bind("normal", "SPC w J", "window.move-down");
weft.bind("normal", "SPC w K", "window.move-up");
weft.bind("normal", "SPC w L", "window.move-right");

// SPC q — quit
weft.bind("normal", "SPC q q", "app.quit");

// SPC h — help. The palette lists commands AND the live offers the focused
// entry publishes, each attributed to its provider, so it doubles as "what
// can I do here". `grants.show` lists every authority row this session ever
// minted, alive or revoked.
weft.bind("normal", "SPC h h", "palette.open");
weft.bind("normal", "SPC h g", "grants.show");

// SPC t — toggle
weft.bind("normal", "SPC t w", "whitespace.trim-buffer");
weft.bind("normal-source", "SPC t c", "comment.toggle-line");

// ── SPC v — structured views ─────────────────────────────────────────
// The structured-view group lives in a fragment, config/semantic.js, because
// helix.js binds the same group: one table, every grammar's structural layer
// (the mode vim declares `normal` binds through in a listing). Its keys are
// intentions where a standard word names the operation and open action names
// for the residue — read the fragment for both tables.
weft.use("semantic");

// Numbers: vim-style increment/decrement.
weft.bind("normal", "C-a", "numbers.increment");
weft.bind("normal", "C-x", "numbers.decrement");

// Auto-close pairs while typing (insert mode).
weft.bind("insert", "parenleft", "autopair.open-paren");
weft.bind("insert", "braceleft", "autopair.open-brace");
weft.bind("insert", "bracketleft", "autopair.open-bracket");
weft.bind("insert", "quotedbl", "autopair.quote-double");
weft.bind("insert", "apostrophe", "autopair.quote-single"); // ' pairs, except in lisps (a quote)
// Type-over: typing the closing delimiter steps over an auto-inserted one, so
// typing balanced `f(x)` stays `f(x)` instead of `f(x))`.
weft.bind("insert", "parenright", "autopair.close-paren");
weft.bind("insert", "braceright", "autopair.close-brace");
weft.bind("insert", "bracketright", "autopair.close-bracket");

// ── Theme ────────────────────────────────────────────────────────────
// TWO FAMILIES, and the namespace says which. `weft.set(ns, key, value)` binds
// the slot `ns/key` — that is the whole rule, and core's config applier knows
// nothing beyond it. Whoever DECLARED the slot reads the value:
//
//   palette/<name>  what a colour IS      — an sRGB hex, read by the renderer
//   theme/<role>    how a ROW ROLE reads  — a style class, read by projection
//
// A whole colorscheme is just a block of the first kind — a fragment you
// weft.use(); the runtime `theme.set-color` command binds the same slot live, at a
// tier that outranks this file.
weft.set("palette", "accent", "#8ec07c");
weft.set("palette", "cursor", "#fabd2f");
weft.set("palette", "selection", "#3c4a5e");
weft.set("palette", "syn_comment", "#7c6f64");
weft.set("palette", "diag_error", "#fb4934");

// A ROW ROLE is themed by its last dotted segment, so one line covers every
// producer that calls its rows the same thing: `git.hunk` and `fs.hunk` are
// both hunks, and neither plugin chose a colour or knew about this file.
// The value is a style CLASS, not a hex — what the row IS, resolved to a
// colour by whichever theme is loaded. Core reads a hunk as `muted`; this
// says a hunk header is worth finding.
weft.set("theme", "hunk", "emphasis");

// How chrome — buttons, tabs, status, menus — looks, from the same family:
// `text` is clean, cell-aligned text with no brackets; `text-icons` adds
// small icons; `widget` draws rounded pills, real tabs and shadowed menus.
// `theme.set-chrome widget` (or `theme.cycle-chrome`) switches it live.
weft.set("theme", "chrome", "text");

weft.echo("weft: config.js loaded");

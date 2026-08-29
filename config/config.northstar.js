// config.northstar.js — config/config.js, re-narrated as the north star.
//
// THE RELATIONSHIP, stated once (config.js says the same at its top):
// config.js is the DAILY DRIVER — the reference configuration a person reads
// and runs. This file is the same SURFACE with the end-state model's
// commentary: what each line means once config evaluates to a sealed manifest
// the kernel reconciles, rather than a script that poked the editor as it
// ran. Not a second config, not a subset — the same declarations, so the
// M3/M4 parity gate (src/e2e/config_test.zig) compares the two as ONE
// surface: same resolved keymap, same action providers, same values, same
// plugin list, same mode structure. A line added to config.js must land here,
// and vice versa; the gate refuses drift.
//
// The forcing-function argument it exists to run (doc/cwa-prior-docs-audit.md
// §5): the degenerate case must stay degenerate. If reproducing today's
// editor required learning systems, scopes, or grant vocabulary, the design
// failed. It does not — see the negative space at the bottom.
//
// What the north-star model changes, in full:
//   1. SEMANTICS (invisible here): every `weft.*` call is a DECLARATION
//      collected into a manifest value; nothing mutates the editor during
//      load, so there is no load order to get wrong.
//   2. A config that never says `weft.system(...)` declares the anonymous
//      DEFAULT system — the degenerate composition. Systems appear only when
//      you want a second one (see the agent-UX note below).
//   3. `weft.plugin(name)` imports that blob's manifest AND accepts its grant
//      bundle IF it comes from the bundled catalog (the first-party trust
//      root). A third-party path takes the explicit form
//        weft.plugin("/path/x.wasm", { grants: { proc: {root: "project"} } })
//      and surfaces in the approval diff.
//   4. `weft.set(owner, key, value)` is a VALUE binding and every key has an
//      OWNER; there is no grab-bag namespace. Theme keys compose per-key at
//      config priority over the core defaults — the same first-wins machinery
//      everything else uses, no new composition mode.

// ── The catalog. Each import merges the plugin's manifest (slots, bindings,
// grants) into this composition; the reconcile engine activates the final
// set, so the ordering of these lines is structurally meaningless.
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
weft.plugin("vim");         // modal editing — owns the normal/insert/visual modes
weft.plugin("ts");          // tree-sitter navigation
weft.plugin("comment");     // toggle line comments (gc operator)
weft.plugin("indent");      // indent/dedent operators (> / <)
weft.plugin("whitespace");  // trim trailing whitespace
weft.plugin("numbers");     // increment/decrement number under cursor
weft.plugin("autopair");    // auto-close ( { [ " in insert mode
weft.plugin("consult");     // fuzzy-jump navigation (consult-line, imenu)
weft.plugin("git");         // grant bundle: proc at project root
weft.plugin("grep");        // grant bundle: proc (rg) at project root
weft.plugin("run");         // grant bundle: proc at project root
weft.plugin("make");        // grant bundle: proc at project root
weft.plugin("notes");       // grant bundle: fs under the notes root
weft.plugin("fmt");         // grant bundle: proc (formatters)
weft.plugin("buffers");
weft.plugin("windows");
weft.plugin("modes");       // language activation — the Predicate client
weft.plugin("snippets");    // grant bundle: fs.read under snippets file
weft.plugin("direnv");      // grant bundle: proc + runtime escalation on .envrc change
weft.plugin("llm");         // grant bundle: proc + fs.read
weft.plugin("console");     // grant bundle: proc
weft.plugin("repl");        // grant bundle: proc (persistent subprocess)
weft.plugin("net");         // grant bundle: net
weft.plugin("which_key");   // menu-hint overlay over the surface door
// An fs capability nobody narrows is confined to the dispatching place, so
// `notes`/`snippets`/`lsp` above need no grant line at all. The browser is the
// exception that has to say so: `root: "/"` is the written-down spelling of
// unconfined, and its typed target doors accept nothing narrower.
weft.grant("files", "fs_read", { root: "/" });
weft.grant("files", "fs_write", { root: "/" });
weft.plugin("files");       // file browser; the target handler owns its semantic scene/actions
weft.plugin("lsp");         // grant bundle: proc + fs.read
weft.plugin("debug");       // breakpoints (gutter markers)

// ── `.js` plugins: no describe() handshake, so a config `weft.grant` is the
// only door to an effect, and without one they fail closed. These GrantDecls
// are manifest data too — they are exactly what an approval diff would show,
// and what `explain()` answers "by whose authority" with.
weft.grant("dap", "proc");
weft.plugin("dap.js");      // grant bundle: proc (adapter)

weft.grant("acp", "proc");
weft.grant("acp", "fs_read");
weft.grant("acp", "fs_write");
weft.plugin("acp.js");      // grant bundle: proc + fs (the agent harness)

// ── Fragments — manifest IMPORTS, one tier below this file's own tier.
weft.use("defaults"); // shared editor-agnostic bindings
// A "sidebar" is a named bundle of viewport ATTRIBUTES plus a present
// declaration — systems-as-manifests arriving concretely. No kernel ontology
// knows the word, which is the whole of D1. Opt-in, as in config.js:
// weft.use("sidebar");

// ── Values. Every key has an owner; the "editor" grab-bag is not a default
// but a DECLARED core namespace, alongside "theme" and "collab".
weft.set("lsp", "zig", "zls");
weft.set("which_key", "delay-ms", "200");     // was: weft.set("editor", "which-key-delay-ms", …)
weft.set("which_key", "placement", "corner");
weft.set("editor", "flash-ms", "150");
weft.set("collab", "share-presence", "on");

// ── Bindings. A bind is a binding declared at the named mode's scope, config
// priority tier — which is what it already meant; it just becomes inspectable
// data. The third argument may be a LIST: an authored first-applicable
// fallback carried whole to dispatch, where an INTENTION arm resolves against
// the catalog at fire time and a concrete command runs as itself.
weft.bind("global", "F1", "which-key-now"); // "global" = the workspace-scope key layer

// Doom-style leader (SPC): chords, prefixes as which-key menus.
weft.bind("normal", "SPC SPC", "find-file");
weft.bind("normal", "SPC :", "pick-commands");
weft.bind("normal", "SPC .", "find-file");
weft.bind("normal", "SPC ,", "buf-pick");

// SPC f — files
weft.bind("normal", "SPC f f", "find-file");
weft.bind("normal", "SPC f s", ["std.persistence.save", "save"]);
weft.bind("normal", "SPC f S", "save-as");
weft.bind("normal", "SPC f r", "project-recent");
weft.bind("normal", "SPC f d", "files");

// SPC b — buffers
weft.bind("normal", "SPC b b", "buf-pick");
weft.bind("normal", "SPC b d", "close");
weft.bind("normal", "SPC b k", "close");
weft.bind("normal", "SPC b n", "buffer-next");
weft.bind("normal", "SPC b s", "save");
weft.bind("normal", "SPC b N", "buf-scratch");

// SPC g — git (the git buffer runs its own keymap mode; when its MODEL
// becomes an ObjectDoc, nothing here changes).
weft.bind("normal", "SPC g g", "git-status");
weft.bind("normal", "SPC g i", "git-init");
weft.bind("normal", "SPC g l", "git-log");
weft.bind("normal", "SPC g d", "git-diff");
weft.bind("normal", "SPC g D", "git-diff-staged");
weft.bind("normal", "SPC g b", "git-blame");

weft.bind("normal", ".", "repeat-change");
weft.bind("normal", "/", "consult-line");
weft.bind("normal", "C-o", ["std.navigation.back", "navigate-back"]);

// SPC s — search
weft.bind("normal", "SPC s s", "consult-line");
weft.bind("normal", "SPC s i", "consult-imenu");
weft.bind("normal", "SPC s p", "grep");
weft.bind("normal", "SPC s w", "grep-word");

// SPC p — project
weft.bind("normal", "SPC p p", "project-recent");
weft.bind("normal", "SPC p f", "find-file");
weft.bind("normal", "SPC p r", "project-recent");
weft.bind("normal", "SPC p R", "project-root");
weft.bind("normal", "SPC p /", "grep");

// SPC c — code
weft.bind("normal", "SPC c c", "comment-line");
weft.bind("normal", "SPC c f", "format");
weft.bind("normal", "SPC c d", "goto-definition");
weft.bind("normal", "SPC c h", "hover");
weft.bind("normal", "SPC c s", "symbols");
weft.bind("normal", "SPC c F", "lsp-format");
weft.bind("normal", "SPC c R", "references");
weft.bind("normal", "g r", "references");
weft.bind("normal", "g R", "rename");
weft.bind("normal", "SPC c k", "signature-help");
weft.bind("normal", "SPC c i", "inlay-hints");
weft.bind("normal", "SPC c a", "code-actions");
weft.bind("normal", "] d", "next-diagnostic");
weft.bind("normal", "[ d", "prev-diagnostic");
weft.bind("normal", "K", "hover");
weft.bind("normal", "SPC c e", "ts-expand-selection");
weft.bind("normal", "SPC c n", "ts-select-node");
weft.bind("normal", "SPC c b", "make-build");
weft.bind("normal", "SPC c t", "make-test");
weft.bind("normal", "SPC c r", "lang-run");
weft.bind("normal", "SPC c x", "run-line");

weft.bind("insert", "C-SPC", "complete");
weft.bind("normal", "C-SPC", "complete");

// ── Actions: UNCHANGED SURFACE. `{lang:"zig"}` is sugar for a mode.Predicate
// `{ext:".zig"}` bound at buffer scope — the same meaning it already had, now
// speaking the one matcher everything else uses.
weft.action("eval");
weft.provide("eval", {}, "run-line");
weft.provide("eval", { lang: "zig" }, "make-build");
weft.provide("eval", { lang: "py" }, "lang-run");
weft.bind("normal", "SPC e", "eval");

weft.action("format");
weft.provide("format", {}, "format-buffer");

// SPC o — tools. Each is instantiable: the instance's BUFFER NAME is its
// identity (`*repl*`, `*repl:2*`, …), which is why no command here is keyed
// by "the current one".
weft.bind("normal", "SPC o d", "files");
weft.bind("normal", "SPC o e", "direnv-status");
weft.bind("normal", "SPC o r", "repl-start");
weft.bind("normal", "SPC o R", "repl-send-line");
weft.bind("normal", "SPC o q", "repl-quit");
weft.bind("normal", "SPC o c", "console-open");
weft.bind("normal", "SPC o C", "console-send");
weft.bind("normal", "SPC o a", "llm-ask-line");

// SPC a — coding agents (ACP). Under the north star this is also where a
// SECOND system would first appear:
//   weft.system("agent-ux", (s) => {
//     s.grant("acp", "proc");
//     s.plugin("acp.js");
//     s.bind("normal", "SPC a a", "agent-start");
//   });
// …but reproducing today's editor needs none of it, which is the point. (The
// mechanism is real — config/agent-ux.js is a second manifest hosted in its
// own system; only the `weft.system(...)` sub-DSL is unbuilt.)
weft.bind("normal", "SPC a a", "agent-start");
weft.bind("normal", "SPC a s", "agent-send");
weft.bind("normal", "SPC a f", "agent-focus");

// SPC d — debug
weft.bind("normal", "SPC d b", "debug-toggle-breakpoint");
weft.bind("normal", "SPC d c", "debug-clear-breakpoints");
weft.bind("normal", "SPC d l", "debug-list-breakpoints");
weft.bind("normal", "SPC d d", "debug-start");
weft.bind("normal", "SPC d r", "debug-continue");
weft.bind("normal", "SPC d n", "debug-step-over");
weft.bind("normal", "SPC d i", "debug-step-into");
weft.bind("normal", "SPC d o", "debug-step-out");
weft.bind("normal", "SPC d q", "debug-stop");
weft.bind("normal", "F5", "debug-continue");
weft.bind("normal", "F9", "debug-toggle-breakpoint");
weft.bind("normal", "F10", "debug-step-over");
weft.bind("normal", "F11", "debug-step-into");

// SPC n — notes. An embed line holds a durable, text-serializable designation
// (`@embed weft://here/file/…?at=…`): the storage form and the fallback form
// are one, so an unresolvable embed degrades to its own bytes plus a reason
// rather than erroring its host.
weft.bind("normal", "SPC n n", "notes-open");
weft.bind("normal", "SPC n c", "notes-capture");
weft.bind("normal", "SPC n h", "notes-capture-here");
weft.bind("normal", "SPC n e", "notes-embeds");
weft.bind("normal", "SPC n E", "notes-embeds-off");

// SPC C — collaboration. A share PRESET compiles to a grant bundle, and the
// confirmation is rendered from that bundle: the text approved and the
// authority selected are one value. Argument-taking verbs (`:share pair`,
// `:share-presence off`, `:share-fs read`, `:listen 7000 edit`) ride the `:`
// line, which is the command registry's own door.
weft.bind("normal", "SPC C s", "share");
weft.bind("normal", "SPC C o", "open-shared");
weft.bind("normal", "SPC C f", "peer-files");
weft.bind("normal", "SPC C p", "peers");
weft.bind("normal", "SPC C x", "disconnect");

// SPC w — window
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

// SPC h — help. The palette lists commands and live offers alike; grants-show
// lists every authority row ever minted, alive or revoked — the inspection
// half of approval-as-manifest-diff.
weft.bind("normal", "SPC h c", "pick-commands");
weft.bind("normal", "SPC h h", "pick-commands");
weft.bind("normal", "SPC h g", "grants-show");

// SPC t — toggle
weft.bind("normal", "SPC t w", "trim-trailing-buffer");
weft.bind("normal", "SPC t c", "comment-line");

// SPC v — generic structured-view controls. These address the semantic
// focus/action protocol, so the same bindings work for a directory view, a
// picker, or any other plugin-owned scene that advertises them. Dialog inputs
// remain interaction-local and are intentionally not global bindings.
//
// Eval-time code building manifest data is idiomatic, not a smell: what must
// end up as DATA is what resolution, explain(), and the approval hash read —
// and it does.
function bindActionGroup(mode, prefix, bindings) {
  for (var i = 0; i < bindings.length; i++) {
    var binding = bindings[i];
    weft.semanticAction(binding[1]);
    weft.bind(mode, prefix + " " + binding[0], binding[1]);
  }
}

// Covered by a standard intention: the key binds the intention, and the
// focused view's own vocabulary publishes the offer that answers it.
function bindIntentionGroup(mode, prefix, bindings) {
  for (var i = 0; i < bindings.length; i++) {
    weft.bind(mode, prefix + " " + bindings[i][0], [bindings[i][1]]);
  }
}

weft.bind("normal", "SPC v j", "cursor-down");
weft.bind("normal", "SPC v k", "cursor-up");
bindIntentionGroup("normal", "SPC v", [
  ["o", "std.target.activate"],
  ["-", "std.hierarchy.step-out"],
  ["TAB", "std.hierarchy.toggle-expanded"],
  ["y", "std.transfer.yank"],
  ["x", "std.transfer.delete-to-register"],
  ["p", "std.transfer.paste"],
]);
// The residue: operations no standard intention names yet.
bindActionGroup("normal", "SPC v", [
  ["c", "workspace.set-working-target"],
  ["e", "field.edit"],
  ["d", "selection.delete"],
  ["m", "fs.permissions.edit"],
  ["n", "fs.entry.create-file"],
  ["N", "fs.entry.create-directory"],
  ["P", "selection.paste-before"],
  ["r", "view.refresh"],
  ["R", "view.revert"],
  ["a", "view.apply"],
]);

weft.bind("normal", "C-a", "increment-number");
weft.bind("normal", "C-x", "decrement-number");

// Autopair (insert mode)
weft.bind("insert", "parenleft", "pair-paren");
weft.bind("insert", "braceleft", "pair-brace");
weft.bind("insert", "bracketleft", "pair-bracket");
weft.bind("insert", "quotedbl", "pair-quote");
weft.bind("insert", "apostrophe", "pair-quote-single");
weft.bind("insert", "parenright", "pair-close-paren");
weft.bind("insert", "braceright", "pair-close-brace");
weft.bind("insert", "bracketright", "pair-close-bracket");

// ── Theme: per-key value bindings on the `theme` slot, config priority over
// the core defaults. "A colorscheme is a block of these" now has a precise
// meaning — a manifest fragment you weft.use().
weft.set("theme", "accent", "#8ec07c");
weft.set("theme", "cursor", "#fabd2f");
weft.set("theme", "selection", "#3c4a5e");
weft.set("theme", "syn_comment", "#7c6f64");
weft.set("theme", "diag_error", "#fb4934");

// The one imperative survivor, explicitly a startup-context effect (the
// `startup` transient scope exists exactly for lines like this):
weft.echo("weft: config.js loaded");

// ── What parity did NOT require (the negative space that proves the design):
// no weft.system(), no scopes, no SlotDecls, no Predicate syntax, no manifest
// vocabulary. One namespace fix (`editor` → `which_key`) and one trust
// decision (the bundled catalog's grant bundles) — everything else is the
// same file meaning the same things, now as a value.

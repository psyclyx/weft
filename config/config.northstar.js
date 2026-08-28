// north-star-config.js — the FORCING FUNCTION artifact for doc/cwa-prior-docs-audit.md §5:
// today's editor, byte-for-byte behavior, expressed as a north-star config.
// Companion to config/config.js (the shipping original). The test this file
// exists to run: "the degenerate case must stay degenerate" — if reproducing
// today's editor required learning systems/scopes/grants, the design failed.
//
// What actually changed vs config/config.js, in full:
//   1. SEMANTICS (invisible here): this file EVALUATES TO A MANIFEST — a value
//      the kernel diffs against the live composition (mode.zig reconcile).
//      Nothing below mutates the editor during load; there is no load order.
//      Every `weft.*` call is a declaration collected into the manifest.
//   2. A config that never says `weft.system(...)` declares the anonymous
//      DEFAULT system — the degenerate composition. Systems appear only when
//      you want a second one (see the agent-UX note at the bottom).
//   3. `weft.plugin(name)` = import that blob's manifest AND accept its grant
//      bundle IF it comes from the bundled catalog (the first-party trust
//      root). Third-party paths take the explicit form:
//        weft.plugin("/path/x.wasm", { grants: { proc: {root: "project"} } })
//      and surface in the approval diff. (Today: 5 self-declared booleans,
//      silently trusted, denial = silent no-op. That dies in W0/W4.)
//   4. `weft.set(owner, key, value)` is a VALUE binding and every key has an
//      OWNER. The `"editor"` grab-bag namespace is dissolved — see the one
//      migrated line, flagged below. Theme keys compose per-key at config
//      priority over the core defaults (same first-wins machinery, no new
//      composition mode needed).
//   Everything else — every bind, every action, every provide — is IDENTICAL.

// ── The catalog. Same list, same names. Each import merges the plugin's
// manifest (slots, bindings, grants) into this composition; the reconcile
// engine activates the final set, so the ordering of these lines is
// meaningless (today it is "mostly meaningless"; now it is structurally so).
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
weft.plugin("modes");       // language activation — the W1 Predicate client
weft.plugin("snippets");    // grant bundle: fs.read under snippets file
weft.plugin("direnv");      // grant bundle: proc + runtime escalation on .envrc change
weft.plugin("llm");         // grant bundle: proc + fs.read
weft.plugin("console");     // grant bundle: proc
weft.plugin("repl");        // grant bundle: proc (persistent subprocess)
weft.plugin("net");         // grant bundle: net
weft.plugin("which_key");   // menu-hint overlay over the surface door
weft.plugin("files");       // file browser; the target handler owns its semantic scene/actions
weft.plugin("lsp");         // grant bundle: proc + fs.read
weft.set("lsp", "zig", "zls");
weft.plugin("debug");       // breakpoints (gutter markers)
// A `.js` plugin has no describe() handshake — `weft.grant` is its only door
// to an effect, and without one it fails closed.
weft.grant("dap", "proc");
weft.plugin("dap.js");      // grant bundle: proc (adapter)

// Shared editor-agnostic bindings — a manifest IMPORT, exactly as today.
weft.use("defaults");

// ── MIGRATED LINE (the only semantic edit in the whole file): the "editor"
// grab-bag namespace is gone; every value key needs an owner. The which-key
// idle delay belongs to the which_key plugin:
weft.set("which_key", "delay-ms", "200");    // was: weft.set("editor", "which-key-delay-ms", "200")
weft.bind("global", "F1", "which-key-now");  // "global" = the workspace-scope key layer, as today

// ── BIND ARITY (doc/configuration.md §5.2): the third argument may be a LIST,
// an authored first-applicable fallback — accept the highlighted candidate,
// else accept whatever was typed. The keymap carries the whole list to
// dispatch; concrete command names (as here) still run the first arm, while
// an INTENTION list resolves against the catalog at fire time.
weft.bind("pick", "Return", ["pick-accept", "pick-accept-input"]);

// ── Everything from here to the theme block is UNCHANGED from config/config.js.
// A bind is a binding declared at the named mode's scope, config priority tier —
// which is what it already meant; it just becomes inspectable data.

// Doom-style leader (SPC): chords, prefixes as which-key menus — all identical.
weft.bind("normal", "SPC SPC", "find-file");
weft.bind("normal", "SPC :", "pick-commands");
weft.bind("normal", "SPC .", "find-file");
weft.bind("normal", "SPC ,", "buf-pick");

// SPC f — files
weft.bind("normal", "SPC f f", "find-file");
weft.bind("normal", "SPC f s", "save");
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

// SPC g — git (the git buffer runs its own keymap mode, exactly as today;
// under W5 its MODEL becomes an ObjectDoc, which changes nothing here).
weft.bind("normal", "SPC g g", "git-status");
weft.bind("normal", "SPC g i", "git-init");
weft.bind("normal", "SPC g l", "git-log");
weft.bind("normal", "SPC g d", "git-diff");
weft.bind("normal", "SPC g D", "git-diff-staged");
weft.bind("normal", "SPC g b", "git-blame");

weft.bind("normal", ".", "repeat-change");
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

weft.bind("insert", "C-SPC", "complete");
weft.bind("normal", "C-SPC", "complete");
weft.bind("normal", "SPC c e", "ts-expand-selection");
weft.bind("normal", "SPC c n", "ts-select-node");
weft.bind("normal", "SPC c b", "make-build");
weft.bind("normal", "SPC c t", "make-test");
weft.bind("normal", "SPC c r", "lang-run");
weft.bind("normal", "SPC c x", "run-line");

// ── Actions: UNCHANGED SURFACE. `{lang:"zig"}` is now sugar for a
// mode.Predicate `{ext:".zig"}` bound at buffer scope — same meaning it
// already had, now speaking the one matcher everything else uses.
weft.action("eval");
weft.provide("eval", {}, "run-line");
weft.provide("eval", { lang: "zig" }, "make-build");
weft.provide("eval", { lang: "py" }, "lang-run");
weft.bind("normal", "SPC e", "eval");

weft.action("format");
weft.provide("format", {}, "format-buffer");

weft.bind("normal", "K", "hover");

// ── Coding agents (ACP) — commented as in the original. Under the north star
// this block is where a SECOND system would first appear:
//   weft.system("agent-ux", (s) => {
//     s.grant("acp", "proc");
//     s.grant("acp", "fs_read");
//     s.grant("acp", "fs_write");
//     s.plugin("acp.js");
//     s.set("acp", "cmd", "codex-acp");
//     s.bind("normal", "SPC o A", "agent-start");
//   });
// …but reproducing TODAY's editor needs none of it, which is the point.

// SPC o — open / tools
weft.bind("normal", "SPC o d", "files");
weft.bind("normal", "SPC o r", "repl-start");
weft.bind("normal", "SPC o c", "console-open");
weft.bind("normal", "SPC o e", "direnv-status");
weft.bind("normal", "SPC o a", "llm-ask-line");

// SPC d — debug
weft.bind("normal", "SPC d b", "debug-toggle-breakpoint");
weft.bind("normal", "SPC d c", "debug-clear-breakpoints");
weft.bind("normal", "SPC d l", "debug-list-breakpoints");
weft.bind("normal", "F9", "debug-toggle-breakpoint");
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

// SPC h — help
weft.bind("normal", "SPC h c", "pick-commands");
weft.bind("normal", "SPC h h", "pick-commands");

// SPC t — toggle
weft.bind("normal", "SPC t w", "trim-trailing-buffer");
weft.bind("normal", "SPC t c", "comment-line");

// SPC v — generic structured-view controls. These commands address the
// semantic focus/action protocol, so the same bindings work for a directory
// view, a picker, or any other plugin-owned scene that advertises them.
// Keep the declaration data-shaped so plugins can share the surface without
// knowing which tool or config supplied it. Dialog inputs remain interaction-
// local and are intentionally not global which-key bindings.
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

// Autopair (insert mode) — unchanged
weft.bind("insert", "parenleft", "pair-paren");
weft.bind("insert", "braceleft", "pair-brace");
weft.bind("insert", "bracketleft", "pair-bracket");
weft.bind("insert", "quotedbl", "pair-quote");
weft.bind("insert", "apostrophe", "pair-quote-single");
weft.bind("insert", "parenright", "pair-close-paren");
weft.bind("insert", "braceright", "pair-close-brace");
weft.bind("insert", "bracketright", "pair-close-bracket");

// ── Theme: per-key value bindings on the `theme` slot, config priority over
// the core defaults. Same surface; "a colorscheme is a block of these" now has
// a precise meaning (a manifest fragment you can weft.use()).
weft.set("theme", "accent", "#8ec07c");
weft.set("theme", "cursor", "#fabd2f");
weft.set("theme", "selection", "#3c4a5e");

// The one imperative survivor, explicitly a startup-context effect (the
// `startup` transient scope exists exactly for lines like this):
weft.echo("weft: config.js loaded");

// ── What parity did NOT require (the negative space that proves the design):
// no weft.system(), no scopes, no SlotDecls, no GrantDecls, no Predicate
// syntax, no manifest vocabulary. One namespace fix (`editor` → `which_key`)
// and one trust decision (the bundled catalog's grant bundles) — everything
// else is the same 250 lines meaning the same things, now as a value.

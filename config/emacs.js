// emacs.js — NON-MODAL, chord-based editing (the emacs feel). Load with:
//   weft --config config/emacs.js
//
// The counterpart to config.js's vim: no modes, one resting `emacs` keymap that
// inherits the core editing floor (self-insert + arrows/Backspace), with every
// command a C-/M- chord on top. C-x and C-c are prefix key SEQUENCES — the exact
// same engine the vim leader uses (`C-x` holds pending, which-key shows its
// completions, `C-x C-f` completes) — NOT modes. This is the forcing function:
// it drives the sequence model from the modeless side and exercises the whole
// catalog (git, files, grep, make, repl, …) over a different editor plugin.
//
// Keys are written the way you'd say them — "C-x C-f", "M-x", "M-<" — and the
// one keyspec normalizer canonicalizes them; which-key shows them back the same.

// The catalog (emacs instead of vim/helix). emacs composes the same `motions`.
[
  "edit", "complete", "project", "structural", "region", "shell", "palette",
  "motions", "textobjects", "operators", "emacs",
  "ts", "comment", "whitespace", "numbers", "autopair", "consult",
  "git", "grep", "run", "make", "notes", "fmt", "buffers", "windows",
  "modes", "snippets", "direnv", "llm", "console", "repl", "which_key", "files",
].forEach((p) => weft.plugin(p));
weft.use("defaults"); // shared picker + which-key nav bindings

// which-key: a short idle delay, F1 peeks the current chord's choices.
weft.set("which_key", "delay-ms", "200");
weft.bind("global", "F1", "which-key-now");

// M-x — run a command (the command palette). C-s — incremental search (consult).
weft.bind("emacs", "M-x", "pick-commands");
weft.bind("emacs", "C-s", "consult-line"); // isearch-forward ≈ jump to a line
weft.bind("emacs", "C-r", "consult-line"); // isearch-backward ≈ same picker

// ── C-x — files, buffers, windows, tools (a prefix SEQUENCE) ──
weft.bind("emacs", "C-x C-f", "find-file"); //   find-file
weft.bind("emacs", "C-x C-s", "save"); //        save-buffer
weft.bind("emacs", "C-x C-w", "save-as"); //     write-file
weft.bind("emacs", "C-x C-c", "quit"); //        save-buffers-kill-terminal
weft.bind("emacs", "C-x C-r", "project-recent"); // recentf
weft.bind("emacs", "C-x b", "buf-pick"); //      switch-to-buffer
weft.bind("emacs", "C-x C-b", "buf-pick"); //    list-buffers
weft.bind("emacs", "C-x k", "buffer-close"); //  kill-buffer
weft.bind("emacs", "C-x 2", "window-split"); //  split-window-below
weft.bind("emacs", "C-x 3", "window-vsplit"); // split-window-right
weft.bind("emacs", "C-x 0", "window-close"); //  delete-window
weft.bind("emacs", "C-x o", "window-focus-right"); // other-window (cycle)
weft.bind("emacs", "C-x d", "files"); //         file browser
weft.bind("emacs", "C-x g", "git-status"); //    git-status
weft.bind("emacs", "C-x u", "undo"); //          undo

// ── C-c — mode/user commands (the second prefix SEQUENCE) ──
// Actions: abstract intents resolved by the buffer's language, exactly as the
// vim config — `eval` runs it (a .zig buffer builds, else the language runner),
// `format` formats it. A language plugin can weft.provide another provider
// without touching this keymap.
weft.action("eval");
weft.provide("eval", {}, "run-line");
weft.provide("eval", { lang: "zig" }, "make-build");
weft.provide("eval", { lang: "py" }, "lang-run");
weft.action("format");
weft.provide("format", {}, "format-buffer");

weft.bind("emacs", "C-c c", "comment-line"); // comment-dwim
weft.bind("emacs", "C-c f", "format"); //       the format action
weft.bind("emacs", "C-c e", "eval"); //         eval/run by language
weft.bind("emacs", "C-c g", "grep"); //         grep the project
weft.bind("emacs", "C-c s", "consult-line"); // search this buffer
weft.bind("emacs", "C-c i", "consult-imenu"); // imenu
weft.bind("emacs", "C-c b", "make-build"); //   compile
weft.bind("emacs", "C-c t", "make-test"); //    test
weft.bind("emacs", "C-c r", "repl-start"); //   run a REPL
weft.bind("emacs", "C-c o", "console-open"); // a command console
weft.bind("emacs", "C-c d", "direnv-status"); // direnv
weft.bind("emacs", "C-c a", "llm-ask-line"); // ask an llm
weft.bind("emacs", "C-c n", "notes-open"); //   open notes
weft.bind("emacs", "C-c N", "notes-capture"); // capture a note

// M-g g — goto (consult jump), M-g i — imenu (the emacs goto-map).
weft.bind("emacs", "M-g g", "consult-line");
weft.bind("emacs", "M-g i", "consult-imenu");

// Structural / code motion on the M- and C-c layers.
weft.bind("emacs", "C-c .", "goto-definition"); // xref-find-definitions
weft.bind("emacs", "C-c h", "hover"); //          display help at point
weft.bind("emacs", "M-e", "ts-expand-selection"); // expand-region

// Numbers (emacs-ish increment/decrement kept off the reserved chords).
weft.bind("emacs", "C-c +", "increment-number");
weft.bind("emacs", "C-c -", "decrement-number");

// Auto-close pairs as you type — bound on the literal punctuation (the
// normalizer maps "(" → parenleft, etc.). electric-pair-mode.
weft.bind("emacs", "(", "pair-paren");
weft.bind("emacs", "{", "pair-brace");
weft.bind("emacs", "[", "pair-bracket");
weft.bind("emacs", "\"", "pair-quote");
weft.bind("emacs", ")", "pair-close-paren"); // type-over the auto-closer
weft.bind("emacs", "}", "pair-close-brace");
weft.bind("emacs", "]", "pair-close-bracket");

// Completion-at-point — the at-caret popup. C-M-i, the real emacs binding
// (C-SPC is set-mark). M-/ also, dabbrev-muscle-memory.
weft.bind("emacs", "C-M-i", "complete");
weft.bind("emacs", "M-/", "complete");

// Theme as data — a calm light-on-dark block (emacs default-ish).
weft.set("theme", "background", "#1d1f21");
weft.set("theme", "foreground", "#c5c8c6");
weft.set("theme", "accent", "#81a2be");
weft.set("theme", "cursor", "#c5c8c6");
weft.set("theme", "selection", "#373b41");

weft.echo("weft: emacs config — C-x/C-c chords, M-x palette, C-x g git");

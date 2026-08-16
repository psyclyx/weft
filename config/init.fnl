;; weft sample config: vim, as config.
;;
;; Modal editing implemented entirely through the public ABI — modes are
;; keymap tables, motions are built-in commands, operators are scripted
;; compounds of them. Nothing in the core knows vim; delete this file
;; and weft is a plain modeless editor again.
;;
;; Development entry point:  zig build run -- --config config/init.fnl

(fn bind [mode key command] (weft.bind mode key command))
(fn cmd [name summary f] (weft.command name summary f))
(fn run [name] (weft.run name))
(fn set-mode [m] (weft.run "set-mode" m))

;; ── Modes ──
;; normal/visual swallow unbound text (the modal posture); both inherit
;; movement and editing keys from the default table. insert keeps the
;; default table's text input.
(weft.fallback "normal" "default")
(weft.fallback "visual" "normal")
(weft.fallback "insert" "default")
(weft.textinput "normal" nil)
(weft.textinput "visual" nil)

;; ── Compound commands (operators are just functions) ──
(cmd "vim-insert" "Enter insert mode."
  (fn [] (set-mode "insert")))
(cmd "vim-append" "Move right, enter insert mode."
  (fn [] (run "cursor-right") (set-mode "insert")))
(cmd "vim-open-below" "Open a line below, enter insert mode."
  (fn [] (run "line-end") (run "insert-newline") (set-mode "insert")))
(cmd "vim-open-above" "Open a line above, enter insert mode."
  (fn [] (run "line-start") (run "insert-newline") (run "cursor-up")
         (set-mode "insert")))
(cmd "vim-delete-line" "Delete the current line."
  (fn [] (run "line-start") (run "set-mark") (run "line-end")
         (run "delete-selection") (run "delete-forward")))
(cmd "vim-visual" "Start a character-wise selection."
  (fn [] (run "set-mark") (set-mode "visual")))
(cmd "vim-visual-delete" "Delete the selection, back to normal."
  (fn [] (run "delete-selection") (set-mode "normal")))
(cmd "vim-normal" "Back to normal mode."
  (fn [] (run "clear-selection") (set-mode "normal")))

;; ── Files ──
(cmd "find-file" "Open a file (fuzzy finder)."
  (fn []
    (weft.pick "open" nil
      (fn [path] (when (and path (> (length path) 0)) (weft.run "open" path)))
      {:source "files" :root "." :free_text true})))

;; ── Leader (space) ──
;; A transient chord: space → leader, then a submenu key. Leader modes
;; deliberately have no fallback, so movement keys don't leak through the
;; prefix; Escape (or any bound terminal) returns to normal.
(cmd "leader" "Space leader." (fn [] (set-mode "leader")))
(cmd "leader-file" "Leader: file commands." (fn [] (set-mode "leader-file")))
(cmd "leader-cancel" "Cancel the leader chord." (fn [] (set-mode "normal")))
(cmd "vim-find-file" "Find a file, then normal mode."
  (fn [] (set-mode "normal") (run "find-file")))
(weft.textinput "leader" nil)
(weft.textinput "leader-file" nil)

;; which-key: show these prefix modes' bindings while a chord is pending.
(weft.menu_mode "leader")
(weft.menu_mode "leader-file")
(weft.menu_mode "leader-collab")

;; ── Collaboration ──
;; Host and join are palette commands — `:listen` prompts for a port and,
;; deliberately, the access grade (view|edit|own, defaulting to safe
;; read-only view); `:connect host:port` joins. Sharing the active buffer
;; over a running host is a keystroke, since it takes no arguments.
(cmd "collab" "Collaboration submenu." (fn [] (set-mode "leader-collab")))
(cmd "vim-share" "Share the active buffer, then normal mode."
  (fn [] (set-mode "normal") (run "share")))
(cmd "vim-palette" "Open the palette (for arg-taking commands), then normal."
  (fn [] (set-mode "normal") (run "pick-commands")))
(weft.textinput "leader-collab" nil)

;; ── Windows (vim C-w prefix): split / focus / close ──
(cmd "window" "Window submenu." (fn [] (set-mode "window")))
(cmd "vim-split" "Split vertically, then normal."
  (fn [] (set-mode "normal") (run "split")))
(cmd "vim-focus-other" "Focus the other pane, then normal."
  (fn [] (set-mode "normal") (run "focus-other")))
(cmd "vim-unsplit" "Close the split, then normal."
  (fn [] (set-mode "normal") (run "unsplit")))
(weft.textinput "window" nil)
(weft.menu_mode "window")

;; ── Normal ──
(bind "normal" "h" "cursor-left")
(bind "normal" "j" "cursor-down")
(bind "normal" "k" "cursor-up")
(bind "normal" "l" "cursor-right")
(bind "normal" "w" "word-forward")
(bind "normal" "b" "word-backward")
(bind "normal" "0" "line-start")
(bind "normal" "dollar" "line-end")
(bind "normal" "g" "doc-start")
(bind "normal" "G" "doc-end")
(bind "normal" "i" "vim-insert")
(bind "normal" "a" "vim-append")
(bind "normal" "o" "vim-open-below")
(bind "normal" "O" "vim-open-above")
(bind "normal" "x" "delete-forward")
(bind "normal" "d" "vim-delete-line")
(bind "normal" "u" "undo")
(bind "normal" "C-r" "redo")
(bind "normal" "v" "vim-visual")
(bind "normal" "colon" "pick-commands")   ;; : → command palette
(bind "normal" "space" "leader")          ;; space → leader chord
(bind "normal" "C-w" "window")            ;; C-w → window (split) prefix
(bind "default" "C-g" "cancel")           ;; C-g → abort a pending connect

;; Window prefix: v/s split, w focus-other, o close split.
(bind "window" "v" "vim-split")
(bind "window" "s" "vim-split")
(bind "window" "w" "vim-focus-other")
(bind "window" "o" "vim-unsplit")
(bind "window" "Escape" "leader-cancel")

;; Picker: orderless by default; narrow/widen/cycle-style live (space is
;; a query separator for orderless, so narrowing uses Alt keys).
(bind "pick" "M-n" "pick-narrow")
(bind "pick" "M-u" "pick-widen")
(bind "pick" "M-s" "pick-style-cycle")

;; Leader chords: space f f → find file; space space → palette.
(bind "leader" "f" "leader-file")
(bind "leader" "c" "collab")
(bind "leader" "space" "pick-commands")
(bind "leader" "Escape" "leader-cancel")
(bind "leader-file" "f" "vim-find-file")
(bind "leader-file" "Escape" "leader-cancel")

;; space c s → share active buffer; space c h → palette (host: `listen`
;; prompts port + access; join: `connect host:port`).
(bind "leader-collab" "s" "vim-share")
(bind "leader-collab" "h" "vim-palette")
(bind "leader-collab" "Escape" "leader-cancel")

;; ── Visual ──
(bind "visual" "d" "vim-visual-delete")
(bind "visual" "x" "vim-visual-delete")
(bind "visual" "Escape" "vim-normal")

;; ── Insert ──
(bind "insert" "Escape" "vim-normal")

;; ── Cursor: a bar in every mode; blinking in insert ──
(weft.run "set-cursor" "normal" "bar")
(weft.run "set-cursor" "visual" "bar")
(weft.run "set-cursor" "insert" "bar")
(weft.run "cursor-blink" "insert" "on")   ;; steady elsewhere

;; Boot into normal mode.
(weft.mode "normal")
(weft.log "vim config loaded")

;; ── LSP (when a server is attached) ──
(bind "insert" "C-n" "complete")
(bind "normal" "C-bracketright" "goto-definition")   ;; C-] à la vim tags

;; ── Capabilities: buffer-words completion (instant tier) ──
;; A scripted provider against the capability name — proof the registry
;; is the only coupling. Scans this plugin's replica snapshot for words
;; sharing the prefix.
(weft.provide "edit/completion"
  (fn [prefix]
    (if (= (length prefix) 0)
        []
        (let [text (weft.snapshot)
              seen {}
              out []]
          (each [word (string.gmatch text "[%w_]+")]
            (when (and (> (length word) (length prefix))
                       (= (string.sub word 1 (length prefix)) prefix)
                       (not (. seen word)))
              (tset seen word true)
              (table.insert out word)))
          out))))

;; ── Language servers as data (two, per phase 2) ──
(weft.run "lsp-add" ".zig" "zls")
(weft.run "lsp-add" ".fnl" "fennel-ls")

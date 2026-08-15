;; scion sample config: vim, as config.
;;
;; Modal editing implemented entirely through the public ABI — modes are
;; keymap tables, motions are built-in commands, operators are scripted
;; compounds of them. Nothing in the core knows vim; delete this file
;; and scion is a plain modeless editor again.
;;
;; Development entry point:  zig build run -- --config config/init.fnl

(fn bind [mode key command] (scion.bind mode key command))
(fn cmd [name summary f] (scion.command name summary f))
(fn run [name] (scion.run name))
(fn set-mode [m] (scion.run "set-mode" m))

;; ── Modes ──
;; normal/visual swallow unbound text (the modal posture); both inherit
;; movement and editing keys from the default table. insert keeps the
;; default table's text input.
(scion.fallback "normal" "default")
(scion.fallback "visual" "normal")
(scion.fallback "insert" "default")
(scion.textinput "normal" nil)
(scion.textinput "visual" nil)

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
(bind "normal" "space" "pick-commands")   ;; leader → command palette

;; ── Visual ──
(bind "visual" "d" "vim-visual-delete")
(bind "visual" "x" "vim-visual-delete")
(bind "visual" "Escape" "vim-normal")

;; ── Insert ──
(bind "insert" "Escape" "vim-normal")

;; Boot into normal mode.
(scion.mode "normal")
(scion.log "vim config loaded")

;; ── LSP (when a server is attached) ──
(bind "insert" "C-n" "complete")
(bind "normal" "C-bracketright" "goto-definition")   ;; C-] à la vim tags

;; ── Capabilities: buffer-words completion (instant tier) ──
;; A scripted provider against the capability name — proof the registry
;; is the only coupling. Scans this plugin's replica snapshot for words
;; sharing the prefix.
(scion.provide "edit/completion"
  (fn [prefix]
    (if (= (length prefix) 0)
        []
        (let [text (scion.snapshot)
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
(scion.run "lsp-add" ".zig" "zls")
(scion.run "lsp-add" ".fnl" "fennel-ls")

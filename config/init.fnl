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
(cmd "vim-split" "Horizontal split, then normal."
  (fn [] (set-mode "normal") (run "split")))
(cmd "vim-vsplit" "Vertical split, then normal."
  (fn [] (set-mode "normal") (run "vsplit")))
(cmd "vim-focus-other" "Focus the other pane, then normal."
  (fn [] (set-mode "normal") (run "focus-other")))
(cmd "vim-unsplit" "Close the split, then normal."
  (fn [] (set-mode "normal") (run "unsplit")))
(weft.textinput "window" nil)
(weft.menu_mode "window")

;; ── More operators / insert entries (compounds of built-ins) ──
(cmd "vim-append-line" "Insert at end of line."
  (fn [] (run "line-end") (set-mode "insert")))
(cmd "vim-insert-line" "Insert at start of line."
  (fn [] (run "line-start") (set-mode "insert")))
(cmd "vim-delete-eol" "Delete to end of line."
  (fn [] (run "set-mark") (run "line-end") (run "delete-selection")))
(cmd "vim-change-eol" "Change to end of line."
  (fn [] (run "set-mark") (run "line-end") (run "delete-selection")
         (set-mode "insert")))
(cmd "vim-change-line" "Change the whole line."
  (fn [] (run "line-start") (run "set-mark") (run "line-end")
         (run "delete-selection") (set-mode "insert")))

;; ── g prefix (gg → top) ──
(cmd "goto" "g prefix." (fn [] (set-mode "goto")))
(cmd "vim-goto-top" "Go to the first line." (fn [] (set-mode "normal") (run "doc-start")))
(weft.textinput "goto" nil)
(weft.menu_mode "goto")

;; ── z prefix (zz → center) ──
(cmd "zed" "z prefix." (fn [] (set-mode "zed")))
(cmd "vim-center" "Center the current line." (fn [] (set-mode "normal") (run "center-line")))
(weft.textinput "zed" nil)
(weft.menu_mode "zed")

;; ── Normal ──
(bind "normal" "h" "cursor-left")
(bind "normal" "j" "cursor-down")
(bind "normal" "k" "cursor-up")
(bind "normal" "l" "cursor-right")
(bind "normal" "w" "word-forward")
(bind "normal" "b" "word-backward")
(bind "normal" "0" "line-start")
(bind "normal" "dollar" "line-end")
(bind "normal" "G" "doc-end")
(bind "normal" "i" "vim-insert")
(bind "normal" "a" "vim-append")
(bind "normal" "o" "vim-open-below")
(bind "normal" "O" "vim-open-above")
(bind "normal" "x" "delete-forward")
;; d/c/y are operators (see below); D/C/S remain the to-end/line shortcuts.
(bind "normal" "u" "undo")
(bind "normal" "C-r" "redo")
(bind "normal" "v" "vim-visual")
(bind "normal" "colon" "pick-commands")   ;; : → command palette
(bind "normal" "space" "leader")          ;; space → leader chord
(bind "normal" "C-w" "window")            ;; C-w → window (split) prefix
(bind "normal" "g" "goto")                ;; g → g prefix (gg = top)
(bind "normal" "z" "zed")                 ;; z → z prefix (zz = center)
(bind "default" "C-g" "cancel")           ;; C-g → abort a pending connect

;; ── Editing policy composed in fennel ──
;; The core gives us primitives — weft.cursor/jump/selection/slice/line and
;; the raw edit commands (insert-text, delete-selection, set-mark). The
;; vim-flavored REGISTER, paste, ^, J, and f/t are composed HERE; the core
;; has no notion of a yank register or these motions. (word/WORD boundaries
;; and % stay core — they're structural text scans, not vim policy.)
(var reg "")          ;; yank register contents
(var reg-line false)  ;; is the register linewise?

(fn capture-sel []    ;; read the selection into the register (charwise)
  (let [s (weft.selection)]
    (when s (set reg (weft.slice s.start s.end)) (set reg-line false))))

(cmd "yank-selection" "Copy the selection (charwise)."
  (fn [] (capture-sel) (run "clear-selection")))
(cmd "cut-selection" "Yank then delete the selection."
  (fn [] (capture-sel) (run "delete-selection")))
(cmd "yank-line" "Yank the current line (linewise)."
  (fn [] (let [l (weft.line)] (set reg (weft.slice l.start l.end)) (set reg-line true))))
(cmd "delete-line" "Delete the current line (linewise, into the register)."
  (fn [] (let [l (weft.line)]
           (set reg (weft.slice l.start l.end)) (set reg-line true)
           (weft.jump l.start) (run "set-mark") (weft.jump (+ l.end 1))
           (run "delete-selection"))))
(cmd "paste" "Paste the register after the cursor/line."
  (fn [] (if reg-line
             (let [l (weft.line)] (weft.jump l.end) (run "insert-text" (.. "\n" reg)) (weft.jump (+ l.end 1)))
             (run "insert-text" reg))))
(cmd "paste-before" "Paste the register before the cursor/line."
  (fn [] (if reg-line
             (let [l (weft.line)] (weft.jump l.start) (run "insert-text" (.. reg "\n")) (weft.jump l.start))
             (run "insert-text" reg))))

(cmd "first-non-blank" "Move to the first non-blank on the line."
  (fn [] (let [l (weft.line) text (weft.slice l.start l.end) i (string.find text "[^ \t]")]
           (weft.jump (+ l.start (if i (- i 1) 0))))))

(cmd "join-lines" "Join this line with the next (single space)."
  (fn [] (let [l (weft.line) nxt (weft.line (+ l.end 1))]
           (when (> nxt.start l.start)   ;; a next line exists
             (let [ntext (weft.slice nxt.start nxt.end)
                   nb (string.find ntext "[^ \t]")
                   drop (if nb (- nb 1) (length ntext))]
               (weft.jump l.end) (run "set-mark")
               (weft.jump (+ nxt.start drop)) (run "delete-selection")
               (run "insert-text" " ") (weft.jump l.end))))))

;; f/F/t/T — target-character search on the current line.
(cmd "find-char" "Move to a character on the line (dir f|F|t|T, to <char>)."
  (fn [dir ch]
    (let [cur (weft.cursor) l (weft.line) text (weft.slice l.start l.end)
          rel (- cur l.start)
          fwd (or (= dir "f") (= dir "t"))
          till (or (= dir "t") (= dir "T"))]
      (if fwd
          (let [i (string.find text ch (+ rel 2) true)]
            (when i (weft.jump (+ l.start (- i 1) (if till -1 0)))))
          (do (var found nil)
              (for [k rel 1 -1]
                (when (and (not found) (= (string.sub text k k) ch)) (set found k)))
              (when found (weft.jump (+ l.start (- found 1) (if till 1 0)))))))))

;; More motions. w/b/e are word-char; W/B/E are WORD (whitespace-delimited).
(bind "normal" "W" "WORD-forward")
(bind "normal" "B" "WORD-backward")
(bind "normal" "e" "word-end")
(bind "normal" "E" "WORD-end")
(bind "normal" "asciicircum" "first-non-blank") ;; ^
(bind "normal" "percent" "match-bracket")       ;; %

;; Insert entries + line operators.
(bind "normal" "A" "vim-append-line")
(bind "normal" "I" "vim-insert-line")
(bind "normal" "D" "vim-delete-eol")
(bind "normal" "C" "vim-change-eol")
(bind "normal" "S" "vim-change-line")
(bind "normal" "X" "delete-backward")
(bind "normal" "J" "join-lines")

;; Yank / paste. Visual y is charwise; Y is linewise; p/P paste below/
;; above (linewise) or at the cursor (charwise).
(cmd "vim-visual-yank" "Yank the selection, back to normal."
  (fn [] (run "yank-selection") (set-mode "normal")))
(bind "visual" "y" "vim-visual-yank")
(bind "normal" "Y" "yank-line")
(bind "normal" "p" "paste")
(bind "normal" "P" "paste-before")

;; ── Operators are just modes (no state machine) ──
;; d/c/y set the mark and enter an operator MODE; a motion in that mode
;; extends the selection and the operator applies. Because each is a real
;; menu mode, which-key shows the available motions after the operator —
;; the thing nvim/emacs can't do cleanly.
;;
;; Motions offered to an operator: key → [motion-command friendly-label].
(local op-motions
  {:w ["word-forward" "word"] :W ["WORD-forward" "WORD"]
   :b ["word-backward" "back-word"] :B ["WORD-backward" "back-WORD"]
   :e ["word-end" "word-end"] :E ["WORD-end" "WORD-end"]
   :dollar ["line-end" "line-end"] :0 ["line-start" "line-start"]
   :asciicircum ["first-non-blank" "first-non-blank"]
   :G ["doc-end" "to-end"] :percent ["match-bracket" "match"]})

;; op enter-key → [mode finish-command after-mode line-command double-key]
(fn make-operator [enter-key mode finish after line-cmd]
  ;; Enter: set the mark here, switch to the operator mode (which-key on).
  (cmd (.. "enter-" mode) (.. "Start " mode ".")
    (fn [] (run "set-mark") (set-mode mode)))
  (bind "normal" enter-key (.. "enter-" mode))
  (weft.textinput mode nil)
  (weft.menu_mode mode)
  ;; Cancel drops the pending selection.
  (cmd (.. mode "-cancel") "Cancel the operator."
    (fn [] (run "clear-selection") (set-mode "normal")))
  (bind mode "Escape" (.. mode "-cancel"))
  ;; The doubled operator key is the linewise whole-line form (dd/cc/yy).
  (cmd (.. mode "-line") "Operate on the whole line."
    (fn [] (run "clear-selection") (set-mode after) (run line-cmd)))
  (bind mode enter-key (.. mode "-line"))
  ;; Each motion: run the motion (extends the selection), apply, leave.
  ;; The command name is per-mode (which-key shows "w  op-delete-word").
  (each [mkey spec (pairs op-motions)]
    (let [wname (.. mode "-" (. spec 2))]
      (cmd wname (. spec 2)
        (fn [] (run (. spec 1)) (run finish) (set-mode after)))
      (bind mode mkey wname))))

(make-operator "d" "op-delete" "cut-selection"  "normal" "delete-line")
(make-operator "c" "op-change" "cut-selection"  "insert" "vim-change-line")
(make-operator "y" "op-yank"   "yank-selection" "normal" "yank-line")

;; f / F / t / T — find a character on the line (one-shot capture modes).
(fn find-cmd [name dir]
  (cmd name (.. "Find '" dir "' target.")
    (fn [c] (set-mode "normal") (weft.run "find-char" dir c))))
(find-cmd "do-find-f" "f")
(find-cmd "do-find-F" "F")
(find-cmd "do-find-t" "t")
(find-cmd "do-find-T" "T")
(each [mode capture (pairs {:find-f "do-find-f" :find-F "do-find-F"
                            :find-t "do-find-t" :find-T "do-find-T"})]
  (weft.textinput mode capture)
  (bind mode "Escape" "leader-cancel"))
(cmd "find-f" "f prefix." (fn [] (set-mode "find-f")))
(cmd "find-F" "F prefix." (fn [] (set-mode "find-F")))
(cmd "find-t" "t prefix." (fn [] (set-mode "find-t")))
(cmd "find-T" "T prefix." (fn [] (set-mode "find-T")))
(bind "normal" "f" "find-f")
(bind "normal" "F" "find-F")
(bind "normal" "t" "find-t")
(bind "normal" "T" "find-T")

;; Scrolling (vim C-d/C-u/C-f/C-b/C-e/C-y).
(bind "normal" "C-d" "scroll-half-down")
(bind "normal" "C-u" "scroll-half-up")
(bind "normal" "C-f" "scroll-page-down")
(bind "normal" "C-b" "scroll-page-up")
(bind "normal" "C-e" "scroll-line-down")
(bind "normal" "C-y" "scroll-line-up")

;; g / z prefix contents.
(bind "goto" "g" "vim-goto-top")
(bind "goto" "Escape" "leader-cancel")
(bind "zed" "z" "vim-center")
(bind "zed" "Escape" "leader-cancel")

;; Window prefix: s horizontal split, v vertical split, w/C-w focus other,
;; o/q close split.
(bind "window" "s" "vim-split")
(bind "window" "v" "vim-vsplit")
(bind "window" "w" "vim-focus-other")
(bind "window" "C-w" "vim-focus-other")
(bind "window" "o" "vim-unsplit")
(bind "window" "q" "vim-unsplit")
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

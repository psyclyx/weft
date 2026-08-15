;; scion sample config — development entry point (zig build run -- --config config/init.fnl).
;; The config is a plugin: a Fennel VM with its own document peer, no
;; special powers. Everything below goes through the same command ABI
;; the built-ins use.

;; A scripted command: comment-banner the current line width.
(scion.command "insert-rule" "Insert a horizontal rule."
  (fn [] (scion.run "insert-text" ";; ----------------------------------------\n")))

;; Bindings shadow or extend the defaults freely.
(scion.bind "default" "C-r" "insert-rule")

(scion.log "sample config loaded")

;; scion's bundled plugin — UI policy over core mechanisms, in the same
;; language and through the same ABI as user config. Core provides
;; introspection (scion.buffers, scion.commands), the picker, and echo;
;; what to show and how to phrase it lives here, replaceable by
;; rebinding the same command names.

(fn human-bytes [n]
  (if (>= n 1048576) (.. (math.floor (/ n 1048576)) "MB")
      (>= n 1024) (.. (math.floor (/ n 1024)) "KB")
      (.. n "B")))

(fn buffer-doc [b]
  (.. b.backing
      (if b.path (.. "  " b.path) "")
      (if (> b.unfetched 0) (.. "  " (human-bytes b.unfetched) " unfetched") "")))

(fn buffer-label [b]
  (.. b.id ": " b.name
      (if b.dirty " [+]" "")
      (if b.read_only " [ro]" "")
      (if b.active " *" "")))

(scion.command "buffers" "Pick over the open buffers; accept to switch."
  (fn []
    (let [entries []]
      (each [_ b (ipairs (scion.buffers))]
        (table.insert entries [(buffer-label b) (buffer-doc b)]))
      (scion.pick "buffer" entries
        (fn [choice]
          (let [id (tonumber (string.match choice "^(%d+):"))]
            (when id (scion.run "buffer-switch" id))))))))

(scion.command "status" "Echo where you are: buffer, backing, sync state."
  (fn []
    (each [_ b (ipairs (scion.buffers))]
      (when b.active
        (scion.run "echo"
          (.. b.name "  [" b.backing "]"
              (if b.path (.. "  " b.path) "")
              (if b.dirty "  modified" "  saved")
              (if b.read_only "  read-only" "")
              (if (> b.unfetched 0)
                  (.. "  " (human-bytes b.unfetched) " unfetched")
                  "")))))))

(scion.command "help" "Pick over every command; accept to run it."
  (fn []
    (let [entries []]
      (each [_ c (ipairs (scion.commands))]
        (table.insert entries [(. c 1) (. c 2)]))
      (scion.pick "help" entries
        (fn [choice] (scion.run choice))))))

;; weft's bundled plugin — UI policy over core mechanisms, in the same
;; language and through the same ABI as user config. Core provides
;; introspection (weft.buffers, weft.commands with arg schema), the
;; picker (weft.pick / weft.read: free-text accept, native file/dir
;; sources), and echo; what to show and how to phrase it lives here,
;; replaceable by rebinding the same command names.

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

;; ── Command introspection + argument-aware invocation ──
;; weft.commands() carries each command's arg schema; the palette parses
;; inline args when typed, else prompts for each argument in turn with
;; completion suited to its type. This is the vertico/consult shape built
;; entirely on weft.read.

(fn command-index []
  (let [idx {}]
    (each [_ c (ipairs (weft.commands))]
      (tset idx c.name c))
    idx))

(fn split-ws [s]
  (let [out []]
    (each [tok (string.gmatch s "%S+")] (table.insert out tok))
    out))

(fn coerce [ty tok]
  (if (= ty "integer") (math.tointeger (tonumber tok))
      (= ty "number") (tonumber tok)
      (= ty "boolean") (= tok "true")
      tok))

(fn buffer-ids []
  (let [out []]
    (each [_ b (ipairs (weft.buffers))] (table.insert out (tostring b.id)))
    out))

;; Read options for one argument: files for path-ish args, the open
;; buffer set for buffer-switch, else a free-text line.
(fn arg-opts [cmd-name a]
  (if (or (string.find a.name "path") (string.find a.name "file")
          (string.find a.name "dir") (= cmd-name "open") (= cmd-name "find-file"))
      {:source "files" :root "." :allow_new true}
      (= cmd-name "buffer-switch")
      {:candidates (buffer-ids) :allow_new true}
      {:allow_new true}))

(fn run-safe [name args]
  (let [(ok err) (pcall (fn [] (weft.run name (table.unpack args))))]
    (when (not ok)
      (weft.run "echo" (.. name ": " (tostring err))))))

;; Prompt for arguments i..N in turn (continuation-passing: each accept
;; opens the next), then run the command with the collected values.
(fn read-args [name specs i acc]
  (if (> i (length specs))
      (run-safe name acc)
      (let [a (. specs i)]
        (weft.read (.. name "  " a.name " <" a.type ">")
                    (arg-opts name a)
                    (fn [val]
                      (table.insert acc (coerce a.type val))
                      (read-args name specs (+ i 1) acc))))))

;; Run a palette line: inline args (coerced against the schema) if typed,
;; else per-argument prompts, else the bare command.
(fn run-line [idx line]
  (let [toks (split-ws line)
        name (. toks 1)
        spec (and name (. idx name))]
    (if (not name) nil
        (not spec) (weft.run "echo" (.. "unknown command: " (or name "")))
        (> (length toks) 1)
        (let [args []]
          (for [k 2 (length toks)]
            (let [a (. spec.args (- k 1))]
              (table.insert args (if a (coerce a.type (. toks k)) (. toks k)))))
          (run-safe name args))
        (> (length spec.args) 0) (read-args name spec.args 1 [])
        (run-safe name []))))

(weft.command "pick-commands" "Command palette: run a command (inline args or per-arg prompts)."
  (fn []
    (let [idx (command-index)
          entries []]
      (each [name c (pairs idx)]
        (table.insert entries [name c.summary]))
      (weft.pick "command" entries
                  (fn [choice] (run-line idx choice))
                  {:free_text true}))))

(weft.command "help" "Pick over every command; accept to run it (prompts for args)."
  (fn []
    (let [idx (command-index)
          entries []]
      (each [name c (pairs idx)]
        (table.insert entries [name c.summary]))
      (weft.pick "help" entries
                  (fn [choice] (run-line idx choice))
                  {:free_text true}))))

;; ── Buffers ──

(weft.command "buffers" "Pick over the open buffers; accept to switch."
  (fn []
    (let [entries []]
      (each [_ b (ipairs (weft.buffers))]
        (table.insert entries [(buffer-label b) (buffer-doc b)]))
      (weft.pick "buffer" entries
        (fn [choice]
          (let [id (tonumber (string.match choice "^(%d+):"))]
            (when id (weft.run "buffer-switch" id))))))))

(weft.command "status" "Echo where you are: buffer, backing, sync state."
  (fn []
    (each [_ b (ipairs (weft.buffers))]
      (when b.active
        (weft.run "echo"
          (.. b.name "  [" b.backing "]"
              (if b.path (.. "  " b.path) "")
              (if b.dirty "  modified" "  saved")
              (if b.read_only "  read-only" "")
              (if (> b.unfetched 0)
                  (.. "  " (human-bytes b.unfetched) " unfetched")
                  "")))))))

;; ── Files: fuzzy finder + directory browser (local + host:path) ──

(fn strip-slash [s]
  (let [(r _) (string.gsub s "/$" "")] r))

(fn join-path [base name]
  (if (= base ".") name
      (.. (strip-slash base) "/" name)))

(fn parent-path [spec]
  (let [trimmed (strip-slash spec)]
    (or (string.match trimmed "^(.*)/[^/]+$") ".")))

;; scp-style remote spec: a colon before any slash (mirrors the core's
;; open-buffer host:path detection).
(fn remote-spec? [s]
  (let [colon (string.find s ":")]
    (and colon
         (let [slash (string.find s "/")]
           (or (not slash) (< colon slash))))))

(weft.command "find-file" "Fuzzy-find a file under the project; accept to open."
  (fn []
    (weft.pick "file" nil
      (fn [p] (weft.run "open" p))
      {:source "files" :root "." :free_text true})))

(fn browse-path [spec]
  (if (remote-spec? spec)
      (let [(host path) (string.match spec "^([^:]+):(.*)$")]
        (weft.run "browse-remote" host (if (= path "") "." path)))
      (weft.pick (.. "dir " spec) nil
        (fn [choice]
          (if (= choice "../") (browse-path (parent-path spec))
              (string.match choice "/$") (browse-path (join-path spec (strip-slash choice)))
              (weft.run "open" (join-path spec choice))))
        {:source "dir" :root spec :free_text true})))

(weft.command "browse" "Browse a directory (local, or host:path over a shell)."
  (fn [] (browse-path ".")))

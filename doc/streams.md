# Streams: processes, projections and lists that never block

The plan for one class of problem, found through Find in Files
(2026-10-16) but not owned by it. A search for `plugin` in the weft tree
showed nothing, then took 19 seconds to show 20,000 rows in `*grep*`. Every
cause was general:

- **A large output arrived empty.** `wl_exec_read` documented a window
  and did an exact write, so any output bigger than the reader's buffer
  read as nothing. *Fixed:* the door hands back a window, and the output
  library reads all of it.
- **Rows waited for an unrelated wake.** The pick drained its source
  before the frame delivered process output, so rows sat until a caret
  blink or a key. *Fixed:* the pick drains after the deliveries, and a
  source with rows ready wakes the loop (`Source.ready`).
- **A process answers only when it exits.** `exec` delivers stdout,
  stderr and status at exit, so nothing shows while a search runs, and a
  superseded search runs to completion.
- **Five more process doors take a shell string.** `proc_spawn`,
  `proc_to_buffer`, `proc_append_buffer`, `proc_spool` and `proc_filter`
  each take a command line that something has to quote correctly. The
  JavaScript plane's `qjs_proc_spawn` does too.
- **A projection re-renders whole on every commit.** `repaint` replaces
  the entire document with the entire re-rendered text and repaints
  every style and fold. One large result is a CRDT insert of all of it
  plus a mark per row, on the frame thread. Streaming into it would be
  quadratic.
- **A list holds everything.** A live pick caps a query at 2000 rows
  rather than showing a window of more.

The rule this holds to: **nothing a producer does can block a frame, and
the cost of an update is the size of the update, not the size of
everything before it.** Each fix lands in one shared place. A fix that
ends up specific to grep means the shared place is wrong.

## 1. One process door: argv, streamed, cancellable

A child process is spawned from an **argv**, never a shell string. Its
stdout and stderr arrive as chunks while it runs, through a readiness
wake when bytes are pending and another when it exits, with its exit
status. It can be killed. The SDK's `exec` (collect everything, then
call once) becomes a convenience over the stream, and a line splitter
for chunked output lives in the SDK, not in each plugin.

The shell-string doors go: `proc_spawn`, `proc_to_buffer`,
`proc_append_buffer`, `proc_spool`, `proc_filter` and the JavaScript
plane's `qjs_proc_spawn`. Their callers move to argv:

- `llm`, `console`, `fmt`, `git`, `modes` and `direnv`;
- the `jsonrpc` library, which drives the LSP;
- `dap.js`, `acp.js` and `config.js`.

A caller that needs a shell says so in its argv
(`sh -c <script>`), and the script is then its own business.

*Landed (1a):*
- `wl_proc_spawn` takes an argv and a duplex flag, and `wl_proc_read`
  takes a stream (stdout or stderr). `wl_proc_status` reports the exit.
  The JavaScript plane matches: `weft.procSpawn(argv[], duplex)`,
  `procRead(h, stream)` and `procStatus(h)`.
- `ProcStream` keeps stderr (bounded) and the exit status. It signals
  the loop's wake fd when bytes land, so process streams left the 8 ms
  poll, which now runs only for REPL and net sessions.
- SDK `weft.spawn` / `spawnWith` give line, chunk and exit
  continuations, drained by the SDK's own `on_poll` within a bounded
  budget per poll. A plugin's `.poll` hook runs after that.
- Configured commands (an LSP server, an ACP agent, a DAP adapter) are
  words split into an argv, never shell-parsed.
- The live search streams rg's lines and kills the previous search.

*Landed (1c):* no door takes a shell string.
- `proc_to_buffer`, `proc_append_buffer`, `proc_spool` and their
  `on_fill_token` are deleted.
- `proc_filter` and `shell_insert` take an argv.
- `wl_proc_close_input` ends a child's stdin, and stderr can merge into
  stdout.
- `wl_buffer_append` is shared by both planes.
- An exec continuation runs in the place its command was issued in.
- llm, console, modes, direnv, fmt and shell are migrated. A caller
  whose input IS a shell line (console, fmt's filter, shell insert)
  asks for `sh -c` itself.

`exec` stays as its own door. It already takes an argv and never
blocks; it answers once, which is right for a command whose answer is
read whole (git's gathers).

## 2. Incremental projections

A projection commit applies what changed: new rows at the end are an
insert at the end, a changed row is a replacement of that row, and
styles and folds are painted for the rows that moved. The output library
(`*grep*`, run, make and the other tool buffers) appends rows as its
process streams, so a tool buffer fills while the tool runs.

*Landed:*
- A full commit writes only the replacement that differs
  (`Document.becomes`).
- `wl_proj_extend` opens a build that appends to the committed tree. It
  lays out and writes only the new rows, as an insert at the end.
- The output library streams through `weft.spawn` and appends each batch
  the tool writes. A run is capped at 200,000 rows and says so, and a
  new run stops the last.

Painting styles and folds still walks every row on each commit. That
costs about a millisecond for 20,000 rows, and making it incremental is
left for when it shows.

## 3. Large inserts at document speed

A fresh fill of a tool buffer costs what opening a file of that size
costs, through the same base path stemma gives a file
(`base-anchors-stemma-07`). It does not cost a CRDT operation per chunk.

*Landed:* output is PRODUCED, not authored. The cost was `renderInto`'s
peer path, a shadow replica bootstrapped and merged per scalar: 5.5 µs a
byte in ReleaseFast, so 19 s for the 1.5 MB fill in a Debug test.
`Document.produce` writes to the main replica at 40 ns a byte, and
`refound` folds the history away through `openFromContent`.
- `Document.becomes(text)` writes only the replacement that differs.
- `command.produceInto` serves REPL output, tool fills and transcripts.
- The projection repaint and the transcript projection use `becomes`.
- `renderInto` stays for authored edits: agent file writes, formatter
  results, command output read into a file.

The 1.5 MB case takes about a second in a Debug test.

## 4. Lists at scale

The picker builds and draws the window it shows, so a live source's
rows are bounded by memory policy, not by what one frame can afford.
When a cap remains, it is shown: "2000 of more…". A live source runs on
door 1: it streams its rows as the process finds them, and kills the
previous query's process when the query moves on.

*Landed (4):*
- The picker keeps the ranking it made. A batch a source streams in is
  scored alone and merged in, and a test holds the merge to a full
  re-rank.
- A live source's cap is 50,000 rows a generation, and hitting it shows
  in the header (`[1/50000+]`).
- REPL and net sessions wake the loop when bytes land (`Pool.wakeLoop`),
  as process streams do, and the 8 ms stream poll is deleted.

## 5. Reads outlive the reads after them, and directories are walked

Landed:

- An SDK read (`weft.path()`, `slice`, `argStr`, …) used to return a
  slice of a scratch buffer that the next read overwrote. Now every
  export is an entry (`plugin_sdk/entry.zig`), and a read's answer lives
  until the host next calls the plugin.
- `wl_fs_walk` walks a directory off the frame thread. Its paths are
  read through `wl_fs_walk_read` as they are found, and `on_poll` is
  raised as they land. It is `fs_read`-gated:
  - inside a limit, the start must resolve beneath the limit's root;
  - a symlink is listed, never entered;
  - the machinery carve-out is asked of every directory;
  - it stops at 200,000 files and says so.

  An empty path means the place the dispatch runs in, so a finder names
  no directory. The SDK pumps walks in `on_poll`, beside processes
  (`weft.walk`).
- Open File is the files plugin's search, fed by a walk; the picker
  narrows it. `wl_open_file_pick`, `LocalFinder` and `LocalDir` are gone.
  A live pick holds 200,000 rows, the same as a walk.

## Left

- **The argument asker's prompt** is the status-line minibuffer, which
  is easy to miss in the IDE layout.
- **Browse Remote Files** (`fs_source.RemoteDir`) is still a native pick
  source in core. It moves to a plugin when a remote walk can stand
  behind the same door.

## Order

1. The process door, with streaming and argv. The live search moves onto
   it first, so it shows rows as rg finds them; then every other caller
   moves, and the string doors are deleted.
2. Incremental projections, then streaming tool buffers.
3. Fast large fills.
4. The windowed picker.

Each step lands with its tests before the next starts.

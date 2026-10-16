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

## 2. Incremental projections

A projection commit applies what changed: new rows at the end are an
insert at the end, a changed row is a replacement of that row, and
styles and folds are painted for the rows that moved. The output library
(`*grep*`, run, make and the other tool buffers) appends rows as its
process streams, so a tool buffer fills while the tool runs.

## 3. Large inserts at document speed

A fresh fill of a tool buffer costs what opening a file of that size
costs, through the same base path stemma gives a file
(`base-anchors-stemma-07`). It does not cost a CRDT operation per chunk.

## 4. Lists at scale

The picker builds and draws the window it shows, so a live source's
rows are bounded by memory policy, not by what one frame can afford.
When a cap remains, it is shown: "2000 of more…". A live source runs on
door 1: it streams its rows as the process finds them, and kills the
previous query's process when the query moves on.

## Order

1. The process door, with streaming and argv. The live search moves onto
   it first, so it shows rows as rg finds them; then every other caller
   moves, and the string doors are deleted.
2. Incremental projections, then streaming tool buffers.
3. Fast large fills.
4. The windowed picker.

Each step lands with its tests before the next starts.

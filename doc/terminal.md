# The terminal

The `terminal` plugin runs a shell on a real terminal: a pseudo-terminal the
kernel's line discipline drives, and a VT emulator (ghostty's libghostty-vt)
turning the shell's output into a screen. C-c interrupts, C-d ends input, C-z
suspends, and full-screen programs (`less`, `vim`, `top`) take the screen and
give it back. It replaced a line-mode shell over the REPL session machinery,
which had no pty, no emulation and no way to send a signal.

The split follows weft's rule: capabilities are plugins, core gets doors.
Core moves bytes, sizes and cells. It does not know what a terminal is, which
program runs, what `TERM` says, or how a key becomes bytes. All of that lives
in `src/plugins/terminal/`.

## 1. The pty door

`core/pty.zig` puts a child on a pseudo-terminal. The guest reaches it
through six doors (`wasm_host/pty.zig`, SDK `weft.pty*`):

| door | what it does |
|---|---|
| `wl_pty_spawn(cmd, cols, rows)` | runs `cmd` under `/bin/sh -c` on a new pty; perm `proc` |
| `wl_pty_write(h, bytes)` | queues bytes for the child to read, as typed |
| `wl_pty_read(h, out, cap)` | moves raw output into the guest |
| `wl_pty_resize(h, cols, rows, px_w, px_h)` | sets the size; the kernel sends SIGWINCH |
| `wl_pty_exited(h)` | returns the exit code, or 128 + signal, once the output is read |
| `wl_pty_close(h)` | hangs the child up and reaps it |

A spawn runs where the dispatch is, like every other spawn door
(doc/place.md). The cwd is the place's directory and the environment is the
place's merged one. A place with no local directory is refused and says so.
It never falls back to the launch directory.

**Threads.** The frame thread opens `/dev/ptmx` and returns. One resident
reader thread does the rest:

- It forks the child onto the slave side. The child gets its own session and
  the slave as its controlling tty. weft's fds are closed, and signal
  dispositions and the mask are reset.
- It then polls three things: the master, the child's pidfd, and a kick
  eventfd.
- Output goes to an inbox capped at 1 MiB. Past the cap, the reader stops
  reading, so a flood is held back by the kernel's pty buffer, not by memory.
- Input goes to an outbox, written as the master accepts it. A child that
  isn't reading never stalls a frame.
- Arrival rings the pool's notify fd once per batch the frame has not seen.
  An idle shell costs no polling; there is no 8 ms stream timer for ptys.

**Exit** comes from the pidfd, not from end of file on the master, because a
background job still holding the tty would delay that past the shell's own
exit. The status is published only after the child's last output has been
read.

**Signals.** No signal is ever sent on the user's behalf. A 0x03 written to
the master is C-c; the line discipline turns it into SIGINT for the
foreground job, as on any terminal.

**Local only.** A pty in a remote place (a shell on a peer, `shell:` loci) is
a later door. It would go the way `peer_fs` did: the same door answered by
the place's authority.

## 2. Where libghostty-vt lives: in the plugin, as wasm

libghostty-vt builds for `wasm32-freestanding`: ghostty's build has a wasm
target for lib-vt, and its static archive builds too.
`nix/libghostty-vt-wasm.nix` calls ghostty's own `nix/libghostty-vt.nix`
(pinned in npins as `ghostty`) with `-Dtarget=wasm32-freestanding`,
`simd=false` and `ReleaseSmall`. The derivation installs `libghostty-vt.a`
plus the C headers, and both shells export the prefix as
`WEFT_GHOSTTY_VT_WASM`. In `build.zig`, a guest marked `.ghostty_vt = true`
gets the headers on its include path and the archive in its link. Only
`terminal` is marked.

So the emulator runs inside the terminal plugin's own sandbox. Its callbacks,
such as the one answering the child's device-attribute query, are ordinary
function pointers within that module. No native emulator door was needed.

One patch is applied. Upstream's freestanding logger imports `env.log`, but
weft's preflight refuses any import outside `weft:abi/*`. The derivation
renames the call to `ghostty_wasm_log`, and the plugin defines it
(`src/plugins/terminal/c.zig`, hidden).

Cost: `terminal.wasm` is about 720 KB, against about 170 KB for `vim.wasm`.

## 3. Rendering: a grid entry

A terminal screen is not text. There is no rope, no history, and it may
redraw sixty times a second. So core gained a second kind of text-less entry
next to projections: **a grid** (`core/grid.zig`, `Buffer.grid`).

- **Publishing.** `wl_grid_publish(name, msg)` applies one message to the
  plugin's own text-less entry, and creates the entry if it does not exist.
  The layout is in `membrane/grid.zig`: a 16-byte header (size, cursor
  position and shape, rows sent), then the changed rows only. Each row is an
  index followed by 16-byte cells: codepoint, fg, bg, attributes, width.
- **Colours** are raw RGB, or one of two theme values, `theme_fg` and
  `theme_bg`. This is the one render door that carries RGB, because 256-colour
  and truecolor output has no theme role to map onto. Plain output still takes
  the theme's colours, and reverse video swaps the theme's pair.
- **Attributes:** bold, italic, faint, underline (single and double
  distinguished; curly, dotted and dashed draw as single), strike, overline
  and invisible. Wide characters are supported.
- **Snapshot-frame rules** (doc/model.md §2.7): `capturePane` copies the grid
  into the frame arena. `gfx/view/grid.zig` draws that copy, so no guest runs
  during layout or drawing. Each row is drawn as merged background rects plus
  one mono cell run per face (regular, bold, italic, both), on the same cell
  geometry as text rows. The cursor is the grid's own, in the shape the VT
  reports (block, bar, underline or hollow), and blinks with the head.
- **Size.** After each frame, the room the pane had goes into `Buffer.extent`
  (cols, rows, cell pixels). If it changed, the owner's `on_poll` fires *after*
  the frame (`notifyExtents`), and the owner reads it with `wl_entry_extent`.
  The terminal then resizes the emulator and the pty, and the child gets
  SIGWINCH.

**Dirty rows.** The plugin reads ghostty's render state and republishes only
the rows it marks dirty. Everything is republished after a resize or a
scroll.

**Measured** with `WEFT_BENCH_TERMINAL=1 zig build test-only
-Dtest-filter=bench/terminal -Doptimize=ReleaseFast`. The frame times below
cover a full composite: read, emulate, publish, build and CPU raster.

| case | time to reach the screen | frames | per-frame time |
|---|---|---|---|
| `yes \| head -n 200000` | 48 ms | 5 | p50 8.7 ms, max 15.7 ms |
| `ls -R /nix/store \| head -n 100000` | 539 ms | 84 | p50 4.8 ms, p90 12.8 ms |

- Each wake digests at most 256 KiB, so a flood draws as it goes rather than
  one frame waiting on all of it.
- A frame with the panel full of 40 coloured rows has a median of 4.2 ms,
  against 3.7 ms for the problems list in the same panel.

## 4. Keys: capture

The terminal's entry declares the capture posture
(`wl_declare_capture("terminal.input")`,
contextual-workspace-architecture.md §10.4). This is capture's first
consumer.

**Routing.** `app/dispatch.captureKey` runs after the interaction layer and
before everything else, including dot-repeat, chords and which-key. Every key
on a capturing entry runs the endpoint with the key's spec and committed
text. The exception is the grammar's **break-out chord**: the binding whose
arms name `std.input.break-out`, found by `Keymap.breakOutMatch` through the
binding mode's fallback chain and `global`.

- Under vim, helix and ide the break-out is `C-\`.
- Under emacs it is `C-c C-\`. There the `C-c` is held as a pending prefix.
  If the next key is not `C-\`, both keys go to the terminal, in order. A lone
  C-c still interrupts, one key late, as in emacs's own `term`.

Breaking out leaves you in the terminal's pane, in the grammar's own mode,
with the endpoint kept. Two ways back in, neither terminal-specific:

- **A click in the pane body.** `pointer.click` on an entry that can resume
  a capture (`Buffer.canResumeCapture`) resumes it, as focusing any IDE's
  terminal does.
- **The `std.input.resume` intention** (`mode.resume-capture`), a core offer
  that is absent unless there is a capture to resume. vim and helix bind it
  ahead of their own insert on `i` and `a`, as in vim's `:terminal`; on any
  other entry the key's next arm, insert, runs.

C-` and the leader chord still reopen the terminal and capture again.

Only an entry's maker may declare capture on it. Otherwise any plugin could
make an entry into a keylogger.

**Encoding.** The plugin parses the spec into a ghostty key event
(`keys.zig`): the physical key, its modifiers, and the unmodified text.
ghostty's key encoder then produces the bytes from the terminal's current
modes, including application cursor keys, the kitty keyboard protocol when
the child negotiates it, and alt-sends-escape.

The terminal keeps three keys for itself, as terminals do:

- S-Prior and S-Next page through the scrollback.
- C-S-v and S-Insert paste the clipboard. Unsafe control bytes are stripped,
  and the paste is bracketed when the child asked for bracketed paste (mode
  2004). The shipped configs grant `terminal` the clipboard permission.

**The wheel** does one of three things:

- When the child enabled mouse tracking, the wheel is sent to it as a mouse
  report.
- On the alternate screen, it sends arrow keys, so a pager scrolls.
- Otherwise it scrolls the scrollback.

**Getting back in.** C-` (or `SPC o t`) captures again. Focusing the panel by
another route keeps whatever posture the entry was left in.

## 5. What stayed

- `terminal.session` is still published on the place the shell starts in.
- `[process exited N]` is written onto the screen, and the next key or C-`
  starts a fresh shell below it.
- The panel integration is unchanged (`viewport.take`, C-j).

The line-mode path is deleted from the plugin, along with its `terminal`
mode, its input line, and `TERM=dumb`/`--noediting`.

`repl` and `console` stay on `repl_session`. They are comint buffers: text a
person edits and searches, with output appended as a CRDT peer. That is a
different thing from a screen, so moving them is not a rename.

## 6. Not done

- **A remote pty.** A shell in a peer's or ssh's place needs the pty door
  answered by that place's authority (§1).
- **Selecting and copying text with the mouse.** ghostty has a selection API
  (`GHOSTTY_TERMINAL_OPT_SELECTION`, the formatter). What is missing is a
  pointer door carrying the cell under the pointer: `wl_pointer` gives a byte
  offset, which a grid has none of.
- **Clicks and drags to the child** when it tracks the mouse. The wheel is
  reported at the cursor's cell, not the pointer's, for the same missing
  reason.
- **Kitty graphics, hyperlinks (OSC 8), title and cwd (OSC 0/7)**, and a
  terminal status segment.
- **Multiple terminals.** There is one `*terminal*` per editor.

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

A terminal is used like the rest of weft: there may be several, each an
ordinary entry (§4); out of capture its screen and scrollback are text the
grammar's own keys read (§6); a shell tells it where its prompts are and
where it is (§7); and at a prompt the command line is a field the grammar
edits, keys going to the program only where the program DECLARED it wants
them (§8) — so the break-out chord is rarely needed.

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

A terminal screen is not text first. It may redraw sixty times a second, and
what it shows is cells with colours. So core has a kind of entry next to
projections: **a grid** (`core/grid.zig`, `Buffer.grid`). Its text — the
cells as a read-only document — is derived from it, and only while someone
reads it (§6).

- **Publishing.** `wl_grid_publish(name, msg)` applies one message to the
  plugin's own grid entry, and creates the entry if it does not exist.
  The layout is in `membrane/grid.zig`: a 16-byte header (size, cursor
  position and shape, rows sent), then the changed rows only. Each row is an
  index followed by 16-byte cells: codepoint, fg, bg, attributes, width, and
  a mark (what the program said the cell is: prompt, typed input, or
  output — the shell integration marks it).
- **Sections.** After the rows a publish may carry tagged sections, each
  framed by its tag and length and skipped by a reader that does not know it:
  `title` (the entry's label, a terminal's OSC 0/2 title — `Buffer.title`)
  and `history` (rows that scrolled off the top of the screen: how many to
  drop from the oldest end, then the new rows, each its own cell count).
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
  (cols, rows, cell pixels, and whether the pane READ the entry as text —
  §6). If it changed, the owner's `on_poll` fires *after* the frame
  (`notifyExtents`), and the owner reads it with `wl_entry_extent` (ten
  bytes: five `u16`s, the last the flags). The terminal then resizes the
  emulator and the pty, and the child gets SIGWINCH.

**Dirty rows.** The plugin reads ghostty's render state and republishes only
the rows it marks dirty. Everything is republished after a resize or a
scroll.

**Measured** with `WEFT_BENCH_TERMINAL=1 zig build test-only
-Dtest-filter=bench/terminal -Doptimize=ReleaseFast`. The frame times below
cover a full composite: read, emulate, publish, build and CPU raster.

| case | time to reach the screen | frames | per-frame time |
|---|---|---|---|
| `yes \| head -n 200000` | 44 ms | 4 | p50 12.8 ms, max 19.8 ms |
| `ls -R /nix/store \| head -n 100000` | 481 ms | 77 | p50 4.2 ms, p90 11.8 ms |
| `yes …`, read (broken out, §6) | 159 ms | 4 | p50 51 ms |
| `ls -R …`, read (broken out, §6) | 2075 ms | 64 | p50 5.3 ms, p90 84 ms |

- The first two rows are the terminal capturing, as before this document's
  §6 existed, and still scanning the stream for the shell's marks (§7, §8):
  48 and 539 ms before this work. History is not copied while nothing reads it.
- The last two are the flood with the terminal READ as text: every wake also
  sends the rows that scrolled into the scrollback and core keeps the
  document in step. `ls -R` turns over ~2500 wide rows a wake; the cost is
  the rows' cells and their text, not the CRDT (below).
- Each wake digests at most 256 KiB, so a flood draws as it goes rather than
  one frame waiting on all of it.
- A frame with the panel full of 40 coloured rows has a median of 4.1 ms,
  against 4.5 ms for the problems list in the same panel.

## 4. Several terminals, and a header that lists entries

The plugin holds one emulator and one pty per terminal (`Term` in
`plugins/terminal/root.zig`), never globals. Each terminal is an ordinary
entry: `*terminal*`, `*terminal:2*`, … designated
`weft://here/proc/terminal.N`, where N counts up for the whole run and is
never reused, so a designation always names one shell.

- `terminal.open` shows the terminal used last, starting one when there is
  none. Given a designation — the plugin is the `proc.terminal` opener — it
  shows that terminal while its shell lives and refuses once it has gone.
- `terminal.new` always starts another.
- Either takes the entry into the viewport named by the `viewport` setting
  (`panel`), through core's `viewport.take`; `none` leaves it in the editor,
  where it is a document with an editor tab, like any entry, and can be
  split.
- Closing a terminal's entry hangs its shell up. Core bumps
  `Buffers.grid_closes` when an entry holding a grid closes, and that wakes
  the grid's owner (`on_poll`), which lets go of whatever fed the entry.

**A viewport header of entries** (`core/viewport.zig`). A docked
viewport's `tabs` may contain, besides command ids, a line `entries` or
`entries:<maker>`. At that place the header lists the entries the viewport
has held that are still open (`Declaration.held`), all of them or only those
the named plugin made:

- labeled by the entry — `Buffer.title` when its maker set one (a
  terminal's OSC title), else its name;
- iconed like the command that opens its designation's kind (the terminal's
  opener, `terminal.open`);
- a click shows the entry in that pane (`Panes.show`: a docked panel owns its
  entry against a plain `buffer.switch`); its × closes it, and the pane shows
  the newest held entry left;
- an entry an ordinary pane shows is let go — in the editor it is a
  document again — and a header that stops listing entries forgets them.

A command tab of the same maker is lit only when no entry tab is: "+ New
Terminal" is not what the panel shows when a terminal is. `config/panel.js`
declares `["problems.open", "entries:terminal", "terminal.new"]`. Nothing
here knows what a terminal is: any plugin's entries can be listed so.

## 5. Keys: capture

Capture is what a terminal does while its program owns the keys — always,
without shell integration; with it, whenever the program declares so (§8).
At a shell's prompt the grammar has the keys instead.

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

- **A click in the pane body.** A press on an entry that can resume a
  capture (`Buffer.canResumeCapture`) marks the gesture, and its release
  (`up-mouse-1`, `pointer.release`) resumes the capture — unless the press
  became a drag, which selects the text instead (§6). As focusing any IDE's
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

## 6. Terminal-normal: the grid read as text

Out of capture — after the break-out chord, or whenever a terminal is not
capturing — the screen and its scrollback are a READ-ONLY TEXT DOCUMENT, so
the grammar's own keys work on them unchanged: vim and helix motions, `/`
search, snipe, visual selection and yank (with its flash), the pointer's
drag-select, ide's selection and C-c. Nothing of this knows what a
terminal is; it is what a grid entry is.

**The document is derived from the cells** (`core/grid_mirror.zig`). Row
`i` of the grid — its history, then its screen — is line `i` of the
document, and a cell's text is `grid.cellText` (its scalar, a space for an
empty cell, nothing for the second half of a wide one), trailing blanks
dropped. So an offset names a cell, and the one function both the document
and the view read is the only place that could disagree.

- **Written only while read.** A publish on an entry that is not capturing
  brings the document up to date; so does leaving capture
  (`grid_mirror.enterReading`, run by `mode.break-out`), which also puts the
  caret where the program's cursor is. While a program takes every key,
  nothing moves a caret through its output, and a flood is not copied twice.
- **History only when read.** The frame tells the owner whether its pane
  reads the entry (`Extent.reading`, `wl_entry_extent`'s flags). Only then
  does the terminal send its scrollback: the rows that scrolled up past the
  newest one core holds, found through a tracked ghostty grid reference that
  follows the scrollback as it moves, and how many of the oldest the
  scrollback dropped. A resize, a clear, or a reference ghostty lost sends
  all of it again (`reset`). The rows are read a viewport at a time through
  the render state, so their colours are resolved as the screen's are.
  `core.grid` keeps them end to end in one store, not an allocation a row.
- **Written as a producer, minimally.** `Document.produce` edits the main
  replica directly and logs the commit as `.producer`: no undo log owns it,
  and it is LEAN — positions without text — so output streamed through the
  document never piles up in its log. Only the change is written: rows gone
  from the front cut, rows scrolled up appended, and the screen's common
  prefix and suffix kept, so a caret or a selection in the scrollback holds
  still under new output. A peer shadow (`renderInto`) was the first cut and
  cost seconds per flood wake — bootstrapping and merging a replica of a
  large document; direct edits cost milliseconds.
- **Re-founded now and then.** A CRDT keeps every scalar that passed through
  as an event and what scrolled away as a tombstone. Past 64 Ki events the
  document is re-founded on its text (`Document.refound`: a bulk load, one
  base event, ~1 ms per MB; `compact` took seconds for the same). Anchors
  and the commit log are local and survive; the text did not move.
- **Posture.** A grid's document is text (`Buffer.posture` derives `.text`
  for a grid with a document, read-only as it is): vim's `V` is a line
  selection, not a listing's rows. Edits are refused (`read_only`: "terminal
  output").

**Drawn as the terminal** (`gfx/view/grid.zig`). The frame snapshot of a
READ grid is the rows its document's scroll shows (`Grid.snapshotRows`,
settled around the caret before capture), history or screen alike, drawn
cell by cell as ever — colours and attributes kept. The view builds the
pane's geometry map from the cells (`grid.layoutRows`: a caret stop at every
cell with text, at its x), so the text machinery's selection washes, flash
and hit-testing land on cells, and the caret is drawn as the grid's cursor at
its cell, in the shape the grammar's mode asks for.

**Back in.** `i` (vim, helix), a click, or C-` resume capture as before; a
drag in the pane selects instead of resuming.

## 7. Shell integration

A shell tells its terminal where its prompts are, when a command runs and
ends, and where it is — if something asks it to. weft asks automatically,
as ghostty, kitty and VS Code do. `weft.set("terminal", "integration",
"off")` opts out; a `shell` setting that is a whole command line (anything
with a space) is run as written, uninjected.

**Injection** (`src/plugins/terminal/shell/`, packaged by
`nix/shell-integration.nix` so it reaches the runtime; the plugin bakes the
path in at build time — `build.zig`'s `terminal_build.shell_integration`,
from `WEFT_SHELL_INTEGRATION` — and the same variable in the environment
overrides it at spawn). A bare shell program starts through `launch`:

- **zsh**: `ZDOTDIR` points at weft's `zsh/`. Its `.zshenv` puts the user's
  `ZDOTDIR` back (unset when they had none), sources the user's `.zshenv`,
  and loads `weft-integration.zsh` into an interactive shell; zsh then reads
  the user's `.zshrc` from the restored `ZDOTDIR` as it would have. The
  integration sets itself up at the first prompt, after the user's config,
  so its marks wrap the prompt the user chose, and its precmd hook goes last.
- **bash**: `--rcfile bash/weft.bash`, which sources `~/.bashrc` first, as an
  interactive bash would have, then sets `PROMPT_COMMAND` (first, to see the
  status) and `PS0`.
- **fish**: weft's directory goes first on `XDG_DATA_DIRS`, so fish sources
  `fish/vendor_conf.d/weft.fish`, which puts `XDG_DATA_DIRS` back and wraps
  `fish_prompt` at the first prompt (its `fish_title` too, unless the
  user defined one).

Each then sources `${XDG_CONFIG_HOME:-~/.config}/weft/shell/<shell>` when it
exists: the user's own hook. `TERM_PROGRAM=weft` stays, for an rc file to
test, as `INSIDE_EMACS` is tested.

The scripts are weft's own (MIT). Ghostty's, pinned in npins, were read for
the injection technique but not copied: its zsh and bash integrations are
GPLv3, derived from kitty's, so reusing them would put GPL code in weft's
tree.

**What the shell says, and what weft does with it:**

| sequence | from | becomes |
|---|---|---|
| OSC 133 A / B | around the prompt | the cells' marks (`Cell.mark.prompt`, `.input`), read from ghostty's semantic content |
| OSC 133 C / D;N | a command starts / ends | (the key routing of §8) |
| OSC 7 `file://host/path` | every prompt, every `cd` | the `cwd` section: the entry's PLACE becomes that directory (`followCwd`, through `place.Realizer.placeOf`), so a relative file opened from it, or a new terminal started from it, is where the shell is |
| OSC 0/2 | the title | the `title` section: `Buffer.title`, the tab's label |

**Landmarks.** A row that starts a prompt — a prompt row under a row that is
not all prompt, so a two-row prompt is one landmark and a command that
printed nothing does not merge two — is a LANDMARK
(`grid_mirror.landmark`). In a terminal read as text:

- `std.navigation.landmark-prev` / `-next` move the caret to the previous or
  next prompt, at the start of its command line (`grid.landmark-prev`,
  `grid.landmark-next`);
- `std.selection.landmark-body` selects the output of the command at the
  caret: the rows after its command line up to the next prompt, trailing
  blank rows left out (`grid.select-landmark-body`).

Core offers the three only on an entry with landmarks, so a grammar binds
the word and every other entry's key keeps its meaning: vim and helix `[[` /
`]]` and `SPC t o`, ide C-Up / C-Down (as VS Code's terminal), emacs
`C-c C-p` / `C-c C-n` / `C-c C-o` (as comint).

## 8. Who has the keys: routed by what the program declared

A terminal cannot know whether a program "uses" a key: a byte stream says
nothing of the sort. What it can know is what the program DECLARED, so
that is all keys are routed by.

**The state machine.** The terminal plugin declares, in every publish that
changes it, an `input` section (`membrane/grid.zig` `InputHead`); core keeps
it (`Grid.input`) and routes by it. The user's own break-out overrides it.

```
                        program declares                  user
  OWNS_KEYS  ─ no integration that syncs its line   ─┐
             ─ a command running (OSC 133 C..D)      │   C-\ (break-out)
             ─ alternate screen / kitty keyboard /   ├──────────────────► BROKEN OUT
               mouse tracking                        │   ◄──────────────── i, a, click, C-`
  PROMPT     ─ at a prompt (after OSC 133 B), its    │   (resume)
               line known, none of the above        ─┘

  OWNS_KEYS   → capture: every key raw to the program but the break-out chord
  PROMPT      → the grammar has the keys and edits the command line as a field
                of the entry's text, with undo; the keys the program CLAIMS
                (Tab, S-Tab, Return, KP_Enter) and the keys the grammar binds
                to nothing go to the program, each after the line
  BROKEN OUT  → terminal-normal (§6): read-only text; the program's state is
                not followed until resumed
```

- **Declared, never guessed.** The plugin computes OWNS_KEYS from ghostty's
  modes (`altScreen`, `kittyFlags`, `mouseTracking`) and the OSC 133 marks
  it watches on the byte stream (`prompt.Scanner`); nothing else. Kitty
  keyboard flags count only when set and not the ones the line editor had
  at its B mark: fish pushes its own to read its line, and pops them while
  it runs a binding — neither is a program claiming the keys.
- **Capture follows the program** (`Buffer.followProgram`, run on every
  publish): OWNS_KEYS declares capture, PROMPT releases it, BROKEN OUT
  (`Buffer.broken_out`) holds both off. `wl_declare_capture` sets the
  endpoint and takes the entry back from a break-out; resuming at a prompt
  leaves the grammar the keys and puts the caret in the command line.
- **The head rests** where the grammar declares for what the entry now is
  (`restingModeFor`): capture's mode when a program takes the keys, the text
  mode at a new prompt (vim and helix normal: `i`, `a` start typing as in any
  text; ide and emacs type directly).
- **Without integration** — a whole command line as `shell`, `integration`
  off — nothing is ever declared, and
  the program owns every key: capture, as before.

**The command line is a field** (`core/grid_mirror.zig`). At a PROMPT the
declaration carries where the line starts (the cursor at OSC 133 B: screen
row and cell) and, when it is the program's word — a new prompt, or a change
the shell made itself (completion, history) — the line and its cursor.

- The field is that row's line in the entry's document, from the prompt's
  last cell to its end (`fieldRange`). `writeRefusal` is the one edit gate
  for a grid entry: only the field takes edits, on its one line — typing,
  vim operators, undo alike (`Context.edit`, `editEach`, `admitUndo`). An
  undo that would reach a line long since run is refused.
- Edits are the user's, so undo is the grammar's own. The mirror keeps the
  field row as the editor holds it (`Grid.field_text`: the prompt from the
  cells, blanks kept, then the field), whatever the shell echoes meanwhile.
- After every key (`app/dispatch.flushField`), a changed line reaches the
  program: the endpoint runs with an empty key, the line and the caret's
  byte in it; the plugin sets the shell's line only when it differs from
  what it last set. A claimed or unbound key runs the endpoint with the key
  after the same line (`toProgram`).

**The line protocol** (`src/plugins/terminal/prompt.zig`, the integration
scripts):

| direction | bytes | meaning |
|---|---|---|
| shell → weft | `OSC 7780;hello;V` | this integration syncs its line; V 2 takes a set in band |
| shell → weft | `OSC 7780;line;SEQ;CURSOR;HEX` | the line buffer (hex of its bytes), the cursor in bytes, the last set it applied |
| weft → shell | `ESC [ 7780 ~ SEQ;CURSOR;HEX BEL` | set the buffer and the cursor |
| weft → shell | `ESC [ 7781 ~` | report now |

The two keys are bound in EVERY keymap — zsh's `emacs`, `viins` and `vicmd`
widgets (`_weft_set_line` reads the payload with `read -k`, which reads
through zle), bash's `emacs`, `vi-insert` and `vi-command` (`bind -x`,
`READLINE_LINE`/`READLINE_POINT`) — so a line lands whatever keymap the
shell is in; zsh in vi mode is tested. zsh reports on every redraw
(`zle-line-pre-redraw`); bash has no redraw hook, so it reports when asked,
after each key weft sends that does not end the line. A report older than
weft's last set (by SEQ) is a stale echo and ignored; one that differs from
what weft set is the shell's own change, and is declared as the program's
word. A B mark while already at a prompt (bash redisplays it after a set;
fish marks every prompt twice, natively and ours) is the same prompt, until
a line ends (OSC 133 C, or a key that ends it). A key that went raw to the
line editor — typed ahead while a command ran, or at a prompt not yet
declared — asks for a report, and no prompt is declared while any asked-for
report is outstanding (`Shell.awaiting`): the field starts with what the
shell actually holds.

**fish** (hello version 2) cannot read further input inside a key binding,
so a set goes in band: ctrl-alt-shift-F10 (`CSI 21;8~`) empties the command
line (and puts a vi mode into insert), the payload types in as text, and
ctrl-alt-shift-F12 (`CSI 24;8~`) takes it back out and sets the real line
with `commandline -r` / `-C`; ctrl-alt-shift-F11 (`CSI 23;8~`) asks for a
report. fish 4 names only keys it knows, so a private `CSI 7780 ~` would be
dropped.

## 9. What stayed

- `terminal.session` is still published on the place the shell starts in.
- `[process exited N]` is written onto the screen, and the next key or C-`
  starts a fresh shell below it.
- The panel integration is unchanged (`viewport.take`, C-j).

The line-mode path is deleted from the plugin, along with its `terminal`
mode, its input line, and `TERM=dumb`/`--noediting`.

`repl` and `console` stay on `repl_session`. They are comint buffers: text a
person edits and searches, with output appended as a CRDT peer. That is a
different thing from a screen, so moving them is not a rename.

## 10. Not done

- **A remote pty.** A shell in a peer's or ssh's place needs the pty door
  answered by that place's authority (§1).
- **Clicks and drags to the child** when it tracks the mouse. The wheel is
  reported at the cursor's cell, not the pointer's.
- **Soft-wrapped lines** are one document line per ROW: a long line wrapped
  by the terminal yanks with a line break where it wrapped, and a search
  does not match across the wrap.
- **Search matches** are not highlighted on the cells; the caret lands on
  them.
- **Kitty graphics and hyperlinks (OSC 8)**, and a terminal status segment.
- **OSC 7's host is not checked.** A shell on another machine (over ssh)
  reporting its directory moves the entry's place to the local directory of
  that name, when there is one.
- **The command line is one row.** A line longer than the row its prompt
  starts on wraps in the shell's echo; the field is the first row's line,
  so the continuation rows mirror the echo beside it. A right prompt
  (zsh's `RPROMPT`) on the line's row reads as part of the field.
- **vim and helix rest in normal mode at a new prompt**, as in any text:
  `i`/`a` type. No grammar declares a "typing" resting mode, and declaring
  one for the field posture would change how every editable listing rests.

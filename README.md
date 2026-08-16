# weft

> **weft** |wɛft| *n.*
> 1. the crosswise threads on a loom, woven over and under the warp to
>    make cloth.
> 2. a thing woven together from many threads.

An editor woven through existing stock: [stemma](https://github.com/psyclyx/stemma)
(the CRDT/rope library) and [snail](https://github.com/psyclyx/snail)
(GPU text rendering), presented natively on Wayland + Vulkan. stemma and
snail are the warp; weft is the pass that binds them into an editor.

## The inversion

A buffer is a CRDT replica and **every mutator is a peer** — the user,
plugins, host agents, remote collaborators. Local solo editing is the
degenerate case (one replica, no sync). Structurally, not by discipline:

- The input → commit-op → render path never blocks and never awaits;
  there is no buffer lock to take.
- Plugins work against immutable versioned snapshots and submit ops
  against the version they read; the CRDT merges them like a concurrent
  collaborator. "Buffer changed during operation" is not expressible.
- Undo emits inverse ops for *own* operations (per-peer selective undo),
  never state restoration.
- Positions are anchors — stable CRDT identities. No bare integer offset
  crosses a public API boundary without the version it is valid at.
- Everything user-visible is built through the public ABI. If built-in
  file support can't be a plugin, the core is wrong.

## One layout model

Text placement is a single primitive with two degenerate ends, not two
code paths. Every visible line is laid out into runs and caret **stops**
by one function; the same stops feed both the rendered picture and the
source-offset ↔ geometry map (motion, hit-testing, caret, selection).

- **Plain buffers** place each line on the monospace cell grid — uniform
  advances, pixel-crisp columns. This is the degenerate case: `stop.x ==
  margin + col*cell_w`, proven by a parity test.
- **Markdown buffers** place proportional runs at varying faces and
  sizes: headings scale, `**bold**`/`*italic*`/`` `code` ``/`[links]`
  style inline, lists/quotes/fenced-code/rules render as blocks — live,
  while the source rope stays plain markdown.

Because motion reads pixel-x from that map (a sticky **goal-x**, not a
scalar column), vertical motion, click-to-place, drag-select, and
selection rectangles all work identically over monospace code and
proportional prose. The old scalar-column assumption is gone — monospace
is just the uniform-advance case of the general model.

Caret and selection are solid rectangles painted through one resident
unit-square record (an affine transform + color) — no extra pipeline.
The caret is configurable per mode (block/bar/underline) and blinks;
the sample vim config uses a block caret in normal mode and a bar in
insert.

## Status

MVP complete, plus live WYSIWYG markdown.

**Core ABI (`src/core/`).** `Document`: the inversion implemented
literally — plugin peers hold shadow CRDT replicas; snapshot → edit own
replica → commit merges the batch like a remote collaborator. Commit log
of composed patches (inserted *and* removed bytes: every commit is
invertible) + version tokens; pull-based causal subscription;
auto-shifted local anchors and portable identity anchors. `undo`:
per-peer selective undo by op inverse, rebased over concurrent traffic.
`Editor`: cursor/selection as anchors, scalar-step motion, view-computed
vertical motion (goal-x), saving as a fallible poll-only task. `command`:
typed commands over a Lua-ready value ABI. `Keymap`: modal string tables
with fallback chains. `markdown`: a stateless inline+block analyzer that
publishes per-byte styling. `pick`, `task`, `layers` (the feed
substrate).

**Render (`src/gfx/`).** snail's analytic glyph pipeline on Vulkan (flat
curve/band texel buffers, SPIR-V from `snail-shaders-vk`). `view.zig`
owns the one-layout-model above; `layout.zig` is the offset↔geometry map.
Fonts resolve at runtime via **fontconfig** — a mono face for code plus a
sans family (regular/bold/italic/bold-italic) for prose, so markdown gets
real italics. Damage-driven rebuilds; frame + input-latency percentiles
log continuously.

**Scripting.** Each plugin is its own Lua 5.4 VM (fennel compiled in) and
its own Document peer. The config is a plugin named "config" with no
special powers. The Lua API is the global `weft`.

**Vim, as config.** `config/init.fnl` implements modal editing —
normal/insert/visual, operators as scripted compounds, a `space` leader
(`space f f` opens the fuzzy file finder), `:` for the command palette,
per-mode cursor styles — entirely through the public ABI. The core does
not know vim exists.

**Syntax (tree-sitter).** Grammars are pinned nixpkgs packages (parser
`.so` dlopened at runtime, highlight query embedded at build). The commit
log drives incremental reparse through a shared mirror; the view gets
class-per-byte paint over the visible range. Zig and Fennel wired.

**LSP.** A language server is a child process behind lock-free
reader/writer threads; all protocol work happens in a per-frame tick on
the main thread — the editor never waits on the server. Diagnostics tint
the text and surface in the status line; completion opens the `pick`;
goto-definition moves the cursor.

Property-tested (display-free, `zig build test`): 2-peer convergence
under stale-snapshot batches, identity anchors under adversarial
concurrency, subscription patch-replay, patch-composition oracle,
selective undo round trips, plugin VM integration, keymap modality,
save/load round trips, the monospace-parity gate, the offset↔geometry
map, and the markdown analyzer.

## Dependencies

Zig deps are **path deps into the monorepo checkout** (`../../lib/snail`,
`../../lib/stemma`). System libraries (wayland, libxkbcommon,
vulkan-loader, harfbuzz, tree-sitter, lua, and the build-time
wayland-scanner/pkg-config/slangc) come from the npins-pinned nixpkgs via
`shell.nix` — never the ambient PATH.

**Fonts are the deliberate exception.** weft resolves faces through
fontconfig against the *system's* installed fonts (so you get your
configured sans/mono with real italics). Rendered frames therefore depend
on what's installed — a break from the otherwise-hermetic pinning,
accepted because fonts are cosmetic. The embedded DejaVu mono is a
last-resort fallback, and `--font` overrides the mono face.

```sh
nix-shell          # or direnv allow  (provides fontconfig, harfbuzz, …)
zig build run      # open the window
zig build test     # display-free tests
```

## Config

The binary looks up `$XDG_CONFIG_HOME/weft/init.fnl` (else
`~/.config/weft/init.fnl`) read-only; a missing config means built-in
modeless defaults. `--config` overrides the lookup. The in-repo sample
config — vim implemented as config — is the development entry point:

```sh
zig build run -- --config config/init.fnl README.md
```

Open a `.md` file to see live markdown; open a `.zig` file for
tree-sitter highlighting over the monospace grid.

## Headless testing

The render path is verified without a desktop: a headless sway
(`WLR_BACKENDS=headless`, a fixed output) hosts the window, `grim`
captures frames, `wtype` injects input. Assert on layout geometry (caret
x, line heights) rather than pixel-exact glyphs, since fontconfig makes
glyph coverage machine-dependent.

## Remote workflow

Every weft is a peer — there is no separate agent binary. Host a document
from a headless machine with the same executable (the window/Vulkan half
is simply never initialized):

```sh
weft --headless --listen 7777 --token SECRET --lsp zls path/to/file.zig
```

and open it from anywhere (`file.zig` is a name hint — nothing is read
locally; content, ops, and the host's LSP diagnostics arrive over the
encrypted wire; tree-sitter runs locally on your replica):

```sh
weft --connect host:7777 --token SECRET file.zig
```

Two editors can also pair directly (`--listen` in one, `--connect` in the
other). The status line shows link liveness; partitions heal as one
frontier exchange. Protocol spec: doc/wire.md.

## Not yet

Markdown tables and images want 2D block layout (column measuring, image
decode) beyond the per-byte inline model — the next render workstream.

# scion

> **scion** |ˈsʌɪən| *n.*
> 1. a young shoot or twig of a plant, especially one cut for grafting
>    onto existing stock.
> 2. a descendant of a notable family.

An editor grafted onto existing stock: [stemma](https://github.com/psyclyx/stemma)
(the CRDT/rope library) and [snail](https://github.com/psyclyx/snail)
(GPU text rendering), presented natively on Wayland + Vulkan.

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

## Status

MVP complete — all six milestones landed.

**Core ABI (`src/core/`).** `Document`: the inversion implemented
literally — plugin peers hold shadow CRDT replicas; snapshot → edit own
replica → commit merges the batch like a remote collaborator's. Commit
log of composed patches (inserted *and* removed bytes: every commit is
invertible) + version tokens; pull-based causal subscription;
auto-shifted local anchors and portable identity anchors. `undo`:
per-peer selective undo by op inverse, rebased over concurrent traffic
(balanced undo/redo pairs skip transforms — linear undo is exact).
`Editor`: cursor/selection as anchors, scalar-step motion, saving as a
fallible poll-only task (temp+rename), loads via a `host.fs` peer.
`command`: typed commands (comptime-derived schemas) over a Lua-ready
value ABI, with late-binding names. `Keymap`: modal string tables with
fallback chains and per-mode text commands. `task`: no-await-on-hot-path
enforced mechanically (poll-only handles, lock-free injector, futex
parking, Debug hot-section fence). `pick`: the fuzzy-select primitive
(the command palette is one client; configs get `scion.pick`).

**Render (`src/gfx/`).** snail's analytic glyph pipeline on Vulkan
(flat curve/band texel buffers, one pipeline per shape family; SPIR-V
from `snail-shaders-vk`, contract from the committed reflection ABI).
Monospace cell grid with pixel-exact columns; cursor/selection/HUD are
block-glyph runs behind the text — one atlas, no extra pipelines.
Damage-driven rebuilds; frame + input-latency percentiles log
continuously. Measured (ReleaseFast, sustained typing): 60fps
vsync-locked, RSS < 100MB.

**Scripting.** Each plugin is its own Lua 5.4 VM (fennel compiled in)
and its own Document peer. The config is a plugin named "config" with
no special powers. Everything user-visible routes key → keymap →
command ABI; built-ins are registered commands like everything else.

**Vim, as config.** `config/init.fnl` implements modal editing —
normal/insert/visual, operators as scripted compounds, space-leader
command palette — entirely through the public ABI. The core does not
know vim exists.

**Syntax (tree-sitter).** Grammars are pinned nixpkgs packages (parser
`.so` dlopened at runtime, highlight query embedded at build). The
commit log drives `ts_tree_edit` through a shared mirror (shadow rope =
old coordinates per patch) plus one incremental reparse; the view gets
class-per-byte paint over the visible range. Zig and Fennel wired;
languages register by extension.

**LSP.** A language server is a child process behind lock-free
reader/writer threads; all protocol work happens in a per-frame tick on
the main thread — the editor never waits on the server. The same mirror
feed becomes incremental `didChange` (UTF-16 ranges against the
pre-patch shadow; full-sync fallback honors the server's capability).
Diagnostics tint the text and surface in the status line (count +
message under cursor); completion opens the `pick`; goto-definition
moves the cursor. `.zig` files attach `zls` from the dev shell.

Property-tested (display-free, `zig build test`): 2-peer convergence
under stale-snapshot batches, identity anchors under adversarial
concurrency, subscription patch-replay reconstructing every version,
patch-composition oracle, solo + concurrent selective undo round trips,
plugin VM integration, keymap modality, save/load round trips.

## Dependencies

Zig deps are **path deps into the monorepo checkout** (`../../lib/snail`,
`../../lib/stemma`) — the phasekeep app pattern: local development never
round-trips through GitHub. Once `psyclyx/stemma` is pushed, both become
url+hash pins in `build.zig.zon` (the escarghost pattern) so this repo
builds standalone from a clone, and the monorepo continues to override
them to local checkouts through its workspace wiring. A nix package
(`nix/scion.nix`, goop's `zig build --system` pattern) lands at the same
time; until then the build is:

```sh
nix-shell          # or direnv allow
zig build run      # open the window
zig build test     # display-free tests (deps smoke, platform-free logic)
```

System libraries (wayland, libxkbcommon, vulkan-loader, harfbuzz, and the
build-time wayland-scanner/pkg-config/slangc) come from the npins-pinned
nixpkgs via `shell.nix` — never the ambient PATH.

## Config

The binary looks up `$XDG_CONFIG_HOME/scion/init.fnl` (else
`~/.config/scion/init.fnl`) read-only; a missing config means built-in
modeless defaults. `--config` overrides the lookup. The in-repo sample
config — vim implemented as config — is the development entry point:

```sh
zig build run -- --config config/init.fnl README.md
```

Without a config: plain editing, arrows/Home/End, `C-s` save, `C-z`/`C-y`
undo/redo, `C-space` mark, `C-q` quit. With the sample config: vim
normal/insert/visual, `space` opens the command palette.

## Headless testing

The render path is verified without touching a desktop: a headless sway
(`WLR_BACKENDS=headless`) hosts the window, `wtype` injects input
(single invocation per sequence — per-invocation virtual keyboards churn
the seat keymap), `grim` captures frames for inspection.

## Remote workflow (phase 2)

Every scion is a peer. Host a document from a headless machine:

```sh
scion-agent --listen 7777 --token SECRET --lsp zls path/to/file.zig
```

and open it from anywhere (`file.zig` is a name hint — nothing is read
locally; content, ops, and the host's LSP diagnostics arrive over the
encrypted wire; tree-sitter runs locally on your replica):

```sh
scion --connect host:7777 --token SECRET file.zig
```

Two editors can also pair directly (`--listen` in one, `--connect` in
the other). The status line shows link liveness (connected/degraded/
offline); partitions heal as one frontier exchange. Protocol spec:
doc/wire.md (trust model included — shared token, my-machines-only).
Huge files open as a partial-checkout viewer (chunked range fetches,
content-addressed cache); editable holes await the stemma proposal in
doc/stemma-holes-proposal.md.

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

Milestone 2 of 6: the core ABI (`src/core/`), living under the
milestone-1 shell (window + cleared frames + xkb input; typing edits a
real Document, rendering waits for milestone 3).

- `Document` — the inversion, implemented literally: plugin peers hold
  shadow CRDT replicas; snapshot → edit own replica → commit merges the
  batch like a remote collaborator's. Commit log of composed patches
  (with content) + version tokens; pull-based causal subscription;
  auto-shifted local anchors and portable identity anchors.
- `registry` — late-binding interned names (bind after reference,
  rebind through held handles).
- `command` — typed commands whose schema + validation wrapper are
  derived at comptime from ordinary Zig functions, over a Lua-ready
  value ABI.
- `task` — no-await-on-hot-path enforced mechanically: handles are
  poll-only (no wait/join exists), spawn is lock-free (Treiber injector
  + futex parking), plus a Debug hot-section fence.

Property-tested (display-free, `zig build test`): 2-peer convergence
under stale-snapshot batches, identity anchors under adversarial
concurrency, subscription patch-replay reconstructing every version,
and a patch-composition oracle. Upcoming: render path, editing +
per-peer undo, Lua/Fennel scripting, vim-as-config.

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

## Development config (from milestone 5)

The binary will look up `~/.config/scion/init.fnl` (XDG) read-only; a
missing config means built-in defaults. The in-repo sample config
(`config/init.fnl`) is the development entry point:

```sh
zig build run -- --config config/init.fnl
```

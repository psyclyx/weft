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

Milestone 1 of 6: wiring. The binary opens a Wayland window (xdg-shell,
hidpi-aware), presents cleared Vulkan frames (FIFO), and logs
xkb-translated key events (keysym + UTF-8 + modifiers — real keymap
handling, no toolkit). stemma and snail resolve and pass smoke tests.
Upcoming milestones: core ABI (Document/Registry/Command/Task), render
path, editing + per-peer undo, Lua/Fennel scripting, vim-as-config.

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

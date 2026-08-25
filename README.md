# weft

> **weft** |wɛft| *n.*
> 1. the crosswise threads on a loom, woven over and under the warp to
>    make cloth.
> 2. a thing woven together from many threads.

An editor built over [stemma](https://github.com/psyclyx/stemma) (CRDT rope),
presented on Wayland + Vulkan. stemma is the warp; weft weaves it into an
editor.

## Model

A buffer is a CRDT replica and every mutator is a peer: the user, plugins,
host agents, remote collaborators. Solo local editing is the degenerate
case — one replica, no sync. This is structural, not a convention:

- The input → commit-op → render path never blocks or awaits; there is no
  buffer lock.
- A plugin reads an immutable versioned snapshot and submits ops against
  the version it read; the CRDT merges them like a concurrent
  collaborator. "Buffer changed during operation" is not expressible.
- Undo emits inverse ops for a peer's *own* commits (per-peer selective
  undo), not state restoration.
- Positions are anchors — stable CRDT identities. No bare offset crosses a
  public API boundary without the version it is valid at.

## Authority

Every commit carries an author `Principal` (role: user, plugin, agent, or
remote) and lands through one grade-gated door, `Context.edit`. A document
grant is `view < edit < own`. A `view` peer's ops are never admitted to
shared state by any path — direct edit, peer commit, or replicated layer.
Attribution is load-bearing: a plugin's edits author as *its* peer, so the
user's selective undo spares them, and a view-grade document refuses them
without a ghost commit.

## Layout

Text placement is one primitive, not two code paths. Every visible line is
laid out into runs and caret *stops* by a single function; the same stops
feed both the rendered picture and the offset ↔ geometry map used for
motion, hit-testing, caret, and selection.

- Plain buffers place each line on the monospace cell grid — the
  uniform-advance case, where `stop.x == margin + col*cell_w` (a parity
  test asserts it).
- Markdown buffers place proportional runs at varying faces and sizes:
  headings scale; bold/italic/code/links style inline;
  lists/quotes/fenced-code/rules render as blocks — live, while the rope
  stays plain markdown.

Motion reads pixel-x from that map (a sticky goal-x, not a scalar column),
so vertical motion, click-to-place, drag-select, and selection rectangles
behave identically over monospace code and proportional prose. Caret and
selection paint as solid rectangles through one resident unit-square
record (affine transform + color); the caret style is per-mode
(block/bar/underline) and blinks.

## Extensibility

Everything user-visible is built through the plugin ABI (guest shim
`src/guest/weft.zig`, host membrane `src/core/wasm*.zig`) — a single door
grouped by permission: read (cursor/slice/tree/introspection), write
(`edit`, grade-gated), effects (async/proc/net, gated by declared perms),
admin (kv). A plugin declares its commands, capabilities, and perms in a
manifest; `describe()` runs with no authority, the host approves, then
`init()` runs and every runtime registration is cross-checked against the
manifest. An undeclared registration fails the load.

Dispatch is three tiers over one idea — resolve the best entry by context
and priority: a layered **keymap** (key → name; priority tiers, a fallback
chain, and a `global` layer that applies under every mode) → **actions** (an
abstract intent like `eval`/`format` that many plugins *provide* for, each
with a `when` predicate, resolved to a concrete command in the current
buffer) → the **command** registry (name → handler). Binding a key to an
action gives context-sensitive dispatch for free; the async capability
system (completion/hover/definition) is the same idea at a different
latency. See `doc/dispatch.md`.

Every plugin runs as **wasm**, sandboxed under wasmtime — nothing is linked
or trusted in-process. A guest reaches the editor only through host imports
granted after the manifest handshake (`src/core/wasm*.zig`; guest shim
`src/guest/weft.zig`); its edits land on the same grade gate, authored as
the plugin's peer. weft's binary carries **no catalog**: it ships modeless,
and knows nothing of vim.

The reference catalog (`src/guest/`, ~40 plugins) is authored in Zig against
the ABI with no core privilege — modal editing (`vim`, `helix`) with `:` ex
commands, motions/text-objects/operators, buffer-word completion, a
command/buffer palette and status line, a magit-style `git` and an editable
`dired` (both foldable model buffers), `grep`/`make`/`run`/`repl`/`console`,
tree-sitter (`structural`, `ts`) edits, autopair/comment/format, a
`which-key` overlay, notes, and project history — built to `.wasm` artifacts
installed under `lib/weft/plugins/`, external files a user loads by name.
Nothing is baked in; delete them and weft is a bare modeless editor.

Plugins load two ways, both behind the same handshake:

- `--plugin <name|path.wasm>` on the command line (repeatable).
- `weft.plugin(name)` from `config.js` — so a config brings up its own
  catalog with no flags.

User config is JavaScript. `config.js` runs in QuickJS-ng (compiled to
wasm32-wasi under wasmtime) and drives the editor through the `weft.*`
globals the embedding installs — including `weft.plugin` to load plugins —
the config plane crossing the same membrane, one tier down.

## Render (`src/gfx/`)

Skia is the sole renderer. `FrameBuilder` and `View` lower editor state into
Weft-owned scene data: explicit filled rectangles and positioned HarfBuzz
glyphs. The renderer does not know whether its Vulkan target is a desktop
swapchain or a standard offscreen image used by E2E capture.

- **skia** — a C++ shim (`src/gfx/skia/shim.cpp`, built with g++, linked
  against libskia) draws those items onto an `SkCanvas`
  (`SkFont`/glyph ids + `SkPaint` rects, reusing the same font bytes so
  metrics match). GPU path: Skia's Ganesh Vulkan backend
  (`GrDirectContexts::MakeVulkan`) sharing weft's `VkInstance`/device/queue;
  the result is copied into the swapchain image. When there is no dedicated
  GPU — or `WEFT_SKIA_CPU=1` is set — it falls back to Skia's CPU raster
  (`SkSurfaces::WrapPixels`), still presented through Vulkan. `WEFT_SKIA_DUMP=<path>`
  writes the first frame to a PPM for debugging.

`view.zig` owns the layout model above; `layout.zig` is the offset ↔
geometry map. `pickDevice` prefers a dedicated GPU and treats
llvmpipe/lavapipe/CPU as a last resort. The pinned build environment supplies
a deterministic DejaVu Sans Mono face to embed; `--font` may replace it. Proportional
prose faces resolve at runtime through fontconfig. Keeping both choices
outside `weft_text` lets another platform provide fonts without changing the
HarfBuzz shaping interface or the view. Rebuilds are damage-driven; frame and
input-latency percentiles log continuously.

## Syntax and LSP

Tree-sitter grammars are pinned nixpkgs packages: the parser `.so` is
dlopened at runtime, the highlight query embedded at build. The commit log
drives incremental reparse through a shared mirror; the view receives
class-per-byte paint over the visible range.

A language server runs as a child process behind lock-free reader/writer
threads; all protocol work happens in a per-frame tick on the main thread,
so the editor never waits on the server. Diagnostics tint the text and
surface in the status line; completion opens the pick; goto-definition
moves the cursor.

## Tests

Display-free (`zig build test`): 2-peer convergence under stale-snapshot
batches, identity anchors under adversarial concurrency, subscription
patch-replay, the patch-composition oracle, selective-undo round trips,
the authority invariants, the plugin ABI and wasm membrane (each catalog
plugin as `.wasm`, the perm handshake, `config.js` eval), keymap
modality, save/load round trips, the monospace-parity gate, the
offset↔geometry map, and the markdown analyzer.

## Build

The internal [stemma](https://github.com/psyclyx/stemma) library resolves to a
GitHub release pin by default, and `npins/sources.json` carries the same pin for
the nix layer. To iterate against a local checkout, set the override variable:

```sh
NPINS_OVERRIDE_STEMMA=../../lib/stemma zig build test
```

(The zon path twin is static, so the override must name the monorepo
location `../../lib/<name>` — anything else is a loud refusal, not a
silently ignored setting. Keep `build.zig.zon`'s pins and
`npins/sources.json` on the same tags.) System libraries — wayland, libxkbcommon,
vulkan-loader, harfbuzz, fontconfig, tree-sitter, wasmtime, and skia — resolve
through `pkg-config`; Skia's C++ shim is built with the shell's g++. The
QuickJS-ng source and the build-time wayland-scanner/pkg-config tools
— come from npins-pinned nixpkgs via `shell.nix`, not the ambient PATH.

Proportional fonts are the deliberate exception: runtime fontconfig resolves
them from the system, so prose rendering depends on configured fonts. The
default mono face is pinned with the build for deterministic editor geometry;
`--font` overrides it.

```sh
nix-shell          # or direnv allow
zig build run      # open the window (skia renderer)
zig build test     # display-free tests
```

## Config

`config.js` (JavaScript, evaluated in QuickJS) loads plugins and wires keys
and commands through the `weft.*` globals. A bare `zig build run` is
modeless; the in-repo sample config loads the reference catalog itself
(vim, the palette, …) via `weft.plugin`, so it is the development entry
point — no `--plugin` flags needed:

```sh
zig build run -- --config config/config.js README.md
```

Plugins resolve by name against the install dir (`lib/weft/plugins/`,
overridable with `$WEFT_PLUGIN_DIR`); a path ending in `.wasm` loads
literally. `--plugin vim` (repeatable) loads without a config at all.

Open a `.md` file for live markdown; a `.zig` file for tree-sitter
highlighting over the monospace grid.

## Headless testing

The render path is verified without a display server. The production Skia
renderer targets an ordinary offscreen Vulkan `VkImage`; the harness injects
platform-neutral key specifications through normal dispatch and reads the
completed image back through Vulkan. Captures are full editor frames, not a
test-side reconstruction. Two collaborating editors are submitted together
and read together so their side-by-side captures describe the same test step.

### Recording a demo video

The existing whole-app spine test can optionally stream its live, synchronized
two-screen capture into an H.264 MP4. This is opt-in, so ordinary test runs
remain unchanged:

```sh
WEFT_E2E_VIDEO=/tmp/weft-spine.mp4 \
  zig build e2e-demo --summary all
```

The output is 30 fps by default, with the source and observer screens composed
side-by-side into each frame from one capture operation. The demo path types at
75 ms per character and lingers on milestone states for 1000 ms. Tune those
values without changing the scenario:

```sh
WEFT_E2E_VIDEO=/tmp/weft-spine.mp4 \
WEFT_E2E_VIDEO_FPS=30 WEFT_E2E_TYPING_MS=55 WEFT_E2E_LINGER_MS=1500 \
  zig build e2e-demo --summary all
```

Frames are streamed directly to `ffmpeg` through a bounded one-frame PPM
buffer; no raw frame sequence is retained. If `ffmpeg` is unavailable, the
test still runs with ordinary timing and reports that recording was disabled.
The focused `e2e-demo` step selects the existing spine test; it does not add a
separate demo scenario.

## Remote

Every weft is a peer; there is no separate agent binary. Host a document
from a headless machine with the same executable (the window/Vulkan half
is simply never initialized):

```sh
weft --headless --listen 7777 --token SECRET --access edit --lsp zls file.zig
```

Open it from anywhere — `file.zig` is a name hint; nothing is read
locally. Content, ops, and the host's LSP diagnostics arrive over the
encrypted wire; tree-sitter runs on your replica:

```sh
weft --connect host:7777 --token SECRET file.zig
```

Two editors can also pair directly (`--listen` in one, `--connect` in the
other); partitions heal as one frontier exchange.

Authentication and authorization are separate. The token proves you *may
connect* (it derives the link encryption); the access grade proves what
you *may do*. A host grants an endpoint `view` (read-only — the peer
receives every edit but its own ops are never admitted, enforced at the
wire), `edit`, or `own` (edit plus reserved administrative authority). The
default is `view`, so write access is only ever handed out by an explicit
`--access edit`. Reaching *out* to an ssh file is the opposite direction:
there you are the principal with full authority, and remoteness is just
where the bytes and toolchain live. Protocol spec: `doc/wire.md`.

## Not yet

Coding-agent support (ACP) is designed and in progress — as plugins, not
core: an agent is a peer, a conversation is a foldable model buffer, and
agents are declared as config data (`weft.agent`), so weft makes no
assumptions about how the adapters are launched. Design and build plan in
`doc/agents.md`.

Markdown tables and images need 2D block layout (column measuring, image
decode) beyond the per-byte inline model.

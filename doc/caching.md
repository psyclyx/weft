# Caching

Weft keeps derived data between frames where computing it again costs
more than looking it up. One rule holds for every such cache:
**a cache cannot grow without bound.** Memory a cache holds is
budgeted, and a cache that is full makes room instead of growing.

## `core.cache.Bounded`

`src/core/cache.zig` is the one cache container. It knows nothing
about what it holds. Its owner supplies four functions: hash, compare,
cost (the bytes an entry holds) and release.

- **Budget.** `Limits.bytes` caps the entries' total cost and
  `Limits.entries` caps their count. The least recently used entry
  goes first to make room.
- **Refusal.** An entry that costs more than the whole budget is
  released, not cached (`Stats.refused`).
- **Ownership.** `put` owns its key and value from the call on. Each
  is released exactly once, including when the put fails or refuses
  them.
- **Borrowing.** A pointer from `get` is valid until the cache next
  changes. A caller that keeps a value across a change copies it out.
  The shaping cache below copies glyphs into the frame's own scratch,
  so no eviction can pull a run out from under a frame.
- **Storage.** The container's own storage is bounded too: slots are
  reused, so the index never outgrows `Limits.entries`.

A cache's key must hold everything the value was derived from. When
an input cannot be put in the key cheaply, the owner clears the cache
whenever that input changes, at the one place it changes.

## Caches

| Cache | Owner | Key → value | Budget |
| --- | --- | --- | --- |
| Shaped text (`gfx/view/shapes.zig`) | View | (face set, style, text) → glyphs, in units of em | 4 MiB, 16k entries |

Shaped glyphs are em-relative, so one entry serves every size. Only
the View's own two face sets are cached. Those sets live exactly as
long as the View, so a face's identity in a key can never come to
mean another face. Text in any other set is shaped uncached. Measuring
a chrome label (`View.uiWidth`) reads the same entry that drawing it
(`View.uiRun`) does.

Measured with `zig build bench-raster` (2026-10-15, interleaved A/B
against b48f9f0): `View.build` fell 20–25% in every case, from
1.25–1.45 ms to 1.00–1.13 ms. The framebuffer hash was identical in
all five cases.

## Candidates

From the 2026-10-15 survey, not yet cached:

- **Laid-out doc popups.** Each frame reflows, analyzes and lays out
  the same `Surface.info` 2–3 times. Its shaping is now cached; caching
  the layout too needs a key over every View input it reads (metrics,
  theme colours).
- **Off-screen goal-x shaping** in `gfx/layout.zig`. It has no View,
  so it does not reach the shaping cache.
- **Terminal grid shaping.** A (codepoint, face) → glyph id table
  would replace most of it.
- **Icons rendered by the Skia backend:** (icon, pixel size, colours)
  → a raster image or picture, once Skia's SVG module is built in.
  Its values are GPU-side handles, which `release` frees.
- **Catalog snapshots** (`core/catalog.zig`). These are keyed by head
  × entry slot. Slot reuse bounds them, except for heads that come and
  go: `forget` is not called at head teardown.

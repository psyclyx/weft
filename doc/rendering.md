# Rendering: decomplecting popups/UI from the platform + backend

Status: DESIGN (2026-08-21). Requested: "move more of the popup/rendering into
plugins, decomplected"; and "wayland/vulkan setup stays in core — later we'll add
X, terminal, browser, macOS", plus "we'll likely add webgpu". This doc fixes the
seam so those are additive, not rewrites. Builds on `extensibility-native-surface.md`,
the surface membrane already shipping, and the abstraction-audit's #1 item
(the render membrane is bypassed by the popup producers).

## The two things being separated

Today the completion popup, the hover box, and the picker dock are drawn by
**core** `src/gfx/view/popup.zig` reaching straight for glyph runs + rects against
the active backend. That fuses three concerns that should be three layers:

1. **What to show** — the UI logic: a completion list has rows, one selected, an
   aligned kind/detail column, a side doc box. This is POLICY and belongs to a
   plugin (the completion consumer), like which-key/dired/magit already are.
2. **How to lay it out** — cell/glyph metrics, wrapping, flip-to-fit-the-viewport.
   This is BACKEND-SPECIFIC (a terminal cell ≠ a webgpu pixel) and belongs to CORE.
3. **How to rasterize + present it** — turn laid-out primitives into pixels/cells
   on a surface, and run the window/input loop. This is PLATFORM + BACKEND and
   belongs to CORE (wayland+vulkan now; X, terminal, browser, macOS, webgpu later).

The seam is between (1) and (2): a plugin emits a **backend-agnostic scene** —
logical content + semantic roles + anchoring, no pixels, no fonts, no GPU. Core
lays it out (it alone knows the metrics) and rasterizes it (it alone knows the
backend). A new backend or platform is then a core-side implementation with
**zero plugin changes** — that is the whole point, and what makes webgpu / X /
terminal / browser / macOS additive.

## The scene vocabulary (generalize the surface membrane)

The surface membrane is 80% of this already (`src/core/surface.zig`, membrane
`wl_surface_begin/row/span/end`): a `Surface` is `rows[]`, each `Row` is
`spans[]`, each `Span` is `{ text, role }`, with a `Placement` and an optional
`selected` row. `Role` is SEMANTIC (normal/accent/group/leaf/effect/muted),
resolved to a color by `Theme.roleColor` — so colorschemes AND backends stay out
of the plugin. which-key, dired, and magit render entirely through this.

What popups need on top of the retained-overlay surface, and must be added to the
vocabulary (not to a bespoke drawer):

- **Anchoring beyond docks.** `Placement` is `bottom | corner | center` today.
  Add `caret{ offset }` — anchored at a document offset, with core doing the
  flip-above/clamp-into-body that `drawPickAtCaret`/`drawHoverAtCaret` hardcode
  now. Anchoring is a layout concern → the plugin names the offset, core places it.
- **Column alignment.** A completion row is `item` + a dimmed `note` (kind+detail)
  aligned to a common column across rows. Express as a row with typed cells /
  a column hint, so core aligns (it knows widths); the plugin just supplies the
  two span groups. (Today `popup.zig` computes `max_item` etc. inline.)
- **A linked side panel.** The selected row's documentation shows in an adjacent
  box (the docs popup just added). Model as a surface that references its parent
  + the selected row, so core positions it beside/below and the plugin need not
  know geometry.
- **Selected-row styling** already exists (`Surface.selected`); reuse it.

None of these are colors or coordinates — they're logical. Metrics + placement
stay core so terminal (cell grid) and webgpu (pixels) lay the SAME scene out
correctly.

## Layered API — reward the grain, fall back to text, escape to webgpu

The membrane must make **good UI easy** and **bespoke UI unattractive** — not by
prohibition, but by making the idiomatic path strictly the better deal. Three
tiers, one vocabulary:

- **Tier 1 — semantic scene (the default, and where the rewards live).** A plugin
  emits rows/spans/roles/anchoring and gets, for free: theming + colorscheme
  follow (roles, never colors), font + shaping + HiDPI, layout + flip/clamp +
  column alignment, **automatic text fallback** on limited backends (terminal),
  focus/keyboard/selection integration, and **composition** — its overlay stacks
  and coexists with which-key, hover, and other plugins' surfaces because they all
  speak the same scene. This is what ~all plugins should use.
- **Tier 2 — structured widgets (still Tier-1 underneath).** Common shapes —
  a caret popup, a list with a selected row + annotation column, a linked info
  panel, a docked panel, an inline decoration — offered as ergonomic builders over
  the same scene, so a plugin composes a rich UI without leaving the rewarded
  path. The bar to clear: Tier 2 should cover enough that escaping is rare.
- **Tier 3 — raw drawable / webgpu (custom pixels, still integrated).** For the
  genuinely-custom — a graph/plot, a shader viz, an interactive canvas — a plugin
  renders its own pixels into a drawable region core owns (a texture rect, webgpu
  when present). Crucially it **stays wired into the editor**: it can still declare
  selectable text regions and hit-boxes, take focus, receive routed key/pointer
  events, sit in the window/pane layout, compose with other surfaces, and opt into
  theme colors — the same integration hooks Tier 1/2 use. What it gives up is only
  the *convenience*: it hand-renders its content and, if it wants to work on a
  terminal, supplies its own text fallback (or declares graphics-only). Tier 3 is
  a first-class citizen, not a sandbox exile.

The incentive is by CARROT, not stick: Tier 1/2 are so easy and so integrated that
you reach for Tier 3 only when you truly need custom pixels — and even then you
stay part of the editor. A menu drawn in raw webgpu is more work for no gain, so
nobody does it; a live plot in webgpu is worth it, and it still gets selection,
focus, and layout. We reward idiomatic without making the exotic strictly worse —
the difference is convenience, not capability or citizenship.

Text fallback is a first-class requirement, not an afterthought: **every Tier-1/2
primitive has a defined text rendering** (a box → box-drawing chars, a role →
an SGR color or attribute, a caret popup → an inline/echo list), so a plugin
writes its UI ONCE and it degrades to good text on limited backends automatically.
Only Tier 3 must hand-author (or forgo) its fallback.

## The backend + platform seams (core-internal)

Two core-internal interfaces, so the additive platforms/backends slot in:

- **Platform** (window + input + present): `src/platform/wayland.zig` today. Owns
  surface creation, the event loop, key/pointer events, vsync/present. Future: X,
  terminal (tty + input), browser (canvas/DOM events), macOS (Cocoa). Platform
  setup stays in CORE — a plugin never touches it.
- **Rasterizer/Backend** (scene → output): `snail_vk` + `skia` today. Consumes a
  laid-out scene (boxes, text runs positioned in device space, rects, colors) and
  draws it. Future: **webgpu** (one more Rasterizer — nothing above it changes),
  terminal (a cell rasterizer: boxes → box-drawing chars, colors → SGR, glyphs →
  cells; lossy by nature, degrade gracefully), browser (webgpu/canvas), macOS
  (metal or webgpu).

The frame path becomes: consumers/plugins emit scenes → core **layout** resolves
metrics + anchoring + columns → core **rasterizer** draws → core **platform**
presents. webgpu enters at "rasterizer"; a terminal enters at "rasterizer +
platform"; neither touches the scene vocabulary or any plugin.

## Migration phases (each compiles + tests green)

- **P0 — groundwork (DONE).** Surface membrane + semantic roles + `decorate`
  inline layer already exist and carry which-key/dired/magit.
- **P1 — caret popups as scenes.** Add `Placement.caret` + column/info-panel to
  `surface.zig` and a GENERIC caret-surface renderer in `popup.zig` that does the
  flip/clamp/column-align once. Re-express the completion popup (+ docs box) and
  the hover box as surfaces built in core (still core-emitted) — deleting the
  bespoke `drawPickAtCaret`/`drawHoverAtCaret` layout. Behavior identical; the
  snapshot tests are the guard.
- **P2 — the consumer emits the scene (DONE).** `Role.annotation` landed
  (column≥1 dimming is now role-driven, not a column-number special case).
  `core.pick.Pick.buildSurface` — not the render layer — builds the picker's
  own scene, caret popup or window-bottom dock, from live `Pick` state;
  `frame_builder.zig` hands it through `hud.surfaces` the same door a
  plugin's retained surface uses (production `Hud.pick`/`Hud.hover` are now
  dead fields, kept only as a legacy/test-only fallback in `View.build` for
  callers that still build a `Hud` by hand). The hover HUD path was DORMANT
  in production (`frame_builder.zig` passed `.hover = null`; LSP hover
  routed to the echo line) — re-wired to a LIVE producer: the `lsp` guest
  plugin now emits its hover as a `.caret` surface through a new
  `wl_surface_caret` membrane call (echo remains the fallback only when
  there's no hover result to anchor). `popup.zig` shrank to three generic
  renderers — `drawSurfaces` (corner/center, and routing for a guest's
  `.caret`/`.bottom` surface), `drawCaretSurface`, `drawDockSurface` — plus
  their `layout*` introspection twins; it no longer names "completion" or
  "hover" anywhere. Guard: `src/e2e/popup_layout_test.zig`'s goldens
  (including two new dock scenarios). DISMISSAL: a guest has no
  `on_move`/`on_edit` export to close its own caret popup when the cursor
  wanders off — that's the P4-era generalization (guest-driven, once
  UI-as-plugin needs it for more than hover). Meanwhile `frame_builder.zig`
  enforces it as CORE POLICY: a retained guest `.caret` surface auto-CLOSES
  the frame the cursor leaves its anchor's line — unlike the echo line
  hover replaced, a caret popup paints over body text, so a stale one left
  open is a real regression, not just clutter.
- **P3 — formalize the backend + platform seams (DONE).** Extract the Rasterizer
  and Platform interfaces around `snail_vk`/`skia`/`wayland` (no behavior
  change), so webgpu / X / terminal / browser / macOS are drop-in later. Keep
  wayland+vulkan as the one live impl. FINDING recorded in `rasterizer.zig`'s
  module doc: today's RenderState conflates draw (scene→pixels) with surface
  ownership (present/swapchain) — the future `draw(scene)` /
  `presentFramebuffer(ctx)` split is what lets the harness's CPU raster become
  a literal named impl, and is where a terminal/webgpu backend enters.
- **P4 — UI-as-plugin.** The completion CONSUMER moves to a guest plugin emitting
  the caret-surface scene through the membrane (needs the caps-fire + live-narrow
  membrane from [[completion-ux-roadmap]]). The completion UI is a plugin, drawn
  through the same seam as which-key.
- **P5 — the editor view as a bundled scene client (core goes rendering-free).**
  Only after P1–P4 prove the ABI on the popups + a perf check: the main buffer
  view emits its viewport as a scene (in-process, native speed via the abi.zig
  transport), so core keeps platform + rasterizer + ABI and owns NO widgets. This
  is the "no rendering in core" endpoint; sequence it LAST because it's the hot
  path.

## Non-goals (not yet)

Actual webgpu / X / terminal / browser / macOS implementations. This doc only
fixes the SEAM so they are additive. Wayland+Vulkan stays the sole platform+backend.

## Decided splits (were open; resolved so this is build-ready)

- **Layout lives in core, always.** A plugin supplies logical content + roles +
  an anchor; core resolves widths, columns, wrapping, and flip/clamp because only
  the active backend knows cell/glyph metrics (a terminal cell ≠ a webgpu pixel).
  A plugin that tried to lay out would break the moment the backend changed. So
  the scene is metric-free.
- **Tier 3 hands back a texture/framebuffer rect, not a command buffer.** The
  plugin renders into an opaque drawable region core owns; core composites it into
  the frame. A raw command-buffer hand-off would weld plugins to one GPU API
  (vulkan today) and defeat the whole webgpu-is-additive goal. The texture rect is
  the backend-neutral escape hatch (backed by webgpu when present; a stub/hidden
  region on a terminal). The rect is INTEGRATED, not isolated: the plugin also
  declares selectable-text spans + hit-boxes over it, joins focus/input routing and
  the pane layout, and composes like any surface — so custom pixels still behave
  like part of the editor.

## Should the text UI itself be a plugin? (leaning yes)

The user's sharper framing: *no rendering in core at all — only the ABI that lets
the UI be a plugin.* Taken seriously, this is the cleanest version of everything
above. Core then owns exactly: the **platform** (window/input/present), the
**rasterizer** (scene → pixels/cells), the **document/edit model + dispatch**, and
the **scene + input ABI**. It owns NO widgets — not even the main editor view. The
text editor is the FIRST, bundled scene client: it emits the buffer viewport as a
scene (lines as rows, cursor/selection/gutter/decorations as spans + regions) the
same way which-key does, and everything else (completion, hover, dired, magit) is
just more clients.

Why this is attractive:
- **One rendering path, proven by its hardest client.** If the editor view itself
  goes through the scene ABI, the ABI is provably expressive and fast enough for
  everything — no "core UI" escape that plugins can't match. A 3rd-party plugin
  can do anything the editor does, including replace/augment the view.
- **Uniformity.** No special-case core rendering to keep in sync with the membrane;
  the abstraction-audit's "producers bypassing the render membrane" goes to zero by
  construction.

The one real risk is **per-frame cost** for the main view (scrolling a large doc).
Two things defuse it: the scene is bounded by the VIEWPORT, not the document (only
visible lines emit, so multi-gig is irrelevant — [[completion-ux-roadmap]]/stemma
already stream); and the bundled UI runs **in-process** (native), not over the wasm
boundary. weft already has this split — `abi.zig` (in-process) mirrors `weft.zig`
(wasm) one-for-one, SAME plugin logic, different transport — so the first-party
editor UI is an in-process scene client at native speed, while third-party UI
plugins use the identical ABI over wasm. The membrane is the contract; the
transport is an implementation detail per client.

Provisional decision: **yes** — treat the editor view as a bundled, in-process
scene client and keep core rendering-free (platform + rasterizer + ABI). But prove
it INCREMENTALLY: P1–P2 move the popups first (bounded, low-risk), P3 formalizes the
seam, and only then (a later phase, P5) move the main editor view onto the scene ABI
once it's proven on the popups + a perf check. Don't rewrite the hot view first.

## The UI as a mesh of narrow capabilities (not one "UI plugin")

Weft's strongest parts defer the concrete behind a NAMED INTERFACE: the caps
registry races `edit/completion` / `edit/hover` providers by name, so any one is
swappable and core names no implementation. A monolithic "UI plugin" throws that
away — you'd swap all or nothing. So the UI decomposes the SAME way: not one
plugin, but a set of narrow **UI capabilities**, each a small interface + a
composition rule + a default (swappable) provider. Core wires names; it owns no
widget. This is the answer to "swap at a reasonable granularity": the granularity
is one capability.

The decomposition — each a capability whose provider emits scene primitives:

| Capability          | Composition   | Interface (in → out)                                        |
|---------------------|---------------|-------------------------------------------------------------|
| `ui/viewport`       | first-wins    | (buffer, visible range, geometry) → text rows scene         |
| `ui/gutter-segment` | ordered-union | (line, facts) → gutter cells (line-nums, diag, git, breakpts)|
| `ui/statusline-seg` | ordered-union | (editor state) → a span group (mode, path, position, lsp)   |
| `ui/caret`          | first-wins    | (offset, mode) → caret shape/blink primitive                |
| `ui/popup`          | union         | — a caret/docked scene (completion, hover, which-key, sig)   |
| `ui/overlay`        | union         | (viewport) → decoration spans (search hits, selection, inlay)|
| `ui/rail`           | first-wins    | (buffer, geometry) → scrollbar/minimap scene                |
| `ui/layout`         | first-wins    | (panes, popups, docks) → placement rects                    |
| `theme`             | first-wins    | role → color                                                |

**Composition mode IS the granularity knob**, and it reuses the caps machinery
(first-wins / union / ranked): a gutter is an ORDERED UNION of segment providers
(line-numbers + diagnostics + git stack left-to-right); a statusline likewise;
popups/overlays are a UNION (many coexist); viewport/caret/rail/layout/theme are
FIRST-WINS (one default, individually overridable). Nobody registers "the UI" —
they register a segment, a popup, an overlay.

**Granularity rule:** carve a slot iff someone might reasonably swap JUST it —
independent variation, independent authorship. Line-number style, diagnostic
gutter marks, a statusline segment, the completion popup, a minimap: each is a
thing a user or 3rd-party plugin swaps alone. Don't split below where pieces always
change together (a caret's shape and blink are one slot, not two) — that's how you
avoid trading a monolith for a thousand-cut mesh.

**The scene is the narrow waist that lets fine pieces compose.** Every UI
capability emits the SAME scene primitives (rows/spans/roles/regions/anchors), so a
swapped provider still themes, lays out, falls back to text, and composes with its
neighbors for free — no N×N mesh of bespoke interfaces, because they all speak
scene. This is why the seam (above) and the granularity (here) are one design: the
shared scene type is what makes many small interfaces cheap.

**Wiring + defaults.** Core ships a default in-process provider per slot (native
speed via the abi.zig transport); config binds a different provider to any one slot
(`weft.provide("ui/gutter-segment", …)`), overriding just that piece. The frame
composes by firing each UI capability and assembling the returned scenes through
`ui/layout` — the same race-and-merge the completion UI already does, one level up.
So swapping is literal and local: replace your git-sign gutter segment without
forking the view; ship a minimap as a pure add; retheme by role; and at the limit
(P5) even `ui/viewport` is just another first-wins slot.

## Primitive sketch (what P1 adds to `core.surface`)

The retained `Surface` already has `rows[]`, `selected`, `Placement`. P1 adds:

    Placement = enum { bottom, corner, center, caret }   // + caret
    Surface {
        …existing…
        anchor: ?usize = null,        // doc offset when placement == .caret
        info: []u8 = &.{},            // linked side panel (selected row's docs)
        // a Row's spans may carry a column tag so core aligns them:
    }
    Span { text, role, column: u8 = 0 }   // 0 = main, 1 = annotation, …

Membrane (extends the existing `wl_surface_*`): `wl_surface_begin` gains a caret
variant, `wl_surface_caret(offset)` — SHIPPED in P2, the one new membrane call the
`lsp` plugin's hover needed. The column tag and linked info panel (`column` on
`Span`, `Surface.info`) stay CORE-SIDE only for now — `wl_surface_span` is still
3 params and there is no `wl_surface_info` import; no guest has needed an
aligned/annotated caret list or a side panel yet (`Pick.buildSurface`, a core
consumer, builds those directly against `core.surface.Surface`). Add
`wl_surface_span_col`/`wl_surface_info` the same way, when a guest actually
needs them — the pattern (contract_data.zig entry + contract.zig handler +
weft.zig extern+wrapper, verified by both comptime tripwires) is established.
The generic renderer `drawCaretSurface` in `popup.zig` does the
flip/clamp/column-align/info-box that `drawPickAtCaret`+`drawHoverAtCaret`
hardcoded before P1 — one place, every caret popup.

## Why this ordering

The completion popup's concrete needs (rows, selected, aligned note column, side
doc panel) are the exact forcing function for the caret-surface primitive — so we
design the vocabulary against a real client, not in the abstract. Once popups are
scenes (P1–P2), the backend seam (P3) is a mechanical extraction, and UI-as-plugin
(P4) and webgpu both become "just another consumer / just another rasterizer".

See [[abstraction-audit]] (render membrane = #1), [[completion-ux-roadmap]],
`extensibility-native-surface.md`.

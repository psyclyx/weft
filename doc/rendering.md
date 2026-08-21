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
- **Tier 3 — raw surface / webgpu (the escape hatch, deliberately costlier).** For
  the genuinely-custom — a graph/plot, a shader viz, a game — a plugin can request
  a raw drawable region (a texture/framebuffer rect it renders into, webgpu when
  present). But it **opts OUT of everything Tier 1 gave**: no theming, no text
  fallback (it must supply its own degraded rendering, or declare "graphics-only"
  and be hidden on a terminal), no automatic composition, no free layout. The
  escape exists for real needs and is honest about its costs.

The incentive is structural: because Tier 1/2 hand you theming, fonts, fallback,
layout, and composition, and Tier 3 makes you rebuild all of it, the grain is to
work WITH the scene. A third-party plugin that uses the semantic API looks native,
recolors with the user's theme, and works in a terminal — for free; one that
reaches for raw webgpu to draw a menu is doing strictly more work for a worse
result. We reward idiomatic; we don't forbid exotic.

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
- **P2 — the consumer emits the scene.** `complete_ui`/hover build a surface
  instead of driving pick+bespoke draw; the picker dock too. `popup.zig` shrinks
  to one generic surface renderer. Core no longer knows "completion popup", only
  "a caret surface".
- **P3 — formalize the backend + platform seams.** Extract the Rasterizer and
  Platform interfaces around `snail_vk`/`skia`/`wayland` (no behavior change), so
  webgpu / X / terminal / browser / macOS are drop-in later. Keep wayland+vulkan
  as the one live impl.
- **P4 — UI-as-plugin.** The completion CONSUMER moves to a guest plugin emitting
  the caret-surface scene through the membrane (needs the caps-fire + live-narrow
  membrane from [[completion-ux-roadmap]]). This is the payoff: the completion UI
  is a plugin, drawn through the same seam as which-key.

## Non-goals (not yet)

Actual webgpu / X / terminal / browser / macOS implementations. This doc only
fixes the SEAM so they are additive. Wayland+Vulkan stays the sole platform+backend.

## Why this ordering

The completion popup's concrete needs (rows, selected, aligned note column, side
doc panel) are the exact forcing function for the caret-surface primitive — so we
design the vocabulary against a real client, not in the abstract. Once popups are
scenes (P1–P2), the backend seam (P3) is a mechanical extraction, and UI-as-plugin
(P4) and webgpu both become "just another consumer / just another rasterizer".

See [[abstraction-audit]] (render membrane = #1), [[completion-ux-roadmap]],
`extensibility-native-surface.md`.

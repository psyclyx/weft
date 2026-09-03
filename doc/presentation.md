# Presentation: the path to "the same plugins, everywhere"

Status: DESIGN (2026-09-03). Supersedes the P4/P5 half of `rendering.md`.
Written after an adversarial review that refuted most of its own first draft.

Forcing statement (user, 2026-09-03): *"we want to be using skia+webgpu. the
editor experience as a plugin means the presentation is a plugin means we need
platform-independent ways to draw things. we should put the work in to do it
right, such that when we eventually add other platforms (browser, x11, macos),
we can just use the same plugins and get the same graphical experience."*

## 0. The verdict, in one line

**WebGPU is the plugin-facing DRAWING API, not core's device layer.** Those are
two independent decisions and the first draft of this doc conflated them:

- **As a device layer** (replacing Ganesh/Vulkan under Skia): not justified.
  Worth ~1 ms, costs a from-source Skia and an unpackaged Dawn. **Cut.**
- **As the API a plugin speaks to draw custom pixels on any platform**: this is
  the point, it is what makes plugin graphics portable to x11/macOS/browser
  without the plugin changing, and it is reachable *today* via `wgpu-native`
  (27.0.4.0, already in the pinned nixpkgs). **Build it.**

Separately, the raster path was 5× slower than it needed to be for ~50 lines'
worth of reason. That was worth taking because it was free, not because it was
ever the goal.

## 0.5 The acceptance criterion

User, 2026-09-03: *"when we're done, the editor shouldn't look different, core
should just be smaller."*

Both halves are mechanically checkable, so this is the gate, not a sentiment:

- **The editor does not look different** — `bench-raster` hashes the whole
  framebuffer, and `popup_layout_test.zig` asserts geometry. A step that changes
  what the user sees has to justify it explicitly, not discover it later.
- **Core gets smaller** — measure `src/core` + `src/gfx` LOC before and after
  each step. A step that moves policy into a plugin and leaves core the same
  size did not move policy; it added an indirection.

Baseline at 2026-09-03: `src/core` 76,036 lines (≈13k of it tests),
`src/gfx` 6,849. Every step below states which number it is supposed to move.
The batching commit is the degenerate case — pixels identical, LOC flat, because
it was a speed fix and claimed nothing about structure.

Three findings drive everything below, all measured or symbol-checked, not
argued:

1. **Glyph-run batching plus a colour memo made the raster path 5× faster**
   (1.999 ms → 0.388 ms at 1600×1000 over a real source file), byte-identical
   output, ~50 lines. **LANDED** on `perf/raster-batching`. It required no
   Graphite, no Dawn, no device layer, no scene change.
2. **Deleting the readback — the entire payoff of a device migration — is worth
   ~1.03 ms**, and that is a ceiling. Batching is **8.8× the win**.
3. **`pkgs.dawn` is not Google Dawn.** It is a Geant4 3D PostScript processor
   (v3.91a, `geant4.kek.jp`, unfree). Google's Dawn is not in nixpkgs at all,
   and the shipped `libskia.so` has **zero** Graphite and zero Dawn symbols —
   headers ship because the derivation's `installPhase` runs a blind `find`.

## 1. What was measured

Ryzen 9 5950X, discrete AMD GPU, `ReleaseFast`, medians over 25–40 interleaved
A/B samples, correctness oracle = FNV-1a hash of the full framebuffer (identical
across every run). 1920×1080, 56 rows, 10,837 draw items from the real
`View.build`.

| phase | today | with glyph-run batching |
|---|---|---|
| `Skia.drawItems` | **7.23 ms** | **0.73 ms** |
| `end()` (`flushAndSubmit(kYes)` + `readPixels`) | **3.85 ms** | 1.30–1.58 ms |
| **total raster + readback** | **11.1 ms** | **2.0–2.3 ms** |

**Those numbers are real `ReleaseFast` numbers — the build mode was not the
problem. The WORKLOAD was.** 10,837 glyphs is a *completely full* 1080p screen
of solid text; real code is short lines and whitespace. Re-measured by
`bench-raster` against an actual 863-line source file — 2,156 glyphs at
1600×1000, 2,437 at 1080p:

| phase | before | after (landed) |
|---|---|---|
| `View.build` | 0.211 ms | 0.212 ms |
| `Skia.drawItems` | 1.999 ms | **0.013 ms** |
| `end()` (CPU raster path) | 0.000 ms | 0.375 ms |
| **raster total** | **1.999 ms** | **0.388 ms** |

Framebuffer hash `0xb75df71b7a8a7a5b` on both sides. The real saving is
~1.6 ms/rebuilt frame, not 9 — a **5× on the raster path**, from a synthetic
worst case that overstated the glyph count by roughly 5×. The lesson worth
keeping: a benchmark's workload is part of its claim, and stating the build
mode is not enough to make a number honest.

Caveat on the instrument: it runs Skia's CPU path, so `end` there is deferred
draw work, not the GPU readback. Timing the readback needs a Vulkan device.

Isolations: GPU readback floor (clear only, no glyphs) **0.89 ms**; staging
memcpy (8.3 MB) **0.14 ms**; `View.build` for a 50×100 viewport **401 µs**;
scene-codec round-trip for an 897-node scene **390 µs native** (encode 182 +
decode 137 + validate 71).

Three corrections this forced on the first draft:

- **The 3.85 ms in `end()` is misattributed.** Only 0.89 ms is readback; the
  other 2.96 ms is Ganesh executing the 10,835 deferred ops the *unbatched* draw
  enqueued. A naive profile reads "4 ms in the readback" and funds a device
  migration to fix a 1 ms problem. This misattribution was the whole argument
  for D3.
- **"Round-trips every frame" was wrong.** The loop is event-driven
  (`main.zig:791`, `render_skia.zig:137`): raster runs only on rebuild.
- **The repo has never measured rasterization or present.** `latency_test.zig`
  measures dispatch only and says so in its own header;
  `popup_layout_test.zig` asserts geometry and explicitly rejects pixels as
  brittle. So the first draft's "guarded by goldens and the latency gate" was
  false as a perf guard — a rasterizer swap could make frames 3× slower with
  both green. **Every perf claim in the first draft, in both directions, was
  unsupported until this review.**

## 2. The guarantee, stated honestly

The first draft promised the same *graphical experience* — pixel identity —
everywhere. That is false, and Dawn would not have fixed it:

- `shim.cpp` uses `SkFontMgr_empty`. Skia does **no** system font access and
  **no** fallback; faces arrive only via `weft_skia_register_font` from
  `font_provider`, which `build.zig:452` resolves to `fontconfig.zig` on Linux
  and `unavailable.zig` — nine lines returning `null` — everywhere else. Off
  Linux, anything beyond the pinned mono face renders different glyphs or none.
- Color management is off by construction: `kBGRA_8888` with a null colorspace
  copied into a `..._SRGB` swapchain. Rendering *directly* into that target
  without the copy would double-encode — a visible washout, and a real
  regression risk in any swap.
- Skia publishes no Ganesh↔Graphite parity list. WebGPU standardizes the API,
  not the pixels: fill rules, MSAA sample positions and line rasterization
  differ across Vulkan/Metal/D3D12, and the WebGPU CTS tolerates that by design.

**The defensible guarantee is: the same scene, the same layout, the same roles.**
Layers 1–4 already deliver it — `gfx/view/linelayout.zig` derives everything
from HarfBuzz metrics with zero backend types reaching `gfx/view/`. Pixel
identity is explicitly disclaimed.

## 3. What actually blocks the goal

None of these are rasterizer problems. This is the real work.

- **Surface-handle shape.** `gfx/context.zig:22` `SurfaceSource{display, surface}`
  goes straight to `vkCreateWaylandSurfaceKHR`. X11 needs a different *shape*,
  not different types. Documented open at `platform/root.zig:52`.
- **Key identity.** `KeyEvent.keysym` is literally an xkb keysym
  (`platform/root.zig:89`). Neither macOS nor a browser maps to it cleanly.
- **Fonts.** `font_provider` is Linux-only by construction. This is the single
  largest threat to cross-platform visual consistency and nothing in the first
  draft addressed it.
- **Input does not exist as a routable thing.** The platform contract has
  exactly one event type, `KeyEvent`. Pointer is *polled state*
  (`mouse_x/mouse_y/mouse_down`); only button 0 is ever read (`dispatch.zig:91`),
  so there is no right-click and no context menu; a click sets focus and stops
  (`:98`) — there is no click→action path at all. Popups, docks and the
  statusline are **unclickable**. Zero of the 253 doors deliver an input event.
- **IME/compose: absent.** Text arrives solely via `xkb_state_key_get_utf8` into
  an 8-byte `KeyEvent.utf8`. CJK input is structurally impossible, and browser
  and macOS are IME-first platforms.
- **Accessibility: zero lines in 152k.** The design already exists and this doc
  should not reinvent it — `contextual-workspace-architecture.md:821` §11.5
  specifies the portable field set (identity, role, name, description, value,
  state, focus order, relationships, *"the same action reference used by pointer
  and keyboard activation"*).
- **The browser leg is blocked by non-graphics facts.** The plugin host is
  wasmtime (`build.zig:1471`, 111 references); LSP/agents need fork/exec; there
  is TCP+TLS, `std.Thread` in 18 files, and fontconfig. wasm-in-wasm is
  demonstrated but Pulley-interpreted (~10×) plus non-signal traps (~2×), and
  the graphics half needs Emscripten+Asyncify. Official CanvasKit is
  WebGL2/Ganesh, not WebGPU/Graphite.

## 4. Decisions

### D1 — Merge `surface` into `projection`. Nothing else.

The first draft proposed unifying three planes. That was wrong twice:

- The "semantic scene" is **39 doors of which 4 are presentation**
  (`_view_publish/_replace/_close/_focus`). The other 35 are an *authority*
  plane — targets, fs capabilities, fields, actions, relations, transfers,
  interactions. "Retire two door groups" would have deleted the clipboard.
- `Placement` is **not orthogonal to content**. Choosing `buffer` decides
  whether content is bytes in a rope, which decides whether search, yank, folds,
  undo and collab CRDT ops apply. Most `(Content, Placement)` cells are
  meaningless; today three types make them unwriteable, a union would make them
  writeable no-ops — the exact bug class [[structural-impossibility]] forbids.

What survives is real and cheap. `surface.zig` is the weak plane: flat rows, a
*closed* 7-value `Role` enum disjoint from the *other* closed 7-value
`StyleClass`, positional `selected`, no keys, no tree. Projection's open dotted
roles + `theme/<leaf>` resolution strictly dominate it. **19 call sites, 3 files
(`which_key`, `lsp`, `git/transient`), 6 doors retired.** Fix
`wasm_host/surface.zig:15` while there — `wl_surface_begin(3)` silently yields
`.bottom` instead of `.caret`.

Note for whoever does it: `editable` stays `?Edit`, a **span**. As a flag it
reopens a fixed bug where a keystroke at row start renames a file to text nobody
typed (`projection.zig:118`).

### D2 — Grow `DrawItem` for core's own chrome. No plugin door.

`rect|glyph` → `+ path, clip, transform, image, rrect`. This is what makes a
scrollbar, a minimap and rounded/shadowed chrome possible — all **core
widgets**, needing no plugin-facing primitive.

`Content.figure` is **cut**. It has zero in-tree clients, and it is a plugin-ABI
break in the *other* thing called scene (the versioned `scene_codec` wire
format), forcing exhaustive-switch edits in ~12 files. It also has no penalty
relative to the idiomatic path, so it is a peer default rather than a fallback —
forty plugins that each look slightly different is precisely what the guarantee
exists to prevent. And it costs accessibility and text-extraction, on which the
whole e2e discipline rests. Per `plugin-api.md`'s own rule, ship the door when a
*second* real consumer exists.

**Keep the escape hatch, and spell it WebGPU (D3b).** The first draft dropped it
on a misread: `rendering.md:188` banned *command buffers*, and a texture rect was
its fix. Four of six real cases need actual pixels (PDF at native resolution,
video, shader viz, embedded webview), including *image previews*, which the first
draft listed as a motivation for the thing that cannot serve it.

The original objection to a command-buffer handoff was that it *"would weld
plugins to one GPU API (vulkan today) and defeat the whole webgpu-is-additive
goal."* WebGPU dissolves that objection by construction: it **is** the
portability layer. A plugin that draws through WebGPU is not welded to anything —
its WGSL runs on Vulkan today, on Metal via a macOS port, and on the browser's
own WebGPU, unchanged. That is precisely the "same plugins, same graphics, any
platform" property the forcing statement asks for, and no other spelling of the
hatch has it.

**Perf caveat, and it is the top risk:** arbitrary interleaved paint/clip/
transform state breaks the glyph-run coalescing that §1 measures at −9.1 ms.
Widen the vocabulary *after* batching lands, and re-measure.

### D3a — Core's device layer: cut Dawn, defer Graphite.

Graphite's native-Vulkan entry point takes the **identical
`skgpu::VulkanBackendContext` `shim.cpp:84` already fills** for Ganesh:

    // gpu/graphite/vk/VulkanGraphiteContext.h
    namespace ContextFactory {
    SK_API std::unique_ptr<Context> MakeVulkan(const VulkanBackendContext&, const ContextOptions&);
    }

So *if* Graphite is ever wanted, it is a factory swap, one `imageUsage` flag at
`gfx/context.zig:296`, `SkSurfaces::WrapBackendTexture`, and
`skia_enable_graphite=true` on a from-source Skia — **no Dawn, no gclient2nix,
no wgpu, no device rewrite**. Skia's maintainers state native Vulkan is the
production-maintained Graphite backend (it is what Android ships); native Metal
is "for testing purposes."

But it buys ~1 ms, and it costs a from-source Skia derivation weft would own and
maintain against an API with no published stability policy. **Not justified by
perf. Revisit only if macOS needs it** — and even there, MoltenVK over the
existing Ganesh/Vulkan path should be priced first.

### D3b — The plugin drawing API: WebGPU, via `wgpu-native`.

This is the decision the forcing statement is actually about, and it is
independent of D3a. Core keeps Skia/Ganesh/Vulkan; a plugin that needs custom
pixels speaks **WebGPU**, and the same plugin then draws identically on every
platform weft is ported to.

Two facts make it tractable now:

- **`wgpu-native` 27.0.4.0 is in the pinned nixpkgs** ("Native WebGPU
  implementation based on wgpu-core"). Unlike Dawn — which is *not* packaged and
  would need an ANGLE-shaped gclient2nix derivation with ~65 pinned sources —
  this is an ordinary dependency.
- **Skia can import the result.** `GrBackendTextures::MakeVk`
  (`gpu/ganesh/vk/GrVkBackendSurface.h`) → `SkImages::BorrowTextureFrom`
  (`gpu/ganesh/SkImageGanesh.h`) wraps an externally-created Vulkan texture as an
  `SkImage`, which composites through D2's new `image` item like any other scene
  element.

The shape: a plugin declares a node whose content is a **drawable region**; core
allocates the texture and hands back a WebGPU surface; the plugin renders into it
with WGSL; core imports and composites it. The region stays a first-class citizen
of the frame — it declares hit rects, joins focus and input routing, sits in the
pane layout, and per `contextual-workspace-architecture.md:843` exposes a bounded
semantic/accessibility window, which is what keeps D2's a11y objection answered
for custom pixels.

**Open design questions, each needing a spike, not a guess:**

1. **Device sharing.** Ideal is wgpu-native adopting weft's existing `VkDevice`
   (no cross-device copy). If its C API does not permit that, the fallback is a
   separate device plus `VK_KHR_external_memory_fd` sharing. Unverified; this is
   the first thing to establish.
2. **ABI surface.** A wasm guest cannot link wgpu-native, so WebGPU must cross
   the membrane. The full API is ~100 entry points; a usable subset — create
   texture / buffer / pipeline-from-WGSL, write buffer, submit render pass — is
   perhaps 20–30 doors. That would be the largest new door group weft has added,
   against 253 existing. It is at least a *standard, specified* surface rather
   than an invented one, which is worth something.
3. **Sandboxing.** A wasm plugin driving a GPU is a real attack surface. WGSL is
   validated and WebGPU is designed for hostile content, which is exactly why it
   is the right choice here — but the grant model (`capability.zig`) needs a
   `gpu` capability and a resource budget.

**Tiering is what keeps this honest.** Tier 1/2 (scene, rows, spans, roles,
paths) remains the default and gets theming, text, hit-testing, accessibility and
composition for free. Tier 3 (WebGPU) is for genuinely custom pixels — a plot, a
shader visualization, a video, a native-resolution image. The carrot argument
from `rendering.md:91` survives intact, because Tier 3 now costs real work
(writing WGSL) to reach: nobody draws a statusline this way. That is the
distinction the first draft got wrong when it proposed `Content.figure`, a door
with all the rewards and none of the cost.

Add `assertRasterizer` and `assertDevice` mirroring `assertPlatform`
(`platform/root.zig:134`), each with a compile-only skeleton like
`HeadlessPlatformSkeleton` (`:178`). Cheap, real, and independent of everything
above.

**Do not clone the darwin gate for wasm32.** `darwin_architecture_gate.zig` is
39 lines importing 13 *already-portable* modules — no `gfx`, no `platform`, no
`skia`, no `wasm_host`. A wasm32 clone would go green on day one and prove
nothing about layers 5–7, the only ones at risk.

### D5 — Cut `abi.zig`.

The first draft called it "the largest hidden cost in the plan" and then
scheduled it sixth. Both were wrong, because it conflates two different goals:

- *"the editor view is a slot"* needs only `container.ProviderRef.ui_provider` —
  a fn-pointer that **exists today** and is already how all eight default
  statusline/gutter providers bind. Zero `abi.zig`.
- *"the editor view is a plugin over the same contract as a wasm guest"* needs
  231-vs-5 door parity — and `InProcClient`'s own doc argues it *should not*
  mirror the wasm shape, since it holds real Zig pointers and needs no handle
  table.

Nothing in the forcing statement requires the in-process transport to look like
the wasm one. Cut it; let a measurement decide if it ever comes back.

### D6 — One theme table, palette included.

Merge `gfx/view/Theme.zig`'s 20 colors into the `theme/<leaf>` slot family. Kill
the `StyleClass`→color switch at `Theme.zig:125` and the startup-only comptime
field walk at `main.zig:486`. ~400 LOC, and the cheapest structural win in the
document: it proves the theme-as-slot motion end to end and is a prerequisite
for "the same plugin looks right under a different palette."

### D7 — Input before the mesh.

`ui/popup`, `ui/rail` and `ui/overlay` are **pointer surfaces**. Completing the
mesh without input ships, identically on three platforms, popups you can look at
and cannot click. Input routing is a prerequisite, not a follow-on.

The compliant shape already exists and does **not** violate the footgun rule:
the plugin bulk-publishes retained hit rects (`gfx/view/semantic.zig:41` `Hit`)
and the *host* searches them. That is bulk publication, not a per-candidate
callback. Note D2's `path`/`clip`/`transform` makes host-side hit-testing
strictly harder — hit rects must stay first-class data.

Fold `contextual-workspace-architecture.md` §11.5's accessibility field set into
the node **at the same time**. Its key clause — *"the same action reference used
by pointer and keyboard activation"* — means a11y activation and the missing
click→action path are **one fix**. Roughly a week now against months later.

### D8 — Per-slot detail

`ui/gutter-segment` fires per (visible row × provider). Giving it a schema so a
guest can bind, as the first draft demanded, converts a fn-pointer call into a
schema encode + wasm crossing **per row, per provider, per frame** — ~10.8k
crossings/s at 60 rows × 3 providers × 60 Hz, against a 61.6 µs insert median.
Measure before mandating. The `[65]` surface array (`frame_builder.zig:426`) is
a 40-line fix, not a workstream.

## 5. Sequencing, ordered by measured value

**0. Glyph-run batching. LANDED** (`perf/raster-batching`): 5× on the raster path, byte-identical, ~50 lines in
`shim.cpp`, guarded by a framebuffer-hash oracle. Independent of everything.
Also: `skia/root.zig:72` calls `scene.linearToSrgbColor` — three `std.math.pow`
per item, ~32.5k per frame — for about 20 distinct colors; the batched 0.73 ms
floor is spent entirely before Skia rasterizes anything. Cache it. *(The `pow`
attribution is inferred from an off-canvas A/B, not profiled — verify.)*

**1. A raster/present timing gate.** The repo has none, so no rasterizer change
can be judged honestly and no regression can be caught. Prerequisite for
everything in §4 that touches the frame.

**2. Theme (D6).** ~400 LOC, cheapest structural win, proves theme-as-slot.

**3. `surface` → `projection` (D1).** 6 doors, 19 call sites, 3 files. Fix the
caret bug.

**4. Input + hit-test + click→action + a11y field set (D7).** The largest real
item, and the one that unblocks the mesh.

**5. `DrawItem` widening (D2), core chrome only.** After batching, re-measured.

**6. `ui/viewport` spike.** ~150 lines: declare the slot, wrap today's
`View.build` as a `.core`-tier `ui_provider`, route `frame_builder.zig:347`
through `Container.resolveOne`, bind a trivial second provider and swap at
runtime. No new ABI. This decides whether the viewport's real signature fits a
slot at all — knowable now, and the thing that would make the endpoint
impossible.

**7. The rest of the mesh**, sized by what 6 and D8's measurement say.

**WebGPU track (D3b), parallel and independent of everything above:**

- **W0 — interop spike.** Can `wgpu-native` adopt weft's existing `VkDevice`? If
  not, does `VK_KHR_external_memory_fd` sharing work? Render one triangle into a
  wgpu texture, import it via `GrBackendTextures::MakeVk`, composite it. This is
  the whole feasibility question and it is a day's work. **Do it before
  designing the ABI.**
- **W1 — the drawable-region node.** Core allocates, plugin draws, core
  composites. In-process first, so the ABI question is deferred.
- **W2 — the membrane doors.** The 20–30 door subset, plus the `gpu` capability
  and its budget.
- **W3 — a real Tier-3 client.** A plot or an image viewer at native resolution,
  which is also the second consumer that justifies the door existing.

**Platform track, also parallel:** surface-handle shape, portable key identity,
`font_provider` beyond Linux. This is the actual path to x11/macOS, and none of
it is a rasterizer problem. W0–W3 is what makes plugin *graphics* survive that
port unchanged.

**Cut:** Dawn; Graphite (deferred, ~1 ms); `abi.zig`; `Content.figure` as a
*default* drawing door (superseded by D3b's tiering); unifying the semantic
authority plane; the wasm32 compile gate; browser as a target of *this* document.

## 6. Sizing

Calibrated against this repo's real velocity, not calendar time: the
`arc/plugin-api` campaign was 50 commits / 12.4k insertions over 3 days;
`phase3` was 142 commits / 35k lines in 2.

| item | blast radius | scale |
|---|---|---|
| 0 — batching + color cache | ~60 lines, 2 files | hours |
| 1 — raster timing gate | ~200 lines, greenfield | hours |
| 2 — theme | ~400 lines, 4 files | ~1 day |
| 3 — surface→projection | 19 call sites, 3 plugins, 6 doors | ~1 day |
| 4 — input + a11y | ~6k lines; first host→guest event door | **one campaign** |
| 5 — DrawItem widening | ~1.5k lines, 11 files | ~2 days |
| 6 — viewport spike | ~150 lines | hours |
| 7 — mesh | ~5k lines, 7 new slots | **one campaign** |
| W0 — wgpu/Skia interop spike | ~200 lines, throwaway | hours–1 day |
| W1 — drawable region, in-process | ~600 lines | ~1 day |
| W2 — WebGPU membrane doors | 20–30 doors + `gpu` capability | **one campaign** |
| W3 — first Tier-3 client | ~500 lines, one plugin | ~1 day |
| platform track | ~2k lines + font work | **one campaign** |

Items 0–3 and 6 together are smaller than a single day of this project's
observed output, and they include the entire measured perf win.

## 7. Open question for the user

`rendering.md:214` claims *"a 3rd-party plugin can do anything the editor does."*
Measurement says that is false: `View.build` for a 50×100 viewport is 401 µs,
while one publish of a deliberately-coarse 897-node scene costs 390 µs *native*
before in-wasm encode, the membrane copy, and a wholesale deep-copy replace. The
semantic scene also cannot express a styled span (`Content` has no span variant),
so syntax highlighting scales node count with highlight density — and
`scene_codec.Limits.max_nodes` is 16,384, already within 2× of a span-granular
1080p viewport.

Either that sentence is retracted, or third-party viewport providers are
accepted as a slower tier than the bundled one. That is a product decision, not
a technical one.

See [[plugins-not-core]], [[structural-impossibility]],
[[rendering-decomplection]], `rendering.md`, `architecture.md`,
`contextual-workspace-architecture.md` §11.5.

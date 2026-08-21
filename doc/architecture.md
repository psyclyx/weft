# weft as a contextual DI runtime over wasm blobs (north star)

Vision (2026-08-21, user): "weft, as a daemon or a one-shot, is basically a DI
framework wired up with platform things. Things are composed contextually — you may
have an editor system, an agent-UX system, etc., as config; even within these you
can swap things under some circumstances. Almost like Smalltalk, but instead of
classes, wasm blobs."

This doc is the FRAME, not a plan — it names why the concrete work (the caps
registry, the LSP plugin, the rendering decomplection in `rendering.md`) is
pointed the right way, and what the last foundational primitive is.

## The method: generalize the degenerate case

The generative move behind everything below — the user's words: "deal with the
hard problems by finding the actual thing that our first instinct is a degenerate
case of. That same motion, everywhere." When a distinction looks hard (local vs.
remote, me vs. them), don't special-case it — find the GENERAL thing of which both
sides are instances, and make your first instinct the degenerate one:

- local vs. remote → a **placement**; local is a degenerate remote (zero hops).
- self vs. peer → a **principal**; self is a degenerate peer (loopback).
- one editor vs. a session → **principals sharing a graph**; solo is a degenerate
  collab (one principal).
- a mode vs. a system → a **context binding**; a mode is a degenerate system.
- **text vs. structure** → an **object graph**; text is a degenerate projection
  (a linearization). (See below — this is the big one.)
- a permission → a **grant**: a (principal, placement, capability, context) tuple
  the membrane checks. "Can I read this file", "can this peer edit that node",
  "can this plugin spawn a proc" are one mechanism, not three. The rich
  permissions system IS this motion applied to authority: every access is a grant
  resolved against the same context stack the DI container uses, so who-can-do-what
  is contextual, composable, and revocable — not a pile of bespoke checks.

Applied everywhere, the motion is why the pieces fit: they are all instances of a
few general things (principals, placements, grants, capabilities, graph nodes,
contexts), so they compose instead of colliding.

## Core is a kernel, not an editor

Core holds no domain logic. It is:

- a **DI container** — the capability registry: named slots, composition modes
  (first-wins / union / ranked), late + contextual binding;
- the **platform** — window / input / rasterizer / proc / net / fs / clock (wayland
  + vulkan now; X, terminal, browser, macOS, webgpu later, all additive);
- the **substrate** — stemma's document memory, the scene ABI, the wasm host + the
  membrane (the message-passing-with-capabilities layer).

Everything with BEHAVIOR — editing ops, UI slots (`ui/viewport`, `ui/gutter-…`),
LSP, agents, themes, completion — is a **blob**: a wasm module, or an in-process
module over the SAME `abi` contract (the `abi.zig`↔`weft.zig` mirror). A blob
PROVIDES capabilities and CONSUMES others; the container wires them late.

## Systems are compositions, not modes

An "editor", an "agent UX", a REPL, a file manager — none are branches baked into
core. Each is a named **composition**: a manifest of which capabilities are active
and which blobs fill them, in a given context. **Config is that manifest.**
Switching editor→agent-UX is re-binding the container's slots, not `if (mode ==)`.

Composition is **contextual**: the active binding for a capability depends on a
CONTEXT stack (workspace → system → buffer → mode → transient), resolved
most-specific-wins — dynamic scope / method lookup, not one global table. The same
capability resolves to different blobs in different contexts, and you can override
ONE slot in ONE context without disturbing the rest. (This is the general form of
what `edit/completion` providers already do by matching a file extension — a crude,
one-level context.)

## The substrate is stemma's object graph, not text

The deepest application of the method. Our first instinct — "a document is text" —
is the degenerate case. The real thing is **stemma's object graph**: structured
nodes, lazy, holey, multi-gig. Text is a **projection** of the graph (a
linearization for one view); dired is a projection of the filesystem graph; a
symbol outline, a diff, a magit status, an agent transcript — all projections of
the same graph. So the capability mesh, the scene, editing, collab, and permissions
should all operate over the GRAPH, with text as one projection among many:

- **Capabilities act on nodes**, not offsets: `edit/completion` at a node,
  `ui/gutter-segment` for a node's line, a rename that edits the graph and every
  projection re-renders. Offsets are a text-projection detail.
- **The scene projects nodes → primitives.** `ui/viewport` is "project these graph
  nodes into rows/spans"; a structural editor projects the same nodes differently.
  Editing a projection mutates the graph (the editable-projection work — dired —
  is the first instance: name-is-content, save-reconciles the graph).
- **Grants are per-node/subtree.** "This peer may edit that subtree", "this agent
  may read but not write these nodes" — authority scoped to graph regions, the same
  grant tuple as everything else.

**Why this + collab goes incredibly hard.** Collab already generalizes self/peer
into principals sharing state ([[weft-e2e-harness]], collab.zig, the register/
ferry). Put that over an OBJECT GRAPH instead of flat text and you get
**structured collaborative editing**: principals (humans AND agents) concurrently
editing a semantic graph, each through their own projection (one in the text view,
one in dired, one in a structural editor, an agent via the API), merges that are
node-aware not line-aware, grants scoped to subtrees, and projections that update
live across peers. Text-merge conflicts become a degenerate case of graph
reconciliation. That is the thing worth building toward — and it's the same handful
of general primitives (graph, principal, placement, grant, projection, capability)
all the way down.

## The Smalltalk analogy, sharpened

Smalltalk's gift is UNIFORMITY + LATE BINDING + LIVENESS: everything an object,
messages dispatched dynamically, the image live and swappable. weft keeps all three
— capabilities are the messages, blobs are the units, binding is late and
runtime-swappable — but replaces Smalltalk's SHARED MUTABLE IMAGE with
CAPABILITY-SECURE SANDBOXED BLOBS. No spooky action at a distance: a blob touches
only what the membrane grants. So it is **object-capability Smalltalk** — the
liveness and uniformity, minus the global-mutable footguns, plus explicit security.
The membrane is message-passing where the grant IS the capability.

Daemon or one-shot: the container can PERSIST (a live image hosting many systems —
editor windows, agent sessions — as contextual compositions) or run ONCE (wire, do,
exit). Same kernel; the image is just long- or short-lived.

## Already true vs. the one primitive still missing

ALREADY (by good bones): the caps registry is a DI container with named slots +
composition + late binding; the membrane + in-process/wasm transport split is
"blobs, one contract, two transports"; blobs load/unload at runtime; **stemma is
already the object graph** (lazy, holey, multi-gig); **collab already generalizes
self/peer** into principals sharing state; **the membrane already gates by perm**
(a coarse grant). weft is most of the way here already — the primitives exist, mostly
at one crude level each.

MISSING — the primitives to GENERALIZE (the same motion, one more turn):

1. **Contextual resolution.** A CONTEXT/SCOPE layer the caps registry resolves
   against (today: file extension — one crude level). Bindings live at scopes; lookup
   walks the context stack, most-specific wins; overriding one slot in one context is
   first-class. Grants resolve against the SAME stack (authority is contextual).
2. **Graph-native capabilities.** Capabilities keyed on graph nodes/subtrees, not
   text offsets; the scene as a projection of nodes → primitives; grants scoped to
   subtrees. Text becomes one projection.
3. **Systems-as-manifests.** Config that DECLARES a composition (slots × blobs ×
   context) rather than imperatively `bind`-ing, so "a system" is a value you name,
   swap, and nest — not a script that ran.

Those turn "a pile of plugins" into "contextually-composed systems over a shared
graph." Build them once there are enough real slots to exercise them — the UI
capability mesh (`rendering.md`) is that forcing function, exactly as completion
forced the async caps membrane. Sequence: prove the scene ABI + UI slots (rendering
P1–P4), then the context/scope + grant + manifest layer over the graph, then the
rest (the editor view as a slot — P5 — agent-UX as a sibling composition, structured
collab as graph-reconciliation) falls out of the same primitives.

See [[rendering-decomplection]], [[completion-ux-roadmap]], [[abstraction-audit]],
`capabilities.md`, `extensibility.md`.

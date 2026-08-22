# W7 — re-basing weft's `Document` on the unified doc-core, decided

Status: STUDY → DESIGN, REVISION 1 (2026-08-22). Companion to
north-star-plan.md §5 F1/F3, §6 W7; stemma-unification.md §2.3 (the deferred
decision) / §4.2 (the coupling table); d1-live-reconcile.md §1.2, §2.2, §4.
Method, matching the plan: checked against the code, file:line, not against
prose headers. stemma was inspected at HEAD (`build.zig.zon:3` →
`0.4.0-dev`; unification landed **0.2.0**, the move op **0.3.0** — the brief's
"v0.3.0 post-unification" is off by one delta on which version did what, noted
so nobody dates the anchors/compaction work to 0.3.0). Sections are labeled
HYPOTHESIS / DESIGN / DECIDED.

The one-line result up front, because it reshapes the phase:

> **DECIDED: option (i) — Document backed by the one graph core (ObjectDoc with
> one root text node) — is the correct end-state and the only one that honors
> F1's "one doc-core, demolition date on two substrates." But the backing swap
> is NOT the flagship, and it is NOT free today.** The W7 gate as WORDED is
> already satisfied on the substrate people use: an identity-anchored
> `doc_region` grant on a `TextDoc`-backed `Document` (W4 slice 3, SHIPPED)
> survives a peer's concurrent edits and traps loudly on collapse. What the
> graph substrate buys OVER that anchor-range is exactly three things — a
> single node identity in place of a fragile boundary-anchor PAIR, survival of
> a *move* refactor, and exact subtree containment/granularity-refinement — and
> **none of them come from the backing swap alone.** A degenerate one-text-node
> ObjectDoc reproduces the identical anchor-PAIR grant, because a lone text
> object's sub-regions are `objectAnchorAt` pairs, not node ids. Node-keyed
> function grants require a *further* layer — functions as structural nodes +
> the struct forest exposed through the facade + a syntax-claim reconcile — that
> sits on the graph-backed Document but is distinct work. So W7 must be split:
> **W7a (substrate unification, gate = drop-in parity) and W7b (the flagship
> node layer, gate = the function grant).** Do not let "swap the backing" be
> mistaken for "flagship works"; it is not.

---

## 1. The feature-parity ledger — every `TextDoc` capability `Document` consumes

Enumerated from `Document.zig` read in full (not from docs), each row: what
`Document` actually calls, the weft consumer that needs it, and whether
ObjectDoc has it TODAY (stemma HEAD, confirmed file:line by inspection).

| `Document` uses… | `TextDoc` site | weft consumer that needs it | ObjectDoc today |
|---|---|---|---|
| `.empty`/`setAgent`/`deinit`/`insert`/`delete`/`text()` | `Document.zig:66,157,199-211,178` | the hot edit path, everything | **HAVE** — `textInsert`/`textDelete` by `ObjId` (`ObjectDoc.zig:451,467`), `ValueRef.textRope()`→`*const Rope` (`:789`), `setAgent` (`:258`). Needs one root text node's `ObjId` threaded everywhere `text()` is called today. |
| `version`/`compareVersions`/`VersionOrder`/`MergeError` | `Document.zig:183,542,545` | `SyncCore`, dirtiness, undo | **HAVE** — `:957,971,203,201`, identical token model. |
| `serialize`/`open`/`merge`/`eventsSince` | `Document.zig:258,260,655,664` | `addPeer`, `mergeRemote`, wire | **HAVE** — `:987,993,1024,975`. |
| `eventsBetween(gpa, from, to)` | `Document.zig:424` (`peerSyncTo`) | **backing save flow**: `Sync.markSaved`→`peerSyncTo` advances the mirror to the *saved* version, not head (`backing.zig:122-124`) | **GAP — absent.** ObjectDoc exposes only `eventsSince`. |
| `anchorAt`/`resolveAnchors`/`EventAnchor`/`AnchorSide`/`AnchorError` | `Document.zig:60-61,523,530,536` | `exportAnchor`/`resolveAnchors`; **the whole `doc_region` grant** (`grants.zig:139-140`, `command.checkDocRegion:224`) | **HAVE (delta 3)** — `objectAnchorAt`/`resolveObjectAnchors` (`ObjectDoc.zig:1278,1310`), and crucially the **same shared type**: `ObjectDoc.EventAnchor == TextDoc.EventAnchor == seq_walker.EventAnchor` (`ObjectDoc.zig:211-213`, `TextDoc.zig:721-722`, `SeqWalker.zig:213-215`). List-object anchors deferred; text-object anchors are what `Document` needs. |
| `compact`/`CompactError`/`agentWatermarks` | `Document.zig:630,642` | `Editor.compactNow`/`compactIfGrown` (bounds walker replay, `Editor.zig:271,296`) | **HAVE (delta 2), text-only** — `compact` (`ObjectDoc.zig:1446`) folds text-sequence history per object; **refuses lists/structs/maps** with `error.NotCompactable` (`:1492,1497`). For a one-text-node doc that is exactly right; but `agentWatermarks` (for serving partial bases) has no analog. |
| `materializeAt` (`textAt`, time travel) | `Document.zig:551-553` | `Document.textAt`; tests (`core/tests.zig:228,262`) | **GAP — absent.** Only comment refs (`ObjectDoc.zig:1350-1420` explains object-identity replay has no base-materialization story). Low production stakes (test/undo-adjacent). |
| `openFromContent` (bulk load) via `adoptContent` | `Document.zig:595-607` | `Editor.openFile` for files ≥ `bulk_load_bytes` (1 MiB) — else a 4 MB file = 4 M events (`Editor.zig:207,219-224`) | **GAP — absent.** |
| partial checkout: `openPartial`/`realizeBase`/`unrealizedBase`/`baseRealized`/`BaseChunk`/`BaseHole`/`AgentWatermark` | `Document.zig:566-568,573-623` | **`session/PartialDoc.zig`** (editable partial checkout of huge remote docs: `adoptPartial:154`, `realizeBase:166`), `backing.loadBased`, `serveBase` (`Collab.zig:263`) | **GAP — absent entirely.** ObjectDoc's own comment (`:1022`) points OUT to `TextDoc.openPartial` as "a larger feature than this step carries." A whole shipped weft feature with no substrate under it. |
| RLE wire (`WireFormat.rle`/`.unit`) | `TextDoc.zig:94-100` | not called directly (wire is opaque `[]u8`) — but sets wire SIZE and the **cross-version compat** story | **GAP — absent.** ObjectDoc has one flat encoding (`stj\x01`), no RLE, no `WireFormat` type. |
| internal reach `doc.history.eventCount()` | `Document.zig:580,596,637`; `core/tests.zig:1004,1063` (two struct layers deep) | virgin-doc asserts + `Editor.compactIfGrown` threshold | reachable (`history.eventCount()` exists on both graphs, `causal.zig:77`) but the *field reach* is brittle — see §3. |

**The ledger's verdict.** Anchors (delta 3) and text-object compaction
(delta 2) reached parity — the two the plan named as W7 blockers (§2.6:
"deltas 1+3"). But `Document` consumes **five more** ObjectDoc gaps —
`eventsBetween`, `openFromContent`, `materializeAt`, and the whole partial-
checkout family — that the unification work deliberately scoped OUT
(stemma-unification.md §4 risks 4/5 flag partial-checkout and `materializeAt`
as *not costed*). Four of those five are real, shipped weft functionality
(the fifth, `materializeAt`, is test-grade). **Option (i) is therefore not a
drop-in today**; it is a drop-in *after four more stemma deltas*, enumerated in
§4.

**And option (ii) does not dodge these gaps by keeping them — it dodges the
keystone.** If `Document` keeps `TextDoc`'s facade over the now-shared
internals, every feature above survives untouched (zero migration). But a
one-sequence `TextDoc` has no node to key on: the only region a caller can name
is an `EventAnchor` PAIR (`grants.DocRegion.start/.end`, `grants.zig:214-218`),
which is precisely what W4 already shipped. Under (ii), W7 is a rename — it
delivers no capability the flagship doesn't already have, and it leaves two
`Op` types, two `SeqWalker` instantiations' *facades*, and two wire formats
alive permanently. That is the scaffolding-past-its-demolition-date F1 forbids
(§5 F1: "the longer we keep both paths around, the harder it will be to do a
good job").

---

## 2. The flagship gate, decomposed — the crux

The W7 gate (north-star-plan.md §6 W7): *"a function-level subtree grant on an
ordinary CODE buffer, keyed by node identity, surviving a peer's concurrent
refactor or trapping loudly."* Structurally it has four clauses; three are
already met without W7, and the fourth is not met by the backing swap.

### 2.1 What is already SHIPPED — anchor-range grants pass the gate as worded

W4 slice 3 built `grants.Limit.doc_region` (`grants.zig:214-270`) and enforces
it at `command.Context.checkDocRegion` (`command.zig:207-230`), the one edit
chokepoint (`command.edit:248-256`, `wasm_host/edit.zig:110`). It is:

- **identity-anchored, not position-anchored** — the region is an `EventAnchor`
  pair (`start` via `exportAnchor(start,.after)`, `end` via
  `exportAnchor(end,.before)`, `grants.zig:162-167`), keyed on the *insertion
  events* of the boundary characters, not byte offsets;
- **survives a peer's concurrent edits** — after a merge, `resolveAnchors`
  (`command.zig:224`) re-resolves the pair against the new head, so the region
  follows edits made in and around it (the anchors ride FugueMax history);
- **traps loudly on collapse** — a whole-region deletion degenerates the pair
  (`out[0] >= out[1]` → `.collapsed` → `error.Collapsed`, `command.zig:225`);
  an out-of-region edit → `error.OutOfLimit` (`:226`). Never a silent drift
  (grants.zig:179-195 collapse policy).

So the gate's clauses "keyed by [identity], surviving a peer's concurrent
refactor OR trapping loudly" are **already passable on a `TextDoc`-backed
`Document`, today.** The one word left unmet is *node* identity: an anchor PAIR
is not a node.

### 2.2 The crux — what a graph NODE identity buys over an `EventAnchor` PAIR

This is the question the plan's phase label hides. The honest answer, three
items, only the first two of which the gate's "trapping loudly" clause does not
already accept:

1. **Move-survival (the substantive collaboration win).** A graph node keeps
   its `ObjId` under a *move*: stemma's structural forest now has
   `structMove(node, parent, order_key)` with a global-Lamport cycle-break
   (`ObjectDoc.zig:582`, `objects_state.zig:76,691,787`, delta 6 SHIPPED). A
   refactor that relocates a function — reorders it, hoists it to another
   scope/file — keeps the grant. An anchor-pair CANNOT: a genuine cut+paste
   mints new insertion identity, so the pair collapses and traps
   (`grants.zig:197-213` states exactly this: "Wholesale cut+repaste mints new
   identity → collapse → trap"). The gate accepts the trap, so anchor-ranges
   *pass*; but "the agent's grant follows its function through a peer's
   reorganize" is only real on the graph substrate.

2. **Collapse robustness.** The anchor-pair collapses whenever *both* boundary
   characters die or the span degenerates (`command.zig:225`) — a refactor that
   rewrites a function's first and last lines can *accidentally* collapse a
   perfectly valid grant. A node grant collapses only when the *node* is
   deleted/unreachable (`GraphDoc.reachable`, `graph.zig:594`) — a semantically
   cleaner condition tied to the function's existence, not to two specific
   characters surviving.

3. **Exact subtree containment + granularity refinement.** A node grant is a
   subtree membership test (`GraphDoc.contains`, `graph.zig:584`), so "the
   agent may edit this function AND its sub-nodes" is exact, and "syntax-driven
   node claims refine granularity" (§2.6: per-statement sub-grants) becomes
   expressible. An anchor-pair is a flat byte interval — fine for a contiguous
   function, but it cannot express nested or refined structure.

**But the crux's sting:** for a *contiguous function that is edited (not
moved)*, the anchor-pair grant and the node grant are **observably
identical** — both survive concurrent edits, both trap on whole-function
deletion. The graph substrate's marginal value is realized ONLY under move
refactors and boundary-collapse edge cases. And:

### 2.3 A code buffer is ONE text node or MANY struct nodes — and only MANY delivers node identity

- **One text node (the literal "text is a degenerate graph doc" swap).** A
  code buffer becomes `root.map → "body": text`. Its sub-region grants are
  `objectAnchorAt` PAIRS on that one text object (`ObjectDoc.zig:1278`) —
  **the same anchor-pair grant `TextDoc` already gives.** Option (i)'s backing
  swap, *by itself, buys nothing for the flagship.*
- **Many struct nodes (what node identity requires).** Each function is a
  structural node (`structCreate` under a parent register, `ObjectDoc.zig:544`),
  its body a text object; the grant keys on the function node's `NodeRef`
  (`grants.GraphSubtree`, `graph_subtree` limit, `grants.zig:253-270`),
  enforced at admission (`GraphCollab.admitRegions` via
  `GraphDoc.touchedRegionsWithin`, `graph.zig:379`). THIS is the only shape that
  is "keyed by node identity."

Two concrete facts make the second shape *not yet buildable* even on a
graph-backed Document:

- **The struct forest is not exposed through `GraphDoc`.** `graph.zig`
  deliberately exposes no `structMove`/`reparent` (`graph.zig:44-59`), and the
  containment walk `walkContains` explicitly does NOT follow struct parentage —
  `.structure` changes are marked UNREACHABLE with a note that `contains` "must
  learn the structural forest (`structParent` parentage)" before struct moves
  work (`graph.zig:411-413`). So the shipped W6 subtree-grant machinery is
  map/list-containment only; it is not flagship-ready for struct-node functions.
- **Tree-sitter node boundaries do not carry stable identity.** A reparse
  produces a fresh tree; its node ids are not stable across edits. Binding "the
  function tree-sitter currently sees" to "a persistent `ObjId`" is a
  structural-reconcile problem — the `on_save`/`live` id-diff of
  editable-projection.md / d1-live-reconcile.md §1.3. *In-function* text edits
  are stable for free (a `textInsert` on the function's own text object needs no
  reconcile); *structural* refactors (add/remove/reorder/rename a function)
  need the reconcile to keep identity. So the flagship's "surviving a concurrent
  refactor" splits exactly along D1's line: content edits are convergent by
  construction, structural refactors ride the move op + reconcile.

**Crux conclusion (DESIGN).** The graph substrate buys, over `EventAnchor`
ranges, precisely *move-survival + node-robust collapse + subtree
containment* — and it buys them only when functions are **structural nodes**,
which needs the struct forest through the facade + a syntax-claim reconcile, not
the backing swap. The backing swap is necessary infrastructure to *host* those
nodes in the same document as the code text (F1's one-doc-core), but it is not
sufficient and it is not, itself, the flagship.

---

## 3. Migration cost map, per option

Persistence first, because it removes a fear: **disk is plain UTF-8, zero
stemma bytes** — `backing.zig` stores file content (`load`/`mergeExternal`
diff raw bytes; `Editor.adoptContent` takes raw content, `Editor.zig:220`).
Confirmed: no file under `src/` references TextDoc's `stg`/`stj` magic. So
**neither option has any disk-migration cost.** The wire is the opposite.

### 3.1 The collab wire — a fleet-wide flag-day, not per-session negotiable

`SyncCore(Doc)` (`sync_core.zig:52`) and `Collab`/`GraphCollab` treat batch
bytes as **opaque `[]u8`** (`sync_core.admitBatch:141`, `Collab.mergeRemote`
call `Collab.zig:172`) and **do not negotiate doc format**. TextDoc's wire
(`stg\x01/2/3`, RLE) and ObjectDoc's (`stj\x01`, flat) are different formats.
Therefore two live peers on different backings **cannot sync** — one on a
`TextDoc`-backed `Document` (old build), one on a graph-backed `Document` (new
build), each hands the other bytes it cannot decode. There is no version byte
in the frame the driver reads to branch on. **Consequence: the swap is a
fleet-wide flag-day for live text collab.** Bounded, because: (a) disk and
solo editing are unaffected; (b) `GraphCollab` is not yet wired into `main.zig`
(zero call sites — graph collab is host/test infra). But `Collab(Document)` IS
the shipped text-collab path (`Collab.zig:47`), so mixed-version collaborators
break. Mitigation options, all deferrable, none free: a wire-format version
byte + a decode fork (keep decoding old `stg` frames), or accept the flag-day
for a pre-GA collab feature. This is the single decision §2.4 of the
unification study deferred and it lands here.

### 3.2 Option (i) — swap the backing (RECOMMENDED end-state; must not be flag-dayed)

- **Files touched.** `Document.zig` (backing field `doc: TextDoc`
  `:66` → the graph core; ~40 methods reimplemented over one text node, incl.
  `Peer.replica` `:94` — each shadow peer becomes a whole ObjectDoc, heavier
  but functional). `backing.zig` (`loadBased`/`markSaved` ride `eventsBetween`
  + partial base — blocked on the gaps below). `session/PartialDoc.zig` +
  `remote_fs.serveBase` (whole partial-checkout feature, blocked). `Editor.zig`
  (`openFile` bulk-load `:219`, `compactNow` `:271`). `grants.zig:139-140` +
  `command.checkDocRegion` (anchor type — LOW risk, already the shared type).
  `core/tests.zig` + `tests.zig:32`. Only **three sites import `stemma.TextDoc`
  directly** (`Document.zig`, `grants.zig` type-alias, `tests.zig` smoke) — the
  coupling is concentrated, per stemma-unification.md §4.2.
- **Blocked on four stemma deltas** (§1): `eventsBetween`, `openFromContent`,
  partial checkout (`openPartial`/`realizeBase`/`agentWatermarks`/…),
  `materializeAt`. Without them the swap *regresses shipped features*.
- **Two internal-reach landmines** (unification §4.2): `self.doc.history.
  eventCount()` (`Document.zig:580,596,637`) and the two-layers-deep
  `ed.doc.doc.history.eventCount()` (`core/tests.zig:1004,1063`). Both depend on
  field names `doc`/`history` surviving the swap. Fix BEFORE swapping (§4).
- **Type surface.** `Document` re-exports `TextDoc.{EventAnchor,AnchorSide,
  VersionOrder,MergeError,CompactError,AnchorError,BaseChunk,AgentWatermark,
  BaseHole}` verbatim (`Document.zig:60-62,523,542,545,566-568`). The anchor
  triad is already the shared `seq_walker` type (delta 3), so it does NOT churn
  — a load-bearing correction to the unification study's fear. `BaseChunk`/
  `AgentWatermark`/`BaseHole` DO churn (partial checkout has no ObjectDoc form
  yet), but only if partial checkout is ported rather than dropped.
- **Test surface.** `Document`, `backing`, `PartialDoc`, `Collab`,
  `command.checkDocRegion` batteries; the two-peer convergence tests; a
  fresh gate: solo edit/save/undo/anchor/compact round-trip on the graph core.

### 3.3 Option (ii) — keep the `TextDoc` facade (REJECTED)

- **Migration cost: ~zero.** Nothing above changes; every feature survives.
- **Fatal flaw #1 — it cannot host node identity.** A one-sequence `TextDoc`
  has no `ObjId` per function; the flagship's node-keyed grant is inexpressible
  on it. It offers only the anchor-pair grant already shipped (§2.1). It
  *dodges the keystone*.
- **Fatal flaw #2 — it violates F1 permanently.** Two `Op` types, two facades,
  two wire formats stay alive with no demolition date — exactly what §5 F1
  forbids. "W7 ran" would be a rename, not the inversion.

### 3.4 The `SyncCore` seam — already proven doc-agnostic (lowest risk)

`SyncCore(Doc)` is instantiated `SyncCore(Document)` (`Collab.zig:47`) and
`SyncCore(GraphDoc)` (`GraphCollab.zig:107`) TODAY, over the shared
`version`/`eventsSince`/`serialize` interface (`sync_core.zig:48-52`). So the
sync-framing layer already treats a text-backed and a graph-backed doc
polymorphically with zero special-casing — direct evidence that the swap costs
nothing at the frontier/announce/admission layer. The merge call and its
`error.Unrealized` partial-checkout recovery stay per-driver (`sync_core.zig`
doc comment; `Collab.zig:172-183`), which is exactly the partial-checkout gap
resurfacing as a driver concern.

---

## 4. Sequencing — converge, then swap, then build the node layer (each gate falsifiable)

W7 lands as **incremental steps behind the existing facade**, never one swap.
The falsifiable gate per step:

**W7-0 (weft, no backing change) — kill the reaches, unify the type surface.**
Add `pub fn eventCount()` to `TextDoc`/ObjectDoc; route `Document.eventCount`
(`:637`) and the two test reaches (`core/tests.zig:1004,1063`) through it —
delete every `self.doc.history.` field access. Confirm `grants.EventAnchor`
(`grants.zig:139-140`) and `Document`'s anchor re-exports point at the shared
`seq_walker.EventAnchor` (they already resolve to it — make it explicit).
*Gate:* no `.history.` reach anywhere under `src/`; `zig build test` green;
`explain`/no behavior change.

**W7-1 (stemma) — close the four Document-consumed gaps** (dependency order):
`eventsBetween` on ObjectDoc (small — a `diff` between two tokens, the shape
already in `causal.zig`); `openFromContent`-equivalent bulk-load for a text
object (materialize content as a compacted text base, zero events);
`materializeAt`-equivalent (or accept its loss — test-grade); the
partial-checkout family for a text object (the large one —
`openPartial`/`realizeBase`/`agentWatermarks` per stemma-unification.md §4
risk 4, explicitly *not costed there*). *Gate:* an ObjectDoc-with-one-text-node
passes `Document.zig`'s full test battery as a drop-in, incl. backing
save/`peerSyncTo`, ≥1 MiB bulk-load, and a `PartialDoc` round-trip.

**W7-2 (weft) — decide the wire flag-day** (§3.1). Either add a frame
version byte + old-`stg` decode fork, or ratify the fleet-wide flag-day for
pre-GA collab. *Gate:* stated in-repo; a two-peer convergence test on the new
wire; if forking, an old×new interop test.
**[DECIDED 2026-08-22 — flag-day, ratified.]** Live text collab is pre-GA
with no deployed mixed-version fleet: weft's main has never been pushed,
`GraphCollab` has no production call site, and `Collab(Document)`'s peers
are the dogfooding user's own builds. A version-byte decode fork would
preserve compatibility no live session needs, at the cost of a second
decode path with no demolition client. Ratified: W7a's swap changes the
collab wire wholesale (`stg` → `stj`); peers must run same-era builds;
the two-peer convergence test on the new wire is the gate. If a real
fleet exists before W7a lands, this decision reopens.

**W7a (weft) — the backing swap for the degenerate case.** `Document.doc:
TextDoc` → the one graph core with a single root text node; reimplement the
~40 methods; each `Peer.replica` becomes an ObjectDoc. *Gate (substrate
parity, NOT the flagship):* `Document`/`backing`/`Collab`/`PartialDoc`/
`checkDocRegion` tests green; solo edit/save/undo/anchor/compact round-trips;
two graph-backed peers converge; the shipped `doc_region` grant still traps
identically. **This is F1's actual mandate met — one doc-core.**

**W7b (weft) — the flagship node layer.** Expose the struct forest through
`GraphDoc` (`structCreate`/`structMove`, teach `walkContains` `structParent`
parentage — the `graph.zig:411-413` TODO); a syntax-driven node-claim
reconcile mapping tree-sitter functions to stable `ObjId`s (D1/editable-
projection id-diff, §2.3); grant on the function `NodeRef` via `graph_subtree`
+ `GraphCollab.admitRegions`. *Gate (THE W7 GATE):* a function-level subtree
grant on a code buffer, keyed by node identity, survives a peer's concurrent
in-function edit AND a peer's move/reorder of the function, OR traps loudly on
the function's deletion/collapse.

**Where each stemma delta already sits:** SeqWalker (`SeqWalker.zig`, both docs
via `.dense`/`.sparse`), anchors (delta 3, `objectAnchorAt`), text compaction
(delta 2, text-only), move op (delta 6, `structMove` + global-Lamport
cycle-break) — all SHIPPED at HEAD. W7-1's four gaps are the *un-shipped*
remainder, and they were scoped out of the unification deltas on purpose.

---

## 5. Recommendation — DECIDED

**DECIDED: incremental option (i) — rebase `Document` onto the one graph core —
sequenced "converge → close the four gaps → swap → build the node layer" (§4),
and W7's single gate is SPLIT into W7a (substrate parity) and W7b (the
flagship).** One-sentence rationale: only a graph-backed `Document` gives F1 its
one doc-core with a demolition date, but the flagship's node identity lives in a
*structural-node layer on top of* that swap — not in the swap — so pretending
"swap the backing" equals "flagship works" would ship the phase against a gate
its own mechanism can't meet.

**Losers, with their fatal flaws:**

- **Option (ii) (keep the `TextDoc` facade)** — cannot express per-function
  node identity at all (a one-sequence doc has no `ObjId` to grant on, §2.1),
  and freezes two `Op` types / two wire formats in place forever, the exact
  scaffolding F1 puts a demolition date on. It makes W7 a rename that dodges the
  keystone.
- **Naive flag-day option (i) (swap today)** — regresses four shipped features
  with no substrate under them (partial checkout of huge remote docs, ≥1 MiB
  bulk-load, `eventsBetween` backing-save, `materializeAt`) and breaks live
  collab between mixed-version peers with no negotiation path (§3.1).

**On whether the flagship is satisfiable WITHOUT the full backing swap —
plainly, per the brief's invitation.** *Yes, as the gate is worded, and it
already is:* the SHIPPED `doc_region` anchor-range grant on `TextDoc` (W4 slice
3) survives a peer's concurrent edits and traps loudly on collapse (§2.1). The
backing swap alone reproduces that grant unchanged (a lone text object is
anchor-pairs, §2.3). So **W7's honest content is not "make the flagship work" —
the flagship's *worded* behavior works now.** W7's honest content is two
separable things the plan conflates:

1. **W7a — the substrate inversion** (F1's real mandate): one doc-core, text as
   the degenerate one-node graph doc, so no code lives on a second `Op` type or
   wire. Its honest gate is **drop-in parity**, not the flagship.
2. **W7b — the capability upgrade**: functions as structural nodes, delivering
   the three things anchor-ranges cannot (move-survival, node-robust collapse,
   subtree granularity, §2.2), which needs the struct forest through the facade
   + a syntax-claim reconcile, and which is what the plan's W7 gate actually
   tests.

W7 stays MANDATORY (F1) — but its keystone is **W7a**, and the flagship gate
belongs to **W7b**. Keeping them fused is how the phase would quietly ship a
backing swap and declare the flagship done while every function grant on the
new substrate is still, byte-for-byte, the anchor-pair grant that already
shipped on the old one.

---

## References

- `src/core/Document.zig` — the facade; the feature-consumption ledger's source.
- `src/core/grants.zig` (`DocRegion`/`GraphSubtree`/`Limit`), `src/core/command.zig`
  (`checkDocRegion:207`, `edit:248`) — the SHIPPED anchor-range grant (§2.1).
- `src/core/graph.zig` — `GraphDoc`, `contains`/`reachable`, `touchedRegionsWithin`,
  and the `walkContains` struct-forest TODO (`:411-413`) blocking W7b.
- `src/core/session/{sync_core,Collab,GraphCollab,PartialDoc}.zig`,
  `src/core/backing.zig`, `src/core/Editor.zig` — the swap's blast radius + the
  four gaps' consumers.
- `lib/stemma` HEAD (`0.4.0-dev`): `SeqWalker.zig`, `TextDoc.zig`,
  `ObjectDoc.zig` (`objectAnchorAt:1278`, `compact:1446`, `structMove:582`),
  `objects_state.zig` (`resolveStructs:691`) — what each doc has today.
- north-star-plan.md §5 F1/F3, §6 W7; stemma-unification.md §2.3/§4.2;
  d1-live-reconcile.md §1.3/§4 — the mandate, the deferred decision, the
  structural-reconcile dependency.

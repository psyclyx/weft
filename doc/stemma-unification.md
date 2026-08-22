# stemma unification — TextDoc/ObjectDoc doc-core, precisely

Status: STUDY, READ-ONLY (2026-08-22). Companion to north-star-plan.md §5 F1/F3,
§6 W5/W7, and d1-live-reconcile.md §4. Everything below was checked against
`lib/stemma` source, file:line, not against either doc's prose header. Where the
header's claim ("the same FugueMax semantics as TextDoc," ObjectDoc.zig:3–5)
turns out to be literally true at the code level, that is noted as such; where
it understates or overstates, the gap is named.

The one-line result up front:

> **The duplication is real but it is NOT "two independent CRDT
> implementations."** The causal graph (`causal.EventGraph(Op)`), the FugueMax
> ordering engine (`Sequence.zig`), the LEB128 wire primitives (`wire.zig`), and
> the version-token protocol (`core.zig`) are ALREADY one shared implementation,
> comptime-instantiated per doc type. What is duplicated is the layer directly
> above that: the per-sequence prepare/effect *replay driver* (TextDoc's
> `Replay` vs ObjectDoc's `Walker`), and everything TextDoc has that ObjectDoc's
> header admits it doesn't (compaction, anchors, partial checkout) — because
> those were built once, against TextDoc's single sequence, and never
> generalized to ObjectDoc's tree of sequences. The wire formats are also fully
> separate, but for a good reason (TextDoc's is RLE-compressed and
> compaction/partial-checkout-aware; ObjectDoc's isn't), and this study
> recommends NOT unifying them.

---

## 1. The duplication map

Function-level, both files read in full (`TextDoc.zig` 1750 lines,
`ObjectDoc.zig` 1075 lines, plus their shared substrate).

### 1.1 Already shared (one implementation, two instantiations)

| concern | shared unit | TextDoc instantiation | ObjectDoc instantiation |
|---|---|---|---|
| causal event graph, frontier, two-frontier diff | `causal.EventGraph(comptime Op)` (`causal.zig:38–297`) | `Graph = causal.EventGraph(TextOp)` (`TextDoc.zig:71`) | `Graph = causal.EventGraph(ObjectOp)` (`objects_state.zig:51`) |
| agent identity: register/lookup/name, per-agent seq contiguity | `EventGraph.registerAgent`/`findAgent`/`agentName`/`nextSeq`/`isKnown`/`lvOf` (`causal.zig:85–134`) | `TextDoc.setAgent` → `history.registerAgent` (`TextDoc.zig:279–281`) | `ObjectDoc.setAgent` → `history.registerAgent` (`ObjectDoc.zig:127–129`) |
| local event append, frontier advance | `EventGraph.add`/`addLocal`/`advanceFrontier` (`causal.zig:154–206`) | `TextDoc.insert`/`delete` call `history.addLocal` (`TextDoc.zig:304,325`) | `ObjectDoc.mapSet`/`listInsert`/`textInsert`/… call `history.addLocal` (`ObjectDoc.zig:250,283,314,…`) |
| version/frontier comparison | `EventGraph.diff`/`missingFrom`/`compareFrontiers` (`causal.zig:226–295`) | `TextDoc.compareVersions`/`eventsSince` (`TextDoc.zig:391–463`) | `ObjectDoc.compareVersions`/`eventsSince` (`ObjectDoc.zig:565–579`) |
| opaque version-token encode/decode, single-entry parse | `core.encodeVersion`/`decodeVersion`/`compareVersions`/`versionSingleEntry` (`core.zig:23–94`) | `TextDoc.version`/`decodeVersion`/`compareVersions` (`TextDoc.zig:369–398`) delegate directly | `ObjectDoc.version`/`decodeVersion`/`compareVersions` (`ObjectDoc.zig:551–567`) delegate directly |
| batch agent-table helpers | `core.tableAdd`/`tableIndexOf` (`core.zig:97–105`) | used in `encodeEvents` (`TextDoc.zig:1442–1443`) | used in `encodeEvents` (`ObjectDoc.zig:895–896`) |
| LEB128 wire primitives | `wire.putUv`/`getUv`/`getBytes` (`wire.zig:6–38`) | throughout `encodeEvents`/`Decoder` | throughout `encodeEvents`/`Decoder` |
| **the FugueMax sequence engine itself** | `Sequence.zig` (482 lines) — treap-backed order-statistics tree, `applyInsert`/`applyDelete`/`toggleInsert`/`toggleDelete`/`integrate`/`effectPositionOf` (`Sequence.zig:334–440`) | `TextDoc.Replay.s: Sequence` (`TextDoc.zig:112`), used by `replayAll` | `Walker.seqs: AutoHashMapUnmanaged(Lv, Sequence)` — one `Sequence` per list/text object (`objects_state.zig:99`), used by `apply` |
| agent-name tiebreak in FugueMax integration | `Sequence.integrate`'s `names.agentNameOf(lv)` comparison (`Sequence.zig:414`) | `Replay.Names.agentNameOf` (`TextDoc.zig:121–129`) | `Walker.Names.agentNameOf` (`objects_state.zig:117–122`) — **identical rule**, not just parallel code |
| pure edit-delta value types, anchor-shift arithmetic | `geometry.Edit`/`Anchor.shift` (`geometry.zig`) | `TextDoc.Edit` reuses `geometry.Edit` | `ObjectDoc.Change.text.edit` reuses `geometry.Edit` |

This is the load-bearing correction to "the same FugueMax semantics as
TextDoc" (ObjectDoc.zig:3–5): it is not a *claim*, it is *the same function*,
called with a different `Sequence` instance per object. Anyone reasoning about
unification from "two CRDT engines" is reasoning from a false premise — there
is one engine, already shared, at exactly the layer that matters most for
correctness (interleaving, tombstones, ordering).

### 1.2 Duplicated (same discipline, two hand-written drivers)

| concern | TextDoc | ObjectDoc | verdict |
|---|---|---|---|
| prepare/effect retreat-advance walker | `Replay.movePrepareTo`/`toggle`/`replayAll` (`TextDoc.zig:199–219`, `162–197`) — one `Sequence`, diff against `history`, retreat newest-first/advance oldest-first | `Walker.movePrepareTo`/`toggle`/`replayAll` (`objects_state.zig:201–213`, `217–243`, `186–199`) — same retreat/advance shape, generalized to dispatch by op kind across N sequences + M map registers | **Duplicated.** Structurally near-identical loops (`diff`, reverse-walk `a_only` calling `toggle(_, false)`, forward-walk `b_only` calling `toggle(_, true)`) written twice, once specialized to "exactly one sequence" and once to "a dynamic set of sequences + registers." |
| merge orchestration: decode → register agents → add events → replay → rollback-on-error | `TextDoc.merge`/`historyPhase`/`rollbackHistory` (`TextDoc.zig:948–1199`) | `ObjectDoc.merge`/`historyPhase` (`ObjectDoc.zig:599–743`) | **Duplicated**, same shape (snapshot pre-state lengths, `errdefer` rollback, `first_new` cursor, per-event `isKnown` skip, parent resolution) — but TextDoc's carries extra machinery (base/bootstrap/watermark/hole handling) ObjectDoc's doesn't need. The graph-rollback skeleton itself doesn't care about `Op` and could be one generic helper. |
| local editing → event recording → materialized-state update | `TextDoc.insert`/`delete` (`TextDoc.zig:294–330`) | `ObjectDoc.textInsert`/`textDelete`/`mapSet`/`listInsert`/… (`ObjectDoc.zig:243–333`) | Necessarily different (map/list semantics don't reduce to char ops), but the *text*-shaped ops (`textInsert`/`textDelete`) are near-identical to `TextDoc.insert`/`delete` restricted to one object — same per-scalar-unit event loop, same rope update, same edit-coalescing shape (`ObjectDoc.zig:653–668` vs `TextDoc.zig:1022–1057`). |
| wire encode/decode (event batches) | `TextDoc.encodeEvents`/`Decoder` (`TextDoc.zig:1239–1745`, ~500 lines: v1/v2/v3, RLE run detection, base sections, hole-aware) | `ObjectDoc.encodeEvents`/`Decoder` (`ObjectDoc.zig:789–1071`, ~280 lines: one format, no RLE, no base/compaction fields) | **Duplicated at the mechanical level** (agent table, LEB128 event loop, parent-list encoding) but genuinely divergent CONTENT (RLE run detection has no ObjectDoc analog since ops are heterogeneous across a tree, not a monotone char stream). Recommend NOT merging these — see §2. |

### 1.3 Present in TextDoc only (ObjectDoc's own header ledgers these as missing, ObjectDoc.zig:21–25)

| concern | TextDoc | ObjectDoc |
|---|---|---|
| compaction (frozen base snapshot, watermark-raising, graph renumbering) | `TextDoc.compact` (`TextDoc.zig:855–935`) | **Absent.** `ObjectDoc.zig:21` ledgers it explicitly: "Not yet (ledgered): compaction for ObjectDoc." |
| identity anchors (`anchorAt`/`resolveAnchors`/`EventAnchor`) | `TextDoc.zig:721–843` | **Absent.** `ObjectDoc.zig:22`: "identity anchors inside ObjectDoc text objects." |
| partial checkout (`openPartial`/`realizeBase`/`BaseHole`/`AgentWatermark`) | `TextDoc.zig:484–660` | **Absent** entirely; no analog, no ledger entry (a strict superset of the compaction gap — partial checkout is compaction-dependent). |
| bulk-load-as-base (`openFromContent`) | `TextDoc.zig:592–625` | **Absent.** |
| RLE wire compression (`WireFormat.rle` / `.unit`, run detection) | `TextDoc.zig:1213–1232`, `insRunAt`/`delRunAt`/`chains` (`1392–1440`) | **Absent** — every event is wire-individual. |
| time travel (`materializeAt`) | `TextDoc.zig:667–719` | **Absent.** |

### 1.4 Present in neither (the move op)

Neither `TextDoc` nor `ObjectDoc` has a move/reparent operation. F3's
parent-register + fractional-order-key design is validated ONLY in
`structure_sketch.zig`, deliberately kept out of the public `stemma` module
(`build.zig:29–43` wires its tests into `zig build test` via a private module,
NOT via `stemma_mod`; `structure_sketch.zig:1–14` states this explicitly).
`ObjectDoc`'s facade also structurally forecloses it today: `mapSet`/
`listInsert` "accept only FRESH `Value`s, never an existing `ObjId`"
(cited by d1-live-reconcile.md:340 against `ObjectDoc.zig`'s op shapes —
confirmed: `ObjectOp` (`objects_state.zig:42–49`) has no `move` variant).

---

## 2. The unification shape

Three candidate shapes, weighed against the plan's four constraints (delta 3
lands once in the core; delta 2 likewise; W7 needs text-as-degenerate-graph-doc;
wire compatibility).

### Option A — ObjectDoc text objects literally become embedded `TextDoc` instances

**Rejected.** `ObjectDoc` deliberately has ONE `EventGraph(ObjectOp)` shared
across every map/list/text op in the whole tree (`ObjectDoc.zig:86`); object
identity IS a creation-event `Lv` in THAT graph (`ObjId = EventId`,
`objects_state.zig:29`), and map/list ops reference other objects by id
INTO THAT SAME GRAPH (`ObjectOp.map_set.val: ValPayload.new_text` created and
referenced via the one graph's `lv`s — `ObjectDoc.zig:196–214`). Embedding a
separate `TextDoc` (its own `EventGraph(TextOp)`, its own frontier, its own
agent table) per text node would fork causal history per node — cross-object
causality (a map key set concurrently with an edit to the value it names)
becomes two graphs that can't be diffed/frontier-compared against each other
in one `EventGraph.diff` call, breaking `ObjectDoc.merge`'s single
atomic-rollback batch model (`ObjectDoc.zig:696–743`) and the single wire
format's one-agent-table-per-batch design. This is not a refactor, it is a
different CRDT.

### Option B — TextDoc becomes "ObjectDoc specialized to one text node"

**Rejected as the unification vehicle, though it is the right SHAPE for
weft's Document post-W7 (see §2.3).** Collapsing TextDoc into ObjectDoc's
representation today would mean either (a) giving up TextDoc's compaction,
RLE wire, partial checkout, and anchors — regressions with no compensating
gain, since ObjectDoc doesn't have them yet — or (b) porting ALL of that
machinery into ObjectDoc first, at which point Option C has already been
done and Option B is just "then also delete TextDoc," a separate, later,
much lower-stakes decision (renaming/deleting a thin specialization once its
substance is shared) that doesn't need to be made now and directly trades off
against wire-format compatibility (§2.4).

### Option C — RECOMMENDED: extract the shared layer ONE LEVEL ABOVE `Sequence.zig`, generalize compaction/anchors there, keep both facades and both wire formats

Concretely: a new shared unit — call it `SeqWalker.zig` — that factors out
the retreat/advance/replay discipline currently duplicated between
`TextDoc.Replay` (`TextDoc.zig:111–220`) and the sequence-handling half of
`objects_state.Walker` (`objects_state.zig:201–243, 317–353`). It is
generic over:
- the `EventGraph(Op)` instance (comptime, same pattern `causal.zig` already
  uses),
- a small "op view" — given an `lv`, is this event a sequence op targeting
  `Sequence` S, at prepare-position P, ins or del — supplied by the caller
  (TextDoc: always "yes, the one sequence"; ObjectDoc: dispatch by
  `ObjectOp` tag + `resolveObj`),
- an emit sink type (TextDoc's `ScalarEdit`; ObjectDoc's `Effect`).

`TextDoc.Replay` becomes a 1-sequence instantiation of `SeqWalker`; the
sequence-op half of `objects_state.Walker` becomes N per-object
instantiations (map-register logic stays ObjectDoc-only — registers aren't
sequences and have no TextDoc analog). This is exactly weft's own
`SyncCore(Doc)` precedent (`app/weft/src/core/session/sync_core.zig` per
weft's docs) — a comptime-generic core with an informal required interface,
not a class hierarchy.

Once that layer exists, **delta 3 (anchors) and delta 2 (compaction) land
ONCE, against `SeqWalker` + `EventGraph(Op)`, generic over `Op`:**
- `anchorAt`/`resolveAnchors`/`EventAnchor` (`TextDoc.zig:721–843`) touch
  only `Replay`'s `Sequence` + `history`'s `idOf`/`agentName` — nothing
  TextDoc-specific. Generalized to `SeqWalker`, TextDoc's own anchors become
  a call-through, and ObjectDoc gets per-text-object (and, for free,
  per-LIST-object) anchors by calling the same function against each
  object's `SeqWalker` instance. **This is delta 3, and it is the D1
  blocker** (d1-live-reconcile.md §4: "the hard blocker for the text half").
- `compact`'s GRAPH-LEVEL half — rebuild `new_graph` with raised watermarks
  and renumbered `lv`s (`TextDoc.zig:888–917`) — is already generic over
  `Op` (it never inspects `TextOp`, only `EventGraph` shape: `parentsOf`,
  `add`, agent watermarks). This extracts verbatim as a shared
  `compactGraph(EventGraph(Op), ...)` helper. The SEQUENCE-LEVEL half
  (materialize each sequence's base content before the graph rebuild,
  `TextDoc.zig:880–884`) generalizes to "materialize each object's base via
  its `SeqWalker`," called once per sequence-shaped object in ObjectDoc's
  tree instead of once for TextDoc's single sequence. **This is delta 2.**
  ObjectDoc's map registers have no compaction story yet even after this —
  MV-register history compaction (when is a superseded map_set safe to
  forget?) is a genuinely separate, harder problem this refactor does not
  solve, and should be scoped OUT of delta 2 explicitly (see §4 risk 5).

Constraint (c) — W7 needs weft's `Document` to re-base text buffers as
degenerate one-node graph docs: once `SeqWalker`/anchors/compaction are
shared, TextDoc genuinely IS "an EventGraph(TextOp) with exactly one
`SeqWalker`" — Option B's shape becomes TRUE of the shared internals even
though TextDoc keeps its own facade and wire format. W7's rebase can then
target either (i) weft's `Document` switching to be backed by `ObjectDoc`
with one root text node (Option B realized, now cheap because the substance
already moved), or (ii) a thin unification where `TextDoc` and
"ObjectDoc-with-one-node" both compile down to the same `SeqWalker`
instantiation and W7 picks whichever facade is less churn for
`app/weft/src/core` call sites. Option C keeps that decision open and cheap
instead of forcing it now.

### 2.4 — Wire-format compatibility: RECOMMENDED — do not unify wire formats

TextDoc's wire (`TextDoc.zig:1201–1233`: v1/v2/v3, RLE run detection,
base/compaction sections, hole-aware partial-base flag) and ObjectDoc's wire
(`ObjectDoc.zig:780–786`: one flat format, heterogeneous op stream, no RLE, no
compaction fields) diverge for a real reason: TextDoc's is optimized for a
monotone single-object char stream (RLE pays off exactly there); ObjectDoc's
events are heterogeneous (map/list/text ops interleaved across many objects)
where run-detection has no natural analog. **Recommendation: Option C shares
the ENGINE, not the WIRE.** Consequence: every existing serialized `TextDoc`
(`"stg\x01/2/3"`) and the collab wire protocol survive completely unchanged —
`SeqWalker`/anchors/compaction are internal refactors behind the existing
`TextDoc.serialize`/`merge`/`eventsSince` public API, which does not change
shape. No migration step is needed for §1–2's plan. (A LATER, separate
decision — converging the wire formats too, e.g. once ObjectDoc's text
objects want RLE for parity — is explicitly out of scope here and would need
its own versioned-migration design; nothing in Option C requires or blocks
it.)

---

## 3. The incremental path

Six steps, each separately landable, each leaving BOTH `zig build test`
suites green (`stemma_mod`'s existing tests plus the sketch-module tests
wired at `build.zig:36–43`). None of steps 1–4 touch wire bytes. Step 5 adds
new wire content (additive, doesn't invalidate old bytes). Step 6 is
weft-side, out of `lib/stemma`.

1. **Extract `SeqWalker` from `TextDoc.Replay`, behavior-preserving.** New
   file (or a new section of `Sequence.zig`) generalizing
   `movePrepareTo`/`toggle`/`replayAll` (`TextDoc.zig:162–219`) to be generic
   over an op-view + emit-sink, with `TextDoc.Replay` becoming a thin 1-object
   wrapper. Zero behavior change — pure refactor, same test suite proves it.
   Est. **~250 lines touched in TextDoc.zig, ~200 new lines in the shared
   file, 0 new tests required** (existing `text_tests.zig`'s full suite is
   the gate; a handful of direct `SeqWalker` unit tests are cheap insurance,
   ~5).
2. **Rebuild the sequence half of `objects_state.Walker` atop `SeqWalker`.**
   `list_ins`/`list_del`/`text_ins`/`text_del` dispatch (`objects_state.zig:
   217–243, 317–353`) calls into the shared walker per-object instead of its
   own hand-rolled toggle loop; `MapReg`/`registerWrite` stay untouched (no
   `SeqWalker` involvement — registers aren't sequences). Gate: full
   `object_tests.zig` green, byte-identical `toJson` outputs before/after.
   Est. **~150 lines touched in objects_state.zig, 0 new tests** (existing
   suite is the gate).
3. **Generalize anchors; land delta 3 on ObjectDoc text objects.** Extract
   `anchorAt`/`resolveAnchors`/`EventAnchor` (`TextDoc.zig:721–843`) into a
   function over `(EventGraph(Op), SeqWalker instance)`; `TextDoc`'s own
   `anchorAt` becomes a call-through; ObjectDoc gains
   `objectAnchorAt(obj, byte_offset, stickiness)` /
   `resolveObjectAnchors(obj, anchors, out)` per text (and, incidentally,
   list) object. **This is delta 3 — the D1 hard blocker for live text
   reconcile** (d1-live-reconcile.md §4, §6 test 6). Est. **~200 lines new/
   moved in the shared layer, ~150 lines new ObjectDoc-facing API in
   ObjectDoc.zig, ~12–15 new tests** (mirror `TextDoc.zig:779–796`'s anchor
   tests, one battery per object kind, plus a cross-object isolation test —
   an anchor in object A must not resolve against object B's edits).
4. **Generalize the graph-rebuild half of `compact`; land delta 2 on
   ObjectDoc (whole-doc compaction, one linearization point).** Extract
   `TextDoc.zig:888–917`'s graph-renumbering loop as
   `compactGraph(EventGraph(Op), stable_lv, ...)`; ObjectDoc's `compact`
   materializes each sequence-shaped object's base via step-3's shared
   per-object walker, calls the shared `compactGraph`, and — explicitly —
   does NOT attempt MV-register compaction (map/list-of-scalars history stays
   uncompacted; see §4 risk 5). Est. **~300 lines new in ObjectDoc.zig
   (compact + base materialization per object kind), ~150 lines extracted
   into the shared graph-rebuild helper, ~15 new tests** (whole-doc compact
   + resume-sync-after-compact + anchor-into-compacted-object rejection,
   mirroring `text_tests.zig`'s existing compaction battery).
5. **Port F3 into `ObjectDoc` proper (delta 6, the move op) — additive wire
   content, new mechanism, largest single step.** New `ObjectOp.move`
   variant; the NEW global-Lamport cross-node cycle-break mechanism
   (`structure_sketch.zig:464–488`'s `computeLamport`/`CanonCtx`, genuinely
   not reused from anywhere else in stemma — north-star-plan.md's F3 caveat
   1 and d1-live-reconcile.md §4 both flag this as net-new, not a port of
   ObjectDoc's per-key MV rule); `objects_state.Walker` gains a
   parent-register discipline per structural node, replacing
   `structure_sketch.zig`'s from-scratch `materialize` with the incremental
   prepare/effect version its own FINDINGS section names as owed
   (`structure_sketch.zig:252–256`). Wire format gains a `move`/`create`
   frame — additive, old ObjectDoc bytes remain valid to decode (no `move`
   frames present). Est. **~500–700 lines in objects_state.zig +
   ObjectDoc.zig, ~200 lines wire, port of the ~400-seed property-test
   campaign (`structure_sketch.zig:1095–1192`) adapted to ObjectDoc's real
   API, ~20 new tests** (the hand-written cases from
   `structure_sketch.zig:716–1060` re-targeted at `ObjectDoc`, plus the
   property campaign as one `zig build test` entry). This step can start any
   time after step 2 (it doesn't depend on anchors/compaction) but the plan
   places it last because it is deferred until a structural-editor client
   needs it (north-star-plan.md §5 F3, §6: "deferred until a structural
   editor client").
6. **weft-side: `Document` re-bases on the unified core (W7).** Out of
   `lib/stemma`'s scope but gated on steps 1+3 at minimum (delta 3, per
   north-star-plan.md's named F1 trigger: "when doc-core unification +
   in-node identity anchors land (stemma deltas 1+3), weft's `Document`
   re-bases onto the unified core"). Whether this means swapping
   `Document`'s backing type to `ObjectDoc` with one root text node, or
   keeping `TextDoc`'s facade over the now-shared internals, is a weft-side
   decision this study does not make (see §2.3) — flagged for the
   orchestrator, not sized here (app/weft work, not lib/stemma).

**Where each delta lands, restated:** delta 3 (anchors) → step 3. Delta 2
(compaction) → step 4. Delta 6 (move op) → step 5. The global-Lamport
cycle-break mechanism → inside step 5, as new code (not a slot in the
existing per-register MV rule).

---

## 4. Risks told straight

### 4.1 Landmines — subtly different semantics that unification could silently change

1. **Map-register MV tiebreak vs the future parent-register tiebreak are
   DIFFERENT RULES, and mixing them in one doc is a real hazard.**
   `ObjectDoc.setOrder` picks the map conflict winner as "greatest
   `(agent_name, seq)` among the causally-maximal antichain"
   (`ObjectDoc.zig:471–477`, used by `mapGet`, `ObjectDoc.zig:420–428`).
   `structure_sketch.zig`'s parent-register winner is "the last write in a
   GLOBAL Lamport-canonical order whose application doesn't cycle" — which
   the sketch's own FINDINGS section proves is NOT always a causally-maximal
   antichain member (`structure_sketch.zig:140–182`, pinned by the test at
   `structure_sketch.zig:875–915`: a rejected write can strand an
   already-superseded write as the effective parent, outside the reported
   conflict set entirely). Step 5 introduces a SECOND, semantically
   different conflict-resolution rule into the same document type. Anyone
   assuming "ObjectDoc's conflict story is uniform" (a reasonable assumption
   from the map/list code alone) will be wrong the moment move ops exist.
   Must be documented at the `ObjectDoc.zig` API boundary, not just in the
   design doc.

2. **TextDoc's per-agent delete-position pattern and ObjectDoc's are
   textually identical but this is fragile, not structural.** Both
   `TextDoc.delete` (`TextDoc.zig:322–326`) and `ObjectDoc.textDelete`
   (`ObjectDoc.zig:328–332`) emit N `del` events "at the same position" in a
   loop with the comment "the next scalar slides into place." This is
   correct because both go through the SAME `Sequence.applyDelete`
   discipline (§1.1) — but it means any future divergence in one facade's
   loop (e.g. ObjectDoc deciding to batch multi-scalar deletes differently
   for its own wire-efficiency reasons, mirroring TextDoc's RLE run
   detection) would silently break the "same effective semantics" property
   that today holds only because both call sites happen to be written the
   same way, not because a shared function enforces it. Step 1/2's
   `SeqWalker` extraction actually FIXES this landmine by making it
   structural rather than coincidental — worth calling out as a concrete
   benefit, not just a risk.

3. **Compaction is whole-document in TextDoc; ObjectDoc's future compaction
   must decide per-object vs whole-graph, and the two are NOT equivalent.**
   `TextDoc.compact` requires ONE linearization point for the ENTIRE
   document (`TextDoc.zig:855–877`: `heads.items.len != 1` →
   `error.NotCompactable`). ObjectDoc's graph interleaves ops across many
   objects; a naive port of "one stable_token, compact everything" (step 4's
   plan) is the safe, TESTED shape — but it means compacting ANY one object
   forces a linearization point across the WHOLE tree, including objects
   with no pressure to compact. A finer per-object compaction (only this
   text node's history, other objects untouched) is a materially different
   and harder design this study does NOT recommend attempting inside delta
   2 — flagged so the orchestrator doesn't assume "delta 2 done" implies
   "compact just the object I care about."

4. **`checkHoleConflicts`/partial-checkout has no ObjectDoc analog and isn't
   free.** TextDoc's hole-aware scalar↔byte mapping (`TextDoc.zig:1061–1123`)
   is ~200 lines of position bookkeeping that only exists because
   `openPartial` lets a replica hold unrealized spans. If delta 2 or a later
   step is read as "ObjectDoc gets everything TextDoc has," partial checkout
   is the piece most likely to be silently assumed rather than actually
   built — it is a distinct feature (compaction-dependent but not implied
   BY compaction) and is not costed anywhere in §3's steps. Flagged as
   explicitly OUT of scope for deltas 1–3 as studied here.

5. **MV-register history compaction is an open problem step 4 does not
   solve.** Once ObjectDoc gains delta 2's graph-level compaction (step 4),
   a natural next question is "can I also forget superseded `map_set`
   events, not just prune sequence tombstones?" — the answer is NOT free
   from step 4's mechanism: `TreeVal`/`RegItem` conflict bookkeeping
   (`ObjectDoc.zig:101`, `objects_state.zig:67–90`) needs every historical
   write to a key to correctly compute `mapConflictCount` for writes still
   causally concurrent with unsynced peers — compacting a superseded-but-
   still-referenced write changes what a late-arriving peer's merge sees.
   This is a genuinely separate problem from sequence compaction and should
   not be assumed solved by step 4's graph-rebuild machinery alone.

### 4.2 weft-side coupling surface

Read-only sweep of `app/weft/src`, confirmed against `Document.zig`,
`grants.zig`, `graph.zig`, `sync_core.zig`, `Collab.zig`, `GraphCollab.zig`,
`transcript.zig`, `backing.zig`, and both test files.

**The good news first: the blast radius is small and concentrated by
design.** Only three sites in the whole app import `stemma.TextDoc` directly
— `app/weft/src/core/Document.zig:58` (the wrapper itself, the intended
single coupling point), `app/weft/src/core/grants.zig:122–123` (a type-alias
reach-through, see below), and `app/weft/src/tests.zig:32` (a 5-line
path-dependency smoke test). Everything else — `Editor.zig`, `backing.zig`,
`session/Collab.zig`, `session/PartialDoc.zig`, `command.zig`'s edit paths —
talks only to `Document`. Similarly, `stemma.ObjectDoc` is imported in
exactly one place, `app/weft/src/core/graph.zig:90`; `transcript.zig` (its
only client) talks only to `GraphDoc`.

**And the `version`/`eventsSince`/`serialize` triad is ALREADY proven
doc-agnostic in production weft code** — direct, load-bearing evidence for
Option C's "share the engine, not necessarily the facade" recommendation.
`app/weft/src/core/session/sync_core.zig:52`,
`pub fn SyncCore(comptime Doc: type) type`, requires only that structural
interface (doc comment `sync_core.zig:48–51`; call sites `:88,103,125`) —
`merge` is deliberately excluded per-driver (`sync_core.zig:21–34`, because
`Collab`'s merge path needs `error.Unrealized` recovery `GraphCollab`
doesn't). It is instantiated exactly twice — `SyncCore(Document)` in
`Collab.zig:47` and `SyncCore(GraphDoc)` in `GraphCollab.zig:91` — meaning
`Document` (TextDoc-backed) and `GraphDoc` (ObjectDoc-backed) are *already*
treated polymorphically at the version/sync-framing layer, today, with zero
special-casing.

**Where it gets less clean: both facades leak their backing doc's TYPES,
not just forward its methods.** `Document`'s public API re-exports
`TextDoc.EventAnchor`/`AnchorSide` (`Document.zig:60–62`),
`TextDoc.VersionOrder` (`:542`), `TextDoc.MergeError`/`CompactError`/
`AnchorError` (`:523,545,551,630`), and `TextDoc.BaseChunk`/
`AgentWatermark`/`BaseHole` (`:566–568`) verbatim — every caller of
`Document`'s public API (`grants.zig`, `command.zig`, both test files) is
transitively typed against TextDoc's exact error sets and anchor/chunk/
watermark shapes. `GraphDoc` does the identical thing for ObjectDoc:
`MergeError`/`VersionOrder`/`ObjId`/`Value`/`Kind`/`ValueRef`/`Change`
(`graph.zig:102–111`), consumed directly by `transcript.zig:123–138`. Both
modules state this is deliberate ("so callers of the facade don't reach
past it into `stemma`," `graph.zig:105–106`) — it centralizes the *import*
but not the *type surface*. A unification that changes `EventAnchor`'s
shape (very plausible under step 3's anchor generalization — see below) or
`ObjId`'s shape ripples through every consumer of `Document`/`GraphDoc`
simultaneously, not just through `lib/stemma`.

**Two genuine internals-reach landmines, smaller than the type-leakage
above but sharper:**
1. `self.doc.history.eventCount()` — `Document.zig:580,596,637` — reaches
   past TextDoc's public API into its `history: Graph` field directly (no
   `pub fn eventCount()` exists on `TextDoc` for `Document` to call
   instead). `Document.zig:637` wraps this as its OWN public
   `eventCount()`, but the wrapper's implementation still does the same
   direct-field reach.
2. `ed.doc.doc.history.eventCount()` — `app/weft/src/core/tests.zig:1004,
   1063` — the same reach, done again from app-level test code, bypassing
   even `Document`'s own `eventCount()` wrapper, two struct layers deep
   (`Editor.doc: Document`, `Document.doc: TextDoc`). This is the single
   most brittle site found: it depends on the field names `doc` and
   `history` both staying exactly as they are through any refactor.

**Structural note for §2's anchor-identity question:** `graph.zig`'s module
comment (lines 16–27) already had to solve, independently, the same problem
delta 3 solves for TextDoc — raw `ObjectDoc.ObjId` is doc-local/
non-portable, so `graph.zig` invented `NodeRef` (backed by
`ObjectDoc.exportId`'s `"sto\x01"` wire token, `graph.zig:213`) specifically
so nothing downstream of the facade leaks the non-portable identity. This
is independent, convergent evidence that TextDoc's `EventAnchor`
(agent-name + seq, already portable, `TextDoc.zig:731–737`) is the right
SHAPE for delta 3's generalization — ObjectDoc's own facade already had to
reinvent portable identity once, the hard way, for objects; anchors should
not repeat that mistake and should ship portable (agent name + seq) from
the start, exactly as `EventAnchor` already is.

**Wire bytes: zero risk.** No file under `app/weft/src` references TextDoc's
`"stg\x01/2/3"` or ObjectDoc's `"stj\x01"` magic — grepped, zero hits — and
`TextDoc.zig`'s magic constants are non-`pub` in the first place. Every
place weft moves these bytes (`Document.mergeRemote`/`eventsSince`/
`serialize`, `Document.zig:648–673`; `sync_core.zig:96–120`'s length-prefixed
framing; `Collab.zig:171–183`; `GraphCollab.zig:139–151`) treats them as
fully opaque `[]u8`. Disk persistence (`backing.zig:178,233`) stores plain
UTF-8 file content, never stemma wire bytes, and `Editor.zig:220`'s
`adoptContent` takes raw content too. This confirms §2.4's recommendation
costs nothing on the weft side: the wire format is free to stay unchanged
(or to change later) independent of anything in §3, as long as the
`version`/`eventsSince`/`serialize`/`merge` opaque-`[]u8` contract holds.

**Also worth noting for scope:** `GraphCollab`/`transcript.zig` are not yet
wired into `main.zig` (zero call sites) — ObjectDoc-side coupling is
presently confined to host-side/test infrastructure, which lowers the
practical urgency (though not the design correctness requirement) of
getting `GraphDoc`'s type-leakage right before W5 ships it live.

**Landmine table, for the orchestrator:**

| coupling point | file:line | breaks if... |
|---|---|---|
| `Document.doc: TextDoc` / `Peer.replica: TextDoc` by value | `Document.zig:66,94` | TextDoc's size/copy semantics change, or per-peer-replica shape is replaced by a shared/CoW core |
| `Document`'s API re-exports `TextDoc.{EventAnchor,AnchorSide,VersionOrder,MergeError,CompactError,AnchorError,BaseChunk,AgentWatermark,BaseHole}` verbatim | `Document.zig:60-62,523,542,566-568` | Any of those shapes change under step 3/4 — every caller of `Document`'s public API breaks in lockstep |
| `grants.zig` reaches past `Document` straight to `stemma.TextDoc.EventAnchor`/`AnchorSide` | `grants.zig:122-123` | Same anchor-type risk, doubled (skips even the `Document`-level alias) |
| Direct internal-field access `self.doc.history.eventCount()` | `Document.zig:580,596,637` | `TextDoc.history`'s field name/type changes under any `SeqWalker`/shared-core refactor |
| Same reach, two layers deep, from app test code | `core/tests.zig:1004,1063` | Same, plus depends on `Document`'s field being named `doc` |
| `stemma.TextDoc` used directly, bypassing `Document` | `tests.zig:32` | Low risk — 5-line smoke test |
| `GraphDoc` re-exports `ObjectDoc.{ObjId,Value,Kind,ValueRef,Change,MergeError,VersionOrder}` verbatim | `graph.zig:102-111` | ObjectDoc's identity/value model changes shape — `transcript.zig:123-138` consumes these directly |
| `SyncCore(Doc)` structural interface | `sync_core.zig:52,88,103,125`; instantiated `Collab.zig:47`, `GraphCollab.zig:91` | **Lowest risk** — already doc-agnostic today; a shared core preserving this 3-method shape costs nothing here |
| Wire format bytes | not referenced anywhere in `app/weft/src` | **Zero risk** — confirms §2.4 |
| Disk persistence format | `backing.zig` | **Zero risk** — plain text, never stemma wire bytes |

---

## 5. Size estimates (rollup)

| step | delta landed | lines touched (lib/stemma) | new tests |
|---|---|---|---|
| 1. Extract `SeqWalker` from `TextDoc.Replay` | — (pure refactor) | ~450 | ~5 |
| 2. Rebuild ObjectDoc's sequence walker atop `SeqWalker` | — (pure refactor) | ~150 | 0 |
| 3. Generalize anchors → ObjectDoc | **delta 3** | ~350 | ~12–15 |
| 4. Generalize compaction → ObjectDoc | **delta 2** | ~450 | ~15 |
| 5. Port F3 move op into ObjectDoc | **delta 6** + new global-Lamport mechanism | ~700–900 | ~20 |
| 6. weft `Document` re-base | **W7** | (app/weft, not sized here) | (app/weft) |

Steps 1–4 total **~1400 lines touched, ~32–35 new tests**, all inside
`lib/stemma`, all wire-compatible, each independently gated by
`zig build test` (confirmed green on today's tree). Step 5 is the largest
single unit of work and the only one that changes wire content (additively).

---

## References

- `lib/stemma/src/stemma/collab/TextDoc.zig` — the text doc, its `Replay`
  walker, anchors, compaction, wire v1–v3.
- `lib/stemma/src/stemma/collab/ObjectDoc.zig` — the object doc, its ledgered
  gaps (`:21–25`).
- `lib/stemma/src/stemma/collab/objects_state.zig` — `Walker`, the
  object-tree prepare/effect discipline.
- `lib/stemma/src/stemma/collab/Sequence.zig` — the one shared FugueMax
  engine.
- `lib/stemma/src/stemma/collab/causal.zig` — the shared `EventGraph(Op)`.
- `lib/stemma/src/stemma/collab/core.zig` — shared version-token protocol.
- `lib/stemma/src/stemma/collab/structure_sketch.zig` — F3 validation
  (test-only, not in the public module — `build.zig:29–43`).
- `app/weft/doc/north-star-plan.md` §5 F1/F3, §6 W5/W7 — the mandate.
- `app/weft/doc/d1-live-reconcile.md` §4 — the dependency analysis this
  study extends with function-level citations.

# D1 — live reconcile of a multi-writer projection

Status: DESIGN, REVISION 1 (2026-08-22). Due in-phase at W5 (north-star-plan.md
§6); W6's structured-collab gate is load-bearing on it (§6 W6, §7 item 1). This
is the design the plan flagged as a place the project "could still get stuck":
"region-atomic commit points are a hypothesis, not a design. Fallback: single-
writer-per-projection, declared as such. W6 does not ship 'collab' while quietly
being turn-taking."

Method, matching the plan: checked against the code, not the docs. Every claim
about what the substrate does or doesn't do cites the file. Sections are labeled
HYPOTHESIS / DESIGN / DECIDED. Where the honest conclusion is "this half is
blocked on stemma work," it is stated with the delta named, because that is the
useful output — §7 of the plan asked for exactly that, not a pretend design.

The one-line result up front, so the rest can be read against it:

> **Live reconcile splits cleanly into two halves that the plan conflated as
> one. The text half (edits inside a node's body) is convergent by construction
> the moment stemma delta 3 lands — it needs no commit points at all; the
> commit-point hypothesis is *wrong* for it. The structure half (creating,
> deleting, reparenting, or re-bounding nodes) is `on_save` applied per-region
> at automatic commit points — it reuses the W5-slice-3 algorithm, and it is
> blocked on F3's parent-register landing in `ObjectDoc` proper. W6 ships the
> declared per-region lease (the fallback), which is buildable on today's
> substrate and is honestly convergent; full concurrent live editing is a
> W6/W7-boundary item gated on the two stemma deltas below.**

---

## 0. What the substrate already gives you (ground truth)

Live reconcile is often imagined as "make CRDT merge happen continuously." That
framing hides the fact that **the merge already happens continuously and already
converges** — the open problem is entirely at the projection↔model boundary, not
the model↔model boundary. Precisely what is already true, cited:

- **Object convergence is free and character-granular.** `GraphDoc`
  (`src/core/graph.zig`) wraps `ObjectDoc`
  (`lib/stemma/src/stemma/collab/ObjectDoc.zig`): maps, lists, and text objects
  over one causal history. Each text object "is a real sequence CRDT with the
  same FugueMax semantics as `TextDoc`" (ObjectDoc.zig:3-5). Two principals
  typing into the same node body converge to one deterministic interleaving on
  every replica, per keystroke, with nothing dropped. There is no "live text
  reconcile algorithm" to invent for content inside an existing node — FugueMax
  is it.
- **The wire protocol is doc-agnostic and shipped.** `SyncCore(Doc)`
  (`src/core/session/sync_core.zig`) does frontier tracking, announce-once,
  push-on-move, batch framing, and the admission gate; `GraphCollab`
  (`session/GraphCollab.zig`) already drives a `GraphDoc` over a `Session`
  channel quad. `graph.zig`'s convergence test (`syncOne` +
  `compareVersions == .equal`) and `transcript.zig`'s two-replica tests prove
  it. Live reconcile does not need a new protocol; it needs new *projection
  behavior over the change stream the protocol already delivers*.
- **Merge hands you a typed change stream.** `GraphDoc.merge` returns
  `[]Change` (ObjectDoc.zig:75-84): `map{obj,key}`, `list_ins`, `list_del`, and
  `text{obj, edit}` per text object, where `edit` is byte-space and "shift that
  object's anchors" is the documented contract. A projection can know exactly
  which objects a remote batch touched.
- **Register conflicts are already honest and inspectable.** A map key that two
  principals set concurrently keeps BOTH values as a conflict set;
  `mapGet` returns a deterministic winner (greatest `(agent name, seq)` of the
  setting event, ObjectDoc.zig:417-428) and `mapConflictCount`/`mapConflictAt`
  (:431-440) expose the whole set. `transcript.zig`'s `adopt` (:94-102) already
  *uses* this to refuse a split-brain (`mapConflictCount(entries_key) > 1`
  ⇒ `error.Corrupt`). The mechanism to surface a register conflict loudly
  exists and has a shipped user.
- **The graph↔text identity bridge is shipped.** A projection's `fill`
  re-renders the model into a read-only buffer and claims one subbuffer id-span
  per region carrying the region's portable `NodeRef` token
  (`transcript.zig:233-263`, `node_fact`). `subs.at(doc, offset)` answers "which
  graph node produced the byte under the caret" without position guessing. This
  is the hook every reconcile mode threads edits back through.
- **Admission is per-document and coarse.** `SyncCore.admitBatch`
  (sync_core.zig:141-151) drops a peer's whole batch unless
  `session.access.canEdit()`; `Access` is `{view, edit, own}` per session per
  doc (Session.zig:40-58). There is **no per-region admission today** — the
  whole doc is view or edit. This is the single most important gap the fallback
  lease has to close, and it is the same gap W6's "identity-anchored subtree
  grants at admission" (plan §6 W6) has to close anyway.

The plan's `ReconcileMode` union (plan §2.6; sketched in `graph.zig`'s doc
comment, not yet built) names `on_save` (DESIGNED, editable-projection.md),
`live` (UNDESIGNED — this doc), and `authoritative` (command + latest-wins
feed). `transcript.zig` ships a fourth, `.read_only`, and documents honestly
that none of the three fit a transcript yet (transcript.zig:206-232).

---

## 1. The region-atomic commit-point hypothesis, made concrete

The plan's hypothesis (§2.6): a projection in `live` mode reconciles "when a row
CLOSES: focus leaves, delimiter typed, timeout — not per-keystroke." Made
concrete against the substrate, the hypothesis has to answer three questions —
what a region IS, what closes it, and what is on the wire between closes — and
the honest answers **split the hypothesis in half and reject one half.**

### 1.1 What is a region? — DECIDED: the CRDT object, nothing coarser or finer

A region is **exactly one `ObjId`**: one node's one text object, one list, or one
map. Not a subtree (a subtree is a *set* of regions with structural relationships
between them — §3), not a text-run inside a body (FugueMax already tracks sub-body
identity per character; inventing a coarser text-run unit throws away the
granularity the CRDT paid for). The subbuffer id-span in `fill` already
partitions the buffer into exactly these units — one span per `NodeRef`, one
`NodeRef` per object. So "region" is not a new concept; it is the id-span the
projection already claims.

This matters because it makes the boundary question precise: **an edit is
"in-region" iff its byte range falls entirely within one id-span, and
"cross-region" iff it touches the boundary between two** (or the void beyond the
last one). That distinction — not a timer — is the real fault line.

### 1.2 In-region text edits — DECIDED: per-edit, no commit point, no batching

For an edit wholly inside one text-object region, live mode translates it
**immediately** into a `GraphDoc.textInsert`/`textDelete` on that object
(graph.zig:196-201) and lets FugueMax merge it. There is no commit point,
because there is nothing a commit point would buy: the text CRDT already merges
at character granularity and converges regardless of how the two principals'
keystrokes interleave on the wire. Batching to a "region close" would only *delay*
convergence and *widen* the window in which the two buffers disagree — pure loss.

> **The commit-point hypothesis is therefore WRONG for in-region text.** This is
> a real correction to the plan's §2.6 sketch, not a restatement of it. "A row
> reconciles when it closes" is the right instinct for structure and the wrong
> instinct for content, and the substrate is what tells them apart.

The one thing per-edit translation needs that the substrate does *not* yet
provide is a stable mapping from a buffer byte-offset to a position inside the
node's text object that survives a concurrent remote edit — i.e. **in-node
identity anchors**. See §4; this is the blocker, and it is stemma delta 3.

### 1.3 Cross-region / structural edits — DESIGN: `on_save` per region at commit points

An edit that creates a region (typing a new dired row), deletes one (`dd` a
row), splits one (a newline mid-body that the projection interprets as "two
nodes now"), or reparents one is a **structural** change. Here the commit-point
hypothesis is correct and necessary, because an intermediate buffer state is not
yet a valid graph state: half a typed row is not yet a node; a newline you are
about to delete should not mint and then trash a node on the wire.

The design is to reuse the `on_save` reconcile algorithm (editable-projection.md
"Identity + reconcile"; being formalized now as W5 slice 3) **scoped to one
region and triggered automatically instead of at `:w`**:

- A **commit point** for a region's structure is, in priority order: (1) a
  **syntactic boundary** the projection declares (a newline at a dired row
  boundary, a fold close, a delimiter for a structural editor) — the honest
  primary, because it is the point at which the projection *knows* the structure
  is well-formed; (2) **focus leaving the region**; (3) an **idle timeout** as
  the backstop for "walked away mid-edit." Explicit save is always also a commit
  point.
- Between commit points, the structural delta is **local-only** — not on the
  wire. The buffer shows the in-progress structure; peers do not see a node
  flicker into and out of existence.
- At a commit point, the region runs the initial→current id-diff
  (editable-projection.md): same id + changed name ⇒ rename (a `mapSet`); id
  gone ⇒ delete; new line with no id ⇒ create; new parent ⇒ move. The diff is
  by id, so the editing path is irrelevant — exactly the `on_save` property,
  just fired per region rather than per buffer.

> **Consequence, stated plainly: live structural reconcile is not a new
> algorithm. It is `on_save` with automatic, region-scoped commit points.** This
> is a good outcome — it means the structure half of D1 composes with W5 slice 3
> for free and inherits its correctness. It also means the structure half
> inherits `on_save`'s dependency: identity-preserving move is a parent-register
> write (F3), and F3 is not in `ObjectDoc` yet (§4).

### 1.4 What is on the wire between commit points — DECIDED

- In-region text edits: **on the wire immediately** (§1.2).
- Structural deltas: **local until their region's commit point**, then a batch of
  graph ops (`mapSet`/`seqInsert`/`seqDelete`/move) via the ordinary
  `push`/`pushOnMove` path (GraphCollab.zig:166-174). The wire protocol does not
  change; only *when* the projection calls the mutators does.

This is the whole of the "region-atomic commit point" idea, made concrete and
correctly narrowed: it governs structure, not content.

---

## 2. `live` vs `on_save` vs `authoritative` — operational difference + decision table

### 2.1 The operational difference — DESIGN

| | what an edit becomes | when it hits the model | when it hits the wire | intermediate states |
|---|---|---|---|---|
| **`on_save`** | buffered as free text; id-diffed at `:w` | at explicit save, whole buffer | at save | never reconciled; the buffer is scratch until save |
| **`live` (text)** | a `textInsert`/`textDelete` on the region's object | per edit, immediately | per edit | *are* the model; FugueMax merges them |
| **`live` (structure)** | a local structural delta, then an id-diff | at the region's commit point | at commit point | local-only; well-formed by construction at commit |
| **`authoritative`** | an `Intent` → a COMMAND to the authority | never merged; state returns as a latest-wins feed | command out, feed in | there is no merge — CRDT would be wrong (plan §5 F2) |

The load-bearing distinctions:

- `on_save` reconciles against an **external authority** (the filesystem) at a
  human-chosen point. `live` has **no external authority** — the graph doc IS
  the truth — so it reconciles continuously (text) or at automatic region
  commits (structure). `transcript.zig:210-216` states exactly this for why a
  transcript can't use `on_save`.
- `authoritative` is not a degraded `live`; it is the *correct* design for a
  single-truth or honestly-last-wins source (the user's media-player insight,
  plan §5 F2). A seek is a command; the position is a latest-wins feed; there is
  nothing to merge and merging it would be a bug. This mode reuses the existing
  feed + action shapes (Collab's presence/diagnostics feeds are the template)
  and needs nothing from D1.

### 2.2 Which tool class gets which mode — DECIDED (per F2, tool by tool)

| tool class | mode | reasoning |
|---|---|---|
| code / prose buffer (post-W7 degenerate one-node graph doc) | **live (text)** | one node, no structure; FugueMax convergence is the whole story. The flagship function-scoped-grant scenario (plan §6 W7) lives here. |
| agent transcript | **read_only** now → **live (text)** later (but see the seam note below: W5-3 ships `on_save` machinery on it as the gate's mechanism proof) | append-mostly; editing a past turn's body is the future live case (transcript.zig:216-232). Genuinely multi-writer only if two humans co-edit one turn — rare, and handled by §1.2 when delta 3 lands. |
| dired / file manager | **on_save** | fs-authority; a half-typed rename must not `mv`. Commit point = the human's save, deliberately. Live would be actively dangerous. |
| magit staging | **on_save** | git index is the authority; `add -p`/`reset` at save. Same as dired. |
| config editor | **on_save** | validate + apply atomically at commit; a half-edited config must never take effect. |
| media-player controls, system monitor, log tail, debugger run-state | **authoritative** | single truth / last-wins; command + feed; merging would be wrong (plan §5 F2). |
| shared structural editor (two humans on one outline, different projections) | **live (text + structure)** | THE target multi-writer case; needs the full stemma stack (§4). Ships on the **fallback lease** at W6 (§5) until then. |

The rule the table encodes: **fs-authority and single-truth tools are never
`live`.** `live` is for models whose truth is the graph itself and which have
more than one writer. That set is small and is exactly the set D1 is for.

One seam, told straight: the W5 gate requires the transcript "edited,
reconciled by id" NOW, before delta 3. W5 slice 3 meets it with `on_save`
*machinery* (explicit commit point, id-diff reconcile) applied to the
transcript, even though the transcript has no external authority and its
resting mode remains this table's answer. That is the gate proving the
reconcile-by-id mechanism the structure half reuses (§1.3) — scaffolding for
the algorithm, not a revision of this table. When `live (text)` becomes real
(delta 3), the transcript moves to it and the explicit commit point dissolves.

---

## 3. Cross-projection conflict — every outcome convergent-by-construction or loudly surfaced

The hard scenario, stated by the task: principal A edits a node via the text
projection while principal B moves/edits it via a structural projection. The
requirement is no silent third result — every outcome is either convergent by
construction or loudly surfaced by the projection. Enumerated exhaustively over
what the substrate can produce:

**Case 1 — disjoint objects (A on N₁.body, B on N₂.body).** Converge trivially;
different objects, no interaction. Projection shows both merged edits. *Silent
and correct* — this is the common case and needs no surfacing.

**Case 2 — same text object, concurrent edits (A and B both type into N.body).**
FugueMax interleaves deterministically; both replicas reach the identical result;
neither principal's bytes are dropped (ObjectDoc.zig:3-5). *Convergent by
construction.* The projection renders the merged text as-is. This is the ONE
place interleaving happens, and it is CRDT-correct — clause (a) of the task
("neither in-flight edit clobbered or interleaved into nonsense") is satisfied by
FugueMax, and the falsifiable test in §6 (test 2) pins it.

**Case 3 — A edits N.body (text proj) while B deletes N (structural proj).**
Convergent in the *graph*: A's text edits and B's delete are causally concurrent;
the graph retains both (the text object still exists with A's edits; B's
structural op removes N from its parent / moves it to trash). But this is a
**silent third result at the projection layer** unless handled: B's structural
view no longer shows N; A's text projection would, naively, show A's edits as if
they were live. The DESIGN: after every merge, a live projection, for each region
it rendered, re-`resolve`s the region's `NodeRef` and checks it is still
**reachable from the current root** (not deleted, not under trash). A region whose
node is no longer reachable is **surfaced as a conflict** — a decoration/marker
on the region reading "deleted by B while you were editing" — never silently
shown as live and never silently dropped. *Loudly surfaced.* (This is the check
`transcript.adopt` does structurally for the root list, generalized to every
rendered region and run on every merge rather than once at open.)

**Case 4 — concurrent scalar writes to the same key (A and B both rename N via
`mapSet("name", …)` through two projections).** MV register conflict:
`mapConflictCount("name") == 2`, `mapGet` picks a deterministic winner
(ObjectDoc.zig:417-434). A live projection MUST read `mapConflictCount` for every
key it renders and, when `> 1`, **surface all conflicting values loudly** rather
than silently showing only the winner. *Loudly surfaced* — same mechanism
`transcript.adopt` already uses, promoted from a one-shot open check to a
per-fill invariant.

**Case 5 — concurrent moves of the same node (A moves N under P; B moves N under
Q).** Parent-register MV conflict; deterministic winner via F3's global order
(plan §5 F3 caveat 1). Convergent. The projection surfaces if
`conflictCount > 1`, same as case 4. *Convergent + surfaced.* **Blocked until F3
parent-registers exist in `ObjectDoc`** (§4) — today `GraphDoc` has no move op at
all (graph.zig:44-59), so this case cannot yet arise, and structural-move live
reconcile is not yet expressible.

**Case 6 — the joint cycle (A moves N under M; B moves M under N).** F3's
global-Lamport cycle-break picks a survivor that "when every causally-dominant
write would cycle … is an earlier superseded write (in the limit, the create) —
deterministic and convergent, but outside the conflict set" (plan §5 F3 caveat
1). Convergent, but the result is *surprising*: neither principal's move
necessarily "won." The projection MUST surface that a cycle was broken and the
node landed at a non-obvious parent — otherwise it is a silent third result even
though it is convergent. *Convergent + must-surface.* Also blocked on F3-in-
`ObjectDoc` plus the new global-order mechanism (§4).

The unifying rule, and the projection contract D1 imposes:

> **A live projection's `fill` runs three checks on every render after a merge:
> (i) every rendered region's `NodeRef` still resolves and is reachable (case 3);
> (ii) every rendered register key has `mapConflictCount ≤ 1` or is surfaced
> (cases 4, 5); (iii) any cycle-break survivor is surfaced (case 6). Text
> interleaving (case 2) is the only silent outcome, and it is correct by
> FugueMax.** No fourth outcome exists on this substrate, so "no silent third
> result" is enforceable by construction rather than by review.

Cases 1 and 2 are shippable on today's substrate. Cases 4 is shippable today
(the conflict-set API exists). Case 3 needs a reachability/trash predicate on the
facade (small — §4). Cases 5 and 6 need F3-in-`ObjectDoc` (§4).

---

## 4. What live mode needs from stemma that `ObjectDoc` doesn't have today

Specific, cited against `ObjectDoc.zig`'s own ledger (:21-25) and the F3
validation caveats (plan §5). These feed the stemma deltas-1/3 unification clock
(plan §2.6, F1).

**REQUIRED — delta 3: in-node identity anchors inside `ObjectDoc` text objects.**
This is the hard blocker for the text half. `TextDoc` has `anchorAt` /
`resolveAnchors` / `EventAnchor` (TextDoc.zig:729-796): a position keyed to a
character's insertion event, stable under concurrent edits, collapsing to the
deletion point when its character dies, `error.Compacted` when compacted away.
`ObjectDoc` text objects have **none of this** — the header ledgers "identity
anchors inside ObjectDoc text objects" as not-yet (ObjectDoc.zig:22). Without
them, a live projection's subbuffer id-span identifies *which* node produced a
byte but not a *stable position within* that node's body: a caret, a selection,
or a W6 grant endpoint inside a node body drifts (or lands wrong) the instant a
peer inserts earlier in the same body. `fill` can rebase whole-region spans from
the `Change.text{obj, edit}` stream, but anything sub-region (the very thing live
in-node editing is about) needs per-object anchors. **Until delta 3, live
in-node text reconcile is not real** — which is why the fallback lease (§5), by
guaranteeing one writer per region, sidesteps it: no concurrent in-node edits ⇒
no sub-region anchor drift to survive.

**REQUIRED for structure — F3's parent-register + trash promoted into `ObjectDoc`
proper (delta 6, the move op).** Today F3 lives only in the *test-only* sketch
`lib/stemma/.../collab/structure_sketch.zig` — "additive, NOT part of the public
stemma module … unreachable from root.zig" (its header). `GraphDoc` deliberately
exposes NO move/reparent and says so (graph.zig:44-59): `ObjectDoc.listInsert`/
`mapSet` "accept only FRESH `Value`s, never an existing `ObjId`." So cases 5 and 6
of §3, and any live *structural* editor, cannot exist until the parent-register
mechanism is production in `ObjectDoc`. The structure half of live reconcile is
gated on this.

**REQUIRED for structure — the global-Lamport cross-node cycle-break (a NEW
mechanism, not `ObjectDoc`'s per-register MV rule).** Plan §5 F3 caveat 1:
resolving a tree of parent-registers needs "a single replica-portable GLOBAL
total order over all writes (Lamport per event, ties by agent-name then seq)
replayed once with per-write cycle rejection — not the per-register MV rule
ObjectDoc reuses for maps; budget it as new." `ObjectDoc` today resolves each map
key independently (mapGet, ObjectDoc.zig:417-428) and *cannot see a cross-node
cycle*. Live structural reconcile inherits this as net-new stemma work.

**SMALL — a reachability / trash predicate on the facade.** Case 3 needs "is this
`ObjId` still reachable from root (not deleted/trashed)?" `GraphDoc` can navigate
from `root()` but exposes no direct predicate. This is a small facade addition
(a walk, or a bit maintained during merge), not a stemma-core change — buildable
now, needed for case-3 surfacing even before F3.

**ALREADY SUFFICIENT (no stemma work):** char-level text convergence
(FugueMax); the MV register conflict set (`mapConflictCount`/`mapConflictAt`,
sufficient for cases 4/5-surfacing); the `merge` `[]Change` stream with per-object
`text` edits (enough to rebase whole-region spans and know which objects moved);
portable `NodeRef` (`exportId`/`importId`); the `SyncCore` frontier protocol and
`GraphCollab` driver.

**DEFERRED but must design-for:** `ObjectDoc` compaction + anchor-collapse-trap
(ledgered not-yet, ObjectDoc.zig:22-24) — W6's identity-anchored grant endpoints
inside node bodies inherit `TextDoc`'s trap-on-collapse semantics
(plan §2.4) once anchors exist; fractional-key rebalancing (plan §5 F3 caveat 2:
same-locus insertion grows keys ~N/8 bytes, needs rebalance at compaction) —
live editing makes rapid same-locus reordering *more* likely than batch editing,
so this pressure is real for a live structural editor specifically.

**Dependency summary:**

- Live **text** half: blocked on **delta 3** (in-node anchors). Everything else
  it needs exists.
- Live **structure** half: blocked on **F3-in-`ObjectDoc`** (delta 6 move) + the
  **new global-Lamport cycle-break** + the small reachability predicate.
- Neither blocks the **fallback lease** (§5), which is buildable today.

---

## 5. The fallback — single-writer-per-projection, fully designed

DECIDED (plan §5 F2 / C5†): if full live disappoints, ship single-writer-per-
projection, *declared as such* — not turn-taking under a collab banner. Designed:

### 5.1 It is single-writer-per-REGION, not per-doc

Per-doc single-writer is just turn-taking on the whole model — exactly what the
plan forbids shipping as "collab." The fallback is **per-region**: within one
live model, edit-ship is a lease held on a region (a node or subtree). Multiple
principals write concurrently to *different* regions of one model — that is
genuine collaboration; the CRDT handles the cross-region concurrency exactly as
in §3 cases 1/4. What the lease removes is concurrency *within* a single region —
and removing that is precisely what makes the text half safe without delta 3
(no two writers in one body ⇒ no sub-region anchor drift to survive) and the
structure half safe without full F3 conflict-surfacing (no two concurrent
structural writers on one region ⇒ cases 5/6 cannot arise).

### 5.2 Acquire / release / display — reusing shipped mechanisms

- **Acquire** on focus-enter of a region: the projection requests an edit lease
  on the region's `NodeRef`. Granted iff no other principal holds it.
- **Release** on focus-leave, idle timeout, or explicit yield. Leases are
  soft-state, re-announced like presence, and reaped on disconnect (a dead
  session's leases die — same lifetime discipline as the plan's scope-bound
  grants, §2.4).
- **Admission** enforces it: extend `SyncCore.admitBatch`'s whole-doc
  `session.access.canEdit()` gate (sync_core.zig:148) to a **per-region**
  check — a batch whose ops target a region the sender does not hold the lease
  for is **refused**, and the refusal is loud (a trap/echo to the sender, never
  the current silent no-op — consistent with the plan's trap-on-deny, §2.4). This
  is the same per-region admission W6 needs for identity-anchored subtree grants;
  the lease is that machinery used for mutual exclusion instead of authority, so
  it is not throwaway work.
- **Display** — this is what makes it DECLARED, not silent. A held region renders
  as locked-by-Bob using the **presence layer that already ships**: `Collab`
  publishes per-peer colored spans with an identity hue (Collab.zig:377-429,
  `packPresenceKind`). A lease is a presence span with a "locked" flag; every
  principal SEES which regions are held and by whom, in the other principal's
  color. Your own keystroke into a held region is refused with a visible message,
  not swallowed.

### 5.3 Why declared beats silent turn-taking

Silent turn-taking is last-write-wins with invisible ownership: principals clobber
each other with no signal, and "convergence" hides a lost edit. The declared lease
makes ownership visible (presence color), makes the boundary of your authority
visible (the region you hold), and makes a violation loud (refused keystroke).
Convergence becomes *trivial* — at most one writer per region at a time, so within
a region there is nothing to reconcile; across regions the CRDT converges as
always. It is honestly collaborative (concurrent multi-region writers) and honest
about its limit (one writer per region), and the UI never hides who owns what.
That is the plan's requirement met literally: it is collab, and it says exactly
what kind.

### 5.4 Ship-W6-on-fallback vs block-on-full-live — the criteria

**Ship W6 on the per-region lease IF** delta 3 has not landed, OR the
cross-projection conflict-surfacing contract (§3 cases 3/4/5/6) is not proven by
the §6 tests. The lease is buildable on today's substrate (per-region admission =
W6's subtree-grant machinery; display = shipped presence) and is honestly
convergent by mutual exclusion. This is the expected W6 outcome.

**Block on full concurrent live (no lease, true per-region concurrency) UNTIL**
delta 3 lands AND §6 tests 2/3/4 pass — i.e. until the substrate can survive
concurrent in-region edits (anchors) and the projection provably surfaces every
non-text conflict loudly.

**The invariant either way:** W6 ships the lease *labeled as a lease*, visible in
the UI and stated in the docs — never "collab" while quietly turn-taking (plan §7
item 1). Full concurrent live lands with **W7**, when the substrate unifies and
in-node anchors exist — which is exactly when the flagship (a function-level grant
on an ordinary code buffer surviving a peer's concurrent refactor, plan §6 W7)
*requires* in-node anchors anyway. The two needs are the same need, so aligning
full-live with W7 is not a slip; it is the correct sequencing.

---

## 6. Falsifiable evaluation — "works" vs "demos well"

The discriminator: a system that *demos well* converges on happy paths and
silently swallows conflict cases; a system that *works* makes every non-text
conflict loud. The tests below assert the LOUD paths, and are runnable against
the existing harness patterns — socketpair `Session`s + `GraphCollab`, and
`fill` output checks, exactly as `transcript.zig`'s tests and `graph.zig`'s
`syncOne`/`compareVersions == .equal` already do.

**Test 1 — convergence under concurrent disjoint edits (the baseline, clause b).**
Two `GraphDoc`s over a `Session` pair; A edits N₁.body, B edits N₂.body,
interleaved; merge both ways; assert `compareVersions == .equal` AND identical
`fill` output on both replicas. Extends the shipped `transcript.zig` convergence
test to bidirectional. *Passes today.*

**Test 2 — interleaving honesty (clause a — the "not nonsense" leg).** A and B
concurrently insert into the SAME text object at the same offset; merge; assert
the result is one deterministic FugueMax interleaving, EQUAL on both replicas,
and that **neither principal's bytes are dropped** (both substrings present).
Falsifies "clobbered or interleaved into nonsense." *Passes today for content;
becomes the delta-3 gate once carets/anchors are asserted stable (test 6).*

**Test 3 — cross-projection delete surfacing (THE discriminator, clause c).** A
edits N.body via the text projection; B deletes/moves N via the structural
projection; merge; assert (i) frontiers converge, AND (ii) `fill` on the text
projection **surfaces the region as conflicted** ("deleted while editing") — the
`NodeRef` no longer resolves-reachable. The load-bearing assertion is (ii): a
demo converges and shows a clean buffer; a working system shows the region LOUD.
If `fill` yields a clean merged buffer with no conflict marker, **the test
fails.** This is the single test that separates "works" from "demos."

**Test 4 — register-conflict surfacing.** A and B concurrently `mapSet` the same
key via two projections; merge; assert the projection detects
`mapConflictCount == 2` and surfaces both values — reusing `transcript.adopt`'s
split-brain pattern (transcript.zig:100) as a per-fill invariant. A demo shows
`mapGet`'s winner and looks fine; the test asserts the conflict is caught.

**Test 5 — lease exclusion (the fallback, falsifies silent turn-taking).** A holds
a region lease; B's edit op into that region is refused at admission (per-region
extension of `admitBatch`); assert B's op is NOT merged, B's projection renders
the region locked-by-A (a presence span), and the refusal is observable to B (a
trap/echo), not a silent drop. Falsifies "quietly turn-taking."

**Test 6 — in-node anchor stability (the delta-3 gate).** Once delta 3 exists:
create an anchor at character K in N.body; concurrently, another replica inserts
before K; merge; resolve the anchor; assert it still names the same CHARACTER
(not the same byte offset). Mirrors `TextDoc`'s existing anchor tests
(TextDoc.zig:779-796). **Until this passes, live in-node text reconcile is not
real and W6 runs on the lease** — this test is the objective gate on that
decision.

The set is complete against §3: tests 1–2 cover the convergent-silent cases;
tests 3–4 cover the must-surface cases buildable today; test 5 covers the
fallback; test 6 gates the delta-3 half. Tests 3, 4, 5 are the ones a
demo-quality implementation fails.

---

## 7. Recommendation and the honest frontier

**Recommendation for W6: ship the declared per-region lease.** It is buildable on
today's substrate (per-region admission is W6's subtree-grant work regardless;
display is the shipped presence layer), it is honestly convergent (mutual
exclusion within a region, CRDT across regions), it surfaces ownership loudly, and
it satisfies the plan's rule that W6 not ship turn-taking under a collab banner —
because it declares exactly what it is. Full concurrent live editing is a
**W6/W7-boundary item**, and the boundary is not arbitrary: it is where in-node
identity anchors (delta 3) exist, and delta 3 is required by the W7 flagship
(function-scoped grant on a code buffer) independently. Aligning full-live with W7
is correct sequencing, not a deferral of convenience.

**What is HYPOTHESIS vs DESIGN vs DECIDED, restated for the record:**

- DECIDED: region = one `ObjId` (§1.1); in-region text is per-edit with no commit
  point (§1.2, a correction to the plan's sketch); the mode-per-tool table
  (§2.2, per F2); the fallback is per-region not per-doc, declared via presence,
  enforced via per-region admission (§5); the ship-the-lease recommendation (§7).
- DESIGN: live structure = `on_save` at automatic region commit points (§1.3);
  the three-check projection contract that makes "no silent third result"
  enforceable (§3); the six evaluation tests (§6).
- HYPOTHESIS surviving into design: syntactic-boundary-as-primary-commit-point
  (§1.3) — the *right* commit trigger is asserted, not yet measured against a
  real structural editor; the idle-timeout backstop's duration is unspecified.
- HYPOTHESIS rejected: "a row reconciles when it closes" as a *universal* live
  rule — false for content, true only for structure (§1.2).

**The stemma frontier, named (feeds the delta-1/3 unification clock):**

1. **delta 3 — in-node identity anchors in `ObjectDoc` text objects.** Hard
   blocker for the live text half. `TextDoc` has them; `ObjectDoc` doesn't
   (ObjectDoc.zig:22).
2. **F3 parent-register + trash into `ObjectDoc` proper (delta 6 move op).** Hard
   blocker for the live structure half and for §3 cases 5/6. Today F3 is a
   test-only sketch; `GraphDoc` exposes no move by design.
3. **the global-Lamport cross-node cycle-break — net-new stemma mechanism**
   (plan §5 F3 caveat 1), not `ObjectDoc`'s per-register MV rule.
4. small facade addition: a reachability/trash predicate (§3 case 3), buildable
   now.
5. design-for-later: `ObjectDoc` compaction + anchor-collapse-trap; fractional-
   key rebalancing under same-locus insertion (plan §5 F3 caveat 2), which live
   editing stresses harder than batch editing.

The blunt version: **D1's text half is a theorem waiting on delta 3; its
structure half is `on_save`-per-region waiting on F3-in-`ObjectDoc`; W6 ships the
lease.** That is a satisfying design — not because full live is done, but because
it correctly locates the hard part (two named stemma deltas, both already on the
unification clock), gives W6 an honest, convergent, loudly-declared thing to ship
in the meantime, and provides tests that catch a demo pretending to be the real
thing.

See north-star-plan.md (§2.6 modes, §5 F2/F3, §6 W5/W6/W7, §7), architecture.md
(projections of a shared graph), editable-projection.md (the `on_save` algorithm
this reuses), `src/core/graph.zig` + `src/core/transcript.zig` (the shipped
projection + identity bridge), `src/core/session/sync_core.zig` +
`GraphCollab.zig` (the admission point the lease extends),
`lib/stemma/.../ObjectDoc.zig` (the substrate and its ledgered gaps),
`lib/stemma/.../structure_sketch.zig` (F3, validated, not yet in `ObjectDoc`).

# Substrate architecture

Status: design, 2026-08-26. Companion to `contextual-workspace-architecture.md`
(§1.1 delegates the substrate layer here). This document re-homes the still-
binding decisions from the retired planning docs (d1-live-reconcile,
d3-refusal-recovery, w7-rebase, sessions-design, and the extensibility fix
list) as normative design; `cwa-prior-docs-audit.md` is the historical map of
where each came from, and `stemma-unification.md` remains the stemma-internal
reference. Where a decision was superseded by the workspace architecture, it
is not repeated here; everything below is current.

The substrate is: stemma's document cores (TextDoc/ObjectDoc over one shared
engine), position identity, backings and persistence, replication and
admission, region leases, sub-document authority, and the locus model. The
workspace layer above consumes these through protocols; nothing here knows
about buffers, presentations, or keys.

## 1. Position identity

The primitive is the **portable position anchor**: a stemma event identity
(agent name, sequence, side) that rebases through concurrent edits or
resolves to `null` — never to a silently shifted position. There is no third
result, and no bare offset crosses a public boundary without the version it
was computed against. Anchors are portable by construction (presence already
ships them on the wire); they are the standard locator payload for positions
in the workspace layer's Designations, and the anchoring mechanism for
embedded-region extents (architecture §11.8).

Object identity is the graph node (`ObjId`, exported as a portable NodeRef
token). What a node buys over an anchor *pair* is exactly three things:
survival under move (a cut-and-repaste mints new insertion identity, so a
pair collapses-and-traps while a moved node keeps its id), robustness under
boundary rewrites (editing a span's first and last lines can accidentally
collapse a pair; a node grant collapses only when the node is unreachable),
and exact subtree containment. For a contiguous, edited-but-not-moved region
the two are observably identical — which is why anchor-pair grants are a
legitimate degenerate case, not a wrong one.

## 2. Documents, backings, and persistence

**Typed backings.** A document's backing is its authority, one of:
`file | shell-remote file | tool | none (scratch)`. `save` writes the
backing; `save-as` re-points it. A tool backing regenerates content by being
a plugin peer — refresh merges like a concurrent editor, with no special
refresh machinery.

**The backing file is a peer.** External writes are detected by a
capability-detected content hash (sha256 → cksum → mtime+size, in declining
fidelity), diffed against the backing peer's replica, and committed *as that
peer's ops* — unsaved local work and the external write coexist, and external
edits never enter local undo. **Save is a guarded test-and-set, never a blind
write**: upload to a temp target, hash the destination, move iff unchanged,
otherwise STALE → merge → retry. No lost updates; bounded retry. (This is the
mechanism behind the architecture's §12 guarded-persistence rule and §18
gate.) Recorded honest limits: diff-import is positional heuristics, and the
mtime+size fallback widens the race window.

**Divergent checkout.** One history root per shared document. A joiner whose
local file diverges from a shared root either adopts the root and imports its
local difference *as its own ops*, or declines into a private document.
Unrelated histories are never merged, and content equality is never used to
guess identity.

**Bulk load.** `openFromContent` treats the content as the compacted base —
zero events, content-hash base heads (identical bytes share a history root).
Opening a 4 MB file is a bulk load, not four million events.

**Partial checkout.** A replica may hold unrealized spans (holes) over a
compacted base: realize from the viewport, converge by bounce-realize,
`--partial` open. Partial checkout is document-level windowing and is
distinct from presentation-level windowing (architecture §11.6); both exist.

**The W7 decision.** `Document` re-bases onto the one graph core — ObjectDoc
with a single root text node (option i); keeping the TextDoc facade forever
was rejected (it cannot host node identity, and it freezes two op types, two
facades, and two wire formats). W7 is split: **W7a** (backing swap, gate =
drop-in parity) and **W7b** (the node layer, gate = the function-scoped
grant); a backing swap must never be presented as the flagship. Parity ledger
before W7a is honest: ObjectDoc still owes `eventsBetween`,
`openFromContent`, `materializeAt`, the partial-checkout family, and the RLE
wire — a naive swap regresses four shipped features. The pre-GA wire flag-day
was ratified with the reopening condition "a mixed-version fleet exists";
that condition is now the operating assumption of collaboration
(architecture §13.4), so version negotiation supersedes the flag-day on its
own terms.

## 3. Reconcile

The workspace layer names three reconcile modes (architecture §8:
`on_save | live | authoritative`); this section owns the mechanics of `live`
and the boundary between them.

**Regions.** A region is exactly one graph node (`ObjId`); the id-span
partition of a projection defines them. An edit is *in-region* iff its byte
range falls entirely within one id-span; *cross-region* iff it touches a
boundary. That distinction — not a timer — is the fault line.

**In-region text commits immediately.** In-region edits translate directly to
`textInsert`/`textDelete`; batching them to a commit point only delays
convergence and widens disagreement — pure loss. Structure is the opposite:
**cross-region/structural deltas commit at region-scoped commit points**, in
priority order (1) a syntactic boundary the projection declares — the honest
primary, the point where the projection knows the structure is well-formed;
(2) focus leaving the region; (3) an idle backstop. Between commit points the
structural delta is local-only — peers never see a node flicker into and out
of existence.

**The three-check projection contract.** On every render after a merge, a
live projection checks: (i) every rendered region's node still resolves *and
is reachable* — a node a peer deleted while you were editing is surfaced as a
conflict, never silently shown live and never silently dropped; (ii) every
rendered register key has at most one causally-maximal value, or *all*
conflicting values are surfaced; (iii) any move whose winner was decided by
cycle-break is surfaced (convergent, but neither principal's move necessarily
won). Text interleaving is the only silent outcome, and it is correct by
FugueMax. No fourth outcome exists on this substrate, so "no silent third
result" is enforceable by construction rather than by review.

## 4. Region leases

The fallback under contention is single-writer **per region**, never per
document (per-document is turn-taking, which is not collaboration). The lease
is soft state:

- acquire on focus-enter; release on focus-leave, idle, or yield; reaped on
  disconnect; re-announced on reconnect like presence;
- **admission enforces it**: a batch targeting an unheld region is refused
  *loudly* — a visible message, never a silent no-op;
- **display declares it**: held regions render locked-by-holder in the
  holder's presence hue, and a refused keystroke gets a visible message;
- concurrent acquisition converges by deterministic tiebreak (byte-wise lower
  principal name), identically on every replica regardless of arrival order —
  this is not a distributed lock service and linearizable acquisition order
  is not promised;
- a lease refusal is **deferred-until-release**: the op re-rides and lands
  when the lease releases, with the sender carrying visible transient local
  divergence meanwhile.

Leases are mutual exclusion, not authority. Authority refusal has no release,
which is why it gets the opposite treatment (§5).

## 5. Sub-document authority and refusal

**Grant shapes.** Sub-document grants scope to a designation: an anchor-pair
region (`DocRegion`) or a graph subtree (`GraphSubtree`), with
**collapse-and-trap** lifetime — a scope that can no longer be resolved traps
closed; it never silently widens or drifts. This is the substrate behind the
architecture's §13.5 designation-scoped grants and the "agent may edit only
this function" flagship.

**The poison mode (proven, not conjectured).** For replicated history, an
authority refusal is permanent by construction: the refuser rejects before
merge, so its announced frontier never advances past the refused op, and
`eventsSince` re-offers it in every subsequent batch; straddling batches are
refused whole, taking later legitimate edits with them. A refused replicated
op is poison, not a clean failure.

**Prevention is primary.** The grant is announced to its grantee over the
existing grant frame; the grantee records the announced scope as
display-and-prevention state — never authority; the owner still enforces, and
an announcement can never widen. The edit path preflights against the
announced scope *before committing a local op*: an out-of-grant keystroke is
refused locally, visibly, and **no out-of-grant event is ever minted** — the
poison class becomes unreachable. Root cause, named: the sub-document grant
was the one asymmetric-knowledge authority in the system; restoring symmetry
is the structural fix.

**Recovery is re-bootstrap.** An already-poisoned grantee discards its
replica, re-attaches, pulls the clean history through the ordinary frontier
exchange, and replays its still-wanted in-grant edits as new local events.
This is safe because the refused op only ever existed on the grantee's own
replica (refusal happens pre-merge; star topology means no third replica saw
it) — abandoning it un-writes no shared event.

**Two designs are dead. Do not rebuild them.**
1. *Revert-in-the-same-batch does not recover*: touched-region reporting sees
   every applied change regardless of net content, so insert-then-delete does
   not coalesce — revert re-poisons.
2. *Per-op / op-subset admission is structurally impossible*: batches merge
   only per-agent-contiguous; a later legitimate op depends on the earlier
   refused op through the run backbone even when they touch disjoint regions,
   and the event stream cannot excise a middle op.

Both are guarded by trace-lock tests that fail if substrate drift ever makes
them look possible again. Ranked shipping rule: recovery may ship alone;
**prevention without recovery is not acceptable to ship** — recovery is the
backstop the no-silent-third-result rule demands for already-stuck replicas
and for buggy, older, or malicious clients.

## 6. Peers, attribution, and selective inversion

Every mutator is a peer. Plugins and agents author as named sub-peers
(`spawnPeer` / act-as-self, never as the user), grade-capped by their
manifest; attribution is per-peer in the history, which is what makes
**selective undo** expressible — inverting one principal's edits (a tool's
regeneration, an agent's rejected change) without touching the user's. The
enforcement points for sub-document scopes are the same admission and apply
paths; applied action results are additionally clamped to their fired extent
(architecture §12) at this layer.

## 7. Locus

A resource handle carries its locus; a bare path never silently means the
local filesystem. Tiers: `here | peer | shell`. The rules:

- R1 — a path is meaningless without its locus.
- R2 — the peer fingerprint is identity; the address is a hint (rebind
  re-points without changing the locus value or anything built on it).
- R4 — network dials *from the locus's vantage*: the locus is the tunnel.
- R5 — remote degrades exactly like a dead provider
  (`connecting → connected → degraded → offline`), surfaced in the status
  line; nothing remote can register as instant.

URI grammar: `weft://<authority>/<kind>/<ref>`, authority ∈
`here | <fingerprint> | <alias> | shell:<id>`. These URIs are the durable
target descriptions the workspace layer serializes (architecture §6.3).

**The coreutils tier is a first-class requirement**, not a multiplayer side
effect: one persistent remote shell (ssh is the default spawner, not a
dependency — container exec, adb, and serial fit), ranged reads, atomic
writes via temp-and-rename, listing via `ls`. The host capability ladder
(shell+coreutils → full weft peer) is auto-detected at open and surfaced.
Language servers place at the locus where the code is real (`ssh box zls`);
consumers elsewhere receive results as ordinary provider pushes.

## 8. As-built hazards (open until closed)

Recorded so they cannot be silently assumed done:

1. **The projection integration is unbuilt.** The flagship graph runs beside
   the editor's flat text document; the honest integration makes struct
   bodies the truth and flat text a derived projection, wired through
   Document/Editor/Collab with reconcile as the id-diff it already is. **A
   parallel dual-write representation is the forbidden class.**
2. **`syntax_claim` identity is name-keyed v1**: a rename mints a new node,
   which silently breaks a node-scoped grant. Named follow-ups: tree-sitter
   query identity, then anchor-based matching.
3. **Single-reconciler discipline is documented but not enforced** — a
   structural hazard until it is.
4. Repo invariant: no `.history.` field reach anywhere under `src/` — every
   access through the facade's own API.

## 9. Required tests (carried forward)

The falsifiable batteries from the retired docs remain binding: the live-
reconcile six (the three-check contract cases, deleted-while-editing,
register-conflict surfacing, cycle-break surfacing), the refusal-recovery
seven (including both trace locks and the recovery-trigger honesty test —
after N ticks with no recovery action the op is *still* refused, proving the
wait path dead), the guarded-save battery (stale-merge-retry, no lost
updates), divergent-checkout adoption and decline, partial-checkout realize/
converge, and lease acquisition convergence under concurrent grab. The
workspace-layer gates that depend on these are architecture §18's
no-lost-updates and crash-isolation items.

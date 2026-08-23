# D3 — Recovery from a permanently-stuck AUTHORITY refusal (task #24)

Status: DESIGN. Scope: the graph-doc subtree-grant authority path only
(`GraphCollab.admitRegions` → `.reason = .authority`/`.collapsed`). Leases
(`.reason = .lease`) already self-heal and are out of scope except as the
contrast that names the fix.

## 0. The bug, stated exactly

A subtree grant (W6 slice 2) confines a peer to editing within a granted
root's subtree on one `GraphDoc`. Enforcement is one-sided: the HOST binds a
`grants.HandleTable` and checks every inbound batch at `admitRegions`; the
GRANTEE binds nothing and is told nothing — "a granted peer learns of its new
authority only by SUCCEEDING at edits it would previously have been refused
for" (`GraphCollab` module doc). The first out-of-grant edit the grantee sends
is refused, and then the doc is permanently stuck for that peer. Two
independent properties compound to make it permanent:

1. **The refuser's frontier never advances past the refused op.** A refusal
   returns `.refuse` *before* `self.doc.merge` (GraphCollab.zig:412–424), so
   the host never integrates the op; its announced frontier (`version` of its
   own doc) never covers it. `sync_core.pushOnMove`/`sendBatch` compute the
   outbound batch as `eventsSince(their_frontier)` — everything the peer lacks
   — so the refused op is re-offered in EVERY subsequent batch from that
   sender, bundled with whatever new (legitimate) edits followed it.

2. **`admitRegions` refuses a straddling batch WHOLE.** The touched-region
   loop returns `.refuse` on the FIRST region outside the grant
   (GraphCollab.zig:662–677); there is no row-by-row partial admit. A later
   legitimate in-grant edit, once bundled with the earlier out-of-grant op,
   rides the same batch and is refused along with it.

Leases escape this because a lease refusal has a RELEASE: the same op re-ridden
after the holder releases finally passes (`admitRegions`'s "deferred-until-
release", d1 §5.2a). An authority boundary has no release event — nothing ever
makes the out-of-grant op admissible — so "deferred-until-release" degenerates
to "deferred forever." The W6 check-in test documents this inline
(`src/core/session/tests.zig` ~1506–1528) and had to sequence its negative
case dead last because the poison is irreversible within one replica's life.

This document decides how a stuck replica recovers, and — more importantly —
how the stuck state is made unreachable in the first place.

## 1. Trace results — what the substrate actually permits

Everything below was read out of the code at HEAD, not assumed. These findings
eliminate two of the four candidate designs outright.

### 1.1 Revert-in-same-batch does NOT recover (design space #1 is dead)

Claim under test: the grantee locally reverts its out-of-grant edit (an insert
then a delete that nets zero visible content), re-sends, and the now-"clean"
batch is admitted.

It is not admitted. `admitRegions` judges a batch by
`GraphDoc.touchedRegionsWithin`, which merges the WHOLE batch into a scratch
clone and reads the clone's `Change` stream (graph.zig:514–580). The change
stream is generated per-effect in `ObjectDoc.merge`: every `text_ins` and
`text_del` calls `appendTextChange`, which appends a `.text` change carrying
the object's `ObjId` (ObjectDoc.zig:1847, 1862, 1921–1936). Coalescing only
folds ADJACENT same-direction edits on the same object (insert+insert, or
del+del); an insert-then-delete pair does NOT coalesce (`le.removed == 0 and
edit.removed == 0` fails for the delete) and, even when coalescing does fire,
it still carries the object. So a net-zero insert+delete on an out-of-grant
text object still emits `.text` change(s) naming that object → the object
appears in `touched` → `within_roots == false` → `.refuse`, exactly as the
original op did. **A region is reported for every APPLIED change, regardless of
net content.** Revert-in-same-batch re-poisons rather than heals.

(There is no way to make the batch NOT touch the region either: the revert op
is a new edit on the same object; the batch necessarily carries both the
offending op and its revert, and both apply in the clone.)

### 1.2 Op-subset admission is structurally impossible on this substrate (design space #2 is dead)

Claim under test: the host admits "the batch minus the refused op."

stemma merges a batch only if it is per-agent CONTIGUOUS. `Decoder.validate`
(ObjectDoc.zig:3383–3401) requires, for each event of seq S from an agent,
that seq S−1 for that agent is already in the doc or appears earlier in the
same batch (`contiguous = ev.seq == next or seenEarlier(...)`), and that every
parent Lv resolves the same way — else `error.MissingDependency`, and the
batch is rejected WHOLE (ObjectDoc.zig:1660). An agent's events form a
sequential run (each event parents on the agent's own prior event,
causal.zig `recordLocal`/`add`), so the grantee's later legitimate op depends
on its earlier refused op through the run backbone even when the two touch
DISJOINT regions. You cannot hand stemma a batch with a hole in one agent's
run. Admitting "the batch minus the refused op" is therefore not a policy
choice the host can make; it would require the SENDER to construct a filtered
batch, and stemma exposes no such primitive — `eventsSince` returns
`missingFrom(known)` (every event the peer lacks, ObjectDoc.zig:1120–1139) and
`eventsBetween` only bounds ABOVE by a version frontier (ObjectDoc.zig:1149–
1167); neither can excise a middle op while keeping its successors. The only
way to keep the successors without the refused op is to give them NEW
identities that re-parent onto a history without it — i.e. a fork/rebase (§1.3),
not a subset.

DECIDED: do not build per-op / op-subset admission. It is incompatible with
the append-only single-agent run, not merely expensive.

### 1.3 A fork is unnecessary; re-bootstrap reuses only landed machinery (design space #3, reshaped)

The refused op exists ONLY on the grantee's own replica. The host refused it
before merge, so the host's history never contained it; and in the check-in
topology the grantee talks only to the host (star relay), so no third replica
ever received it either. Abandoning it is therefore NOT "un-writing a shared
event" — there is no shared event. It is discarding a local replica whose
tail events no one else ever accepted.

That makes the honest recovery cheap and already-built: the grantee DISCARDS
its poisoned `GraphDoc`, `GraphDoc.init`s a fresh virgin shell, binds a new
`GraphCollab`, and re-attaches; the ordinary frontier exchange bootstraps the
host's CLEAN history (which never had the poison) into the fresh doc — exactly
the empty-joiner bootstrap `GraphCollab`'s module doc describes and the
existing tests exercise (`tests.zig`:940–956 opens a virgin `GraphDoc.init`
joiner and pumps the origin's whole history in; the W6 test at :1186 already
detaches and RE-ATTACHES the same identity). The grantee then re-applies the
edits it still wants as NEW local events on the clean base. There is no seq
collision: every post-poison seq the grantee minted lives only in the
abandoned replica the host never saw, so re-minting at those seq numbers with
different content conflicts with nothing.

A stemma-level DOC FORK (new document identity, founder machinery) buys nothing
over this and costs a new identity; DECIDED: not built.

### 1.4 Why prevention is absent here but present for every sibling authority

The coarse per-doc grant is ALREADY prevention-based: the host posts an
`OpKind.grant` frame carrying the `Access` grade; the client sets
`Document.my_grant` and refuses out-of-grade edits LOCALLY before the wire
(`Collab.zig`:191–202 consume; :330 emit; only client-role accepts, never a
reverse vector). Leases are prevention-based too: acquire/release ANNOUNCE
across the wire (`base + 1` feed), so the grantee's projection knows the
boundary and acquires-on-focus before editing (d1 §5.2). The subtree grant is
the ONE authority that crosses no wire — `grantSubtree`'s doc: "Nothing here
crosses the wire in this slice." So the grantee cannot pre-flight-check its own
boundary; it can only discover it by being refused. **The poison class exists
precisely because subtree-grant authority is the only asymmetric-knowledge
authority in the system.** Restoring symmetry is the structural fix.

## 2. The decision

DECIDED — a two-part design, prevention primary, recovery as the backstop the
no-silent-third-result rule requires:

### 2.1 Prevention (primary): announce the subtree grant to its grantee

Extend the existing, precedented, currently-unconsumed `OpKind.grant` frame on
the graph quad's `base` channel to carry the granted root(s), mirroring the
text-doc grade announcement one-for-one:

- **Emit**: when `grantSubtree`/`revokeSubtreeGrants` change this peer's live
  `.graph_subtree` rows for this doc, the HOST posts an `OpKind.grant` frame:
  `uv n | (uv token_len | token) × n` — the peer's current set of live,
  reachable granted root `NodeRef` tokens (empty set = "no subtree confinement
  announced," today's unrestricted behavior). Re-announced on `rebind` like
  every other soft-state feed. This is additive: an older grantee that ignores
  `.grant` on a graph quad (`.share, .grant => return false` today) is exactly
  as safe as it is now — it simply keeps discovering the boundary by refusal.
- **Consume**: the grantee (client role only, same reverse-vector guard as
  `Collab`'s `.grant`) records the announced roots in a small local field on
  `GraphCollab` (e.g. `granted_roots: []NodeRef`). This is DISPLAY-and-
  prevention state, never authority — the host still enforces at
  `admitRegions`; the announcement is advisory and cannot widen anything.
- **Pre-flight**: the client's edit path (the projection that owns the
  `GraphDoc`) checks a candidate local edit's target node against
  `granted_roots` BEFORE committing the local op and BEFORE it can ride a
  batch. Landed machinery makes this exact check cheap: `GraphDoc.contains`
  (used by `touchedRegionsWithin`) answers "is this node within any granted
  root?" against the client's own live doc — no clone needed, because the
  target node already exists locally at edit time. An out-of-grant keystroke is
  refused locally with a visible message (the same UX contract leases already
  have: "your keystroke into a held region is refused with a visible message,
  not swallowed," d1 §5.2), and NO out-of-grant event is ever minted — so the
  poison class becomes unreachable, not merely recoverable.

This is the structural-impossibility framing: an out-of-grant op is made
impossible to *express* on a grantee that has been told its boundary, rather
than patched after it poisons the queue.

### 2.2 Recovery (backstop): re-bootstrap from the host

For the two cases prevention does not cover — a replica ALREADY stuck when this
ships, and a buggy/older/malicious client that mints an out-of-grant op anyway
— the honest recovery is §1.3's re-bootstrap:

1. The grantee already receives the LOUD signal: `region_refused` with
   `RefusalReason.authority` (or `.collapsed`) lands in `GraphCollab.refusals`.
   Unlike a `.lease` refusal, an `.authority`/`.collapsed` refusal has no
   release to wait for — so it is the trigger to recover, not to sit and
   re-ride.
2. On draining an `.authority`/`.collapsed` refusal, the client's honest path
   is: capture the local edits it still wants that ARE in-grant (it knows them
   from its own projection state), discard the poisoned `GraphDoc`,
   `GraphDoc.init` a fresh shell, bind a new `GraphCollab`, re-attach, let the
   frontier exchange pull the host's clean history, then replay the wanted
   edits as fresh local events. Lost work = exactly the refused op(s) and any
   local-only tail the client chooses not to replay — nothing that any other
   replica ever accepted.

No new protocol is needed for recovery; it is the empty-joiner bootstrap plus
the already-tested detach/re-attach. What IS needed is the client-side POLICY
that recognizes an `.authority`/`.collapsed` refusal as "re-bootstrap," not
"wait for release" — the UX contract that keeps the third result from being
silent.

### 2.3 What is explicitly NOT built

- Op-subset / per-op admission (§1.2 — impossible on the substrate).
- Revert-in-same-batch as a recovery path (§1.1 — does not heal).
- A stemma doc fork / second document identity (§1.3 — re-bootstrap dominates).
- Any host-side frontier-acknowledgement watermark that "accepts receipt
  without merging": even with one, the grantee still cannot re-send the
  legitimate successor without the refused predecessor (§1.2 contiguity), so it
  buys nothing.

## 3. Ranked fallback and triggers

If prevention (§2.1) cannot land in the same slice as this decision (e.g. the
projection edit-path hook is deferred), ship recovery (§2.2) ALONE first: it
turns a permanent poison into a bounded, honestly-signalled re-bootstrap using
only landed machinery, and it is strictly additive. Prevention then lands next
as the class-killer that makes recovery rare. The reverse order (prevention
without recovery) is NOT acceptable to ship for a system that already has stuck
replicas in the wild and must remain honest about the buggy/older-client case —
recovery is the backstop the no-silent-third-result rule demands.

DECIDED order when both fit one slice: land both; prevention is the headline,
recovery is the safety net.

## 4. What stemma must add

Nothing. Every primitive this design needs is already public: `GraphDoc.init`,
`open`, `version`, `eventsSince`, `merge`, `resolve`, `reachable`, `contains`,
`touchedRegionsWithin`. The one stemma "ask" this file surfaces is the SAME
optional one `touchedRegionsWithin`'s doc already names — a pre-merge
op→obj peek API to avoid the serialize+open+merge dry-run — and it is a
performance nicety, not a correctness dependency for D3. No new stemma delta is
required to build recovery or prevention.

## 5. Wire / protocol changes

One additive frame extension, no new channel, no new `OpKind`:

- `OpKind.grant` on a GRAPH quad's `base` channel gains a graph-doc payload
  shape: `uv n | (uv token_len | token) × n` (the grantee's live granted root
  `NodeRef` tokens). On a TEXT quad `.grant` is unchanged (one `Access` grade
  byte). Disambiguated by quad type, exactly as `region_refused` is already
  graph-quad-only. Version-tolerant by omission: an older grantee that does not
  consume graph `.grant` behaves exactly as today (discovers the boundary by
  refusal); an older HOST that never emits it leaves the grantee in today's
  discover-by-refusal mode — both degrade to current behavior, never to a
  decode error, same additive convention as the lease frame's trailing `hue16`
  and `region_refused`'s trailing reason byte.

No change to `batch`/`frontier`/`region_refused`/lease frames. Recovery
(§2.2) adds no wire surface at all.

## 6. Falsifiable tests

Anchored on the existing `src/core/session/tests.zig` harness (socketpair
`Session`s + `GraphCollab`, `fill`/`version`/`compareVersions == .equal`
checks) and `src/core/grants.zig`'s direct-mint unit tests.

1. **Trace lock #1 — revert-in-same-batch is still refused (falsifies design
   #1).** Grantee edits out-of-grant, then reverts (insert+delete netting zero)
   in the SAME batch; assert the batch is STILL refused with `.authority` and
   the host's doc is unchanged. Guards the §1.1 finding against a future
   change to `Change`-stream coalescing.
2. **Trace lock #2 — op-subset is not attempted / contiguity holds (falsifies
   design #2).** A batch with an out-of-grant op followed by an in-grant op is
   refused WHOLE (the existing "straddling ... refused WHOLE" test already
   asserts this direction; extend it to assert the in-grant op does NOT land
   even after re-ride, proving no partial admit path exists).
3. **Prevention — announced grant reaches the grantee.** Host `grantSubtree`
   then push; assert the grantee's `GraphCollab` recorded the announced root(s)
   via the graph `.grant` frame; assert an out-of-grant local edit is refused
   LOCALLY (never posted — zero inbound batches on the host carry it, and the
   host's `refusals` list stays empty because nothing out-of-grant ever
   arrives).
4. **Prevention is advisory only — cannot widen.** A grantee that IGNORES the
   announcement (or an announcement claiming a wider root than the host's table
   holds) still cannot get an out-of-grant op merged: the host's `admitRegions`
   refuses it. Asserts the announcement is display/prevention state, never
   authority (mirrors the REQUIRED-FIX-1 spoof test's spirit).
5. **Recovery — re-bootstrap heals a poisoned replica.** Drive the doc into the
   stuck state (out-of-grant edit, refused, subsequent in-grant edit refused by
   bundling — the current W6 negative case). Then: discard the grantee's
   `GraphDoc`, `GraphDoc.init` fresh, re-attach, replay the in-grant edit.
   Assert (i) frontiers converge (`compareVersions == .equal`), (ii) the
   in-grant edit landed on the host, (iii) the out-of-grant edit did NOT, (iv)
   the host's stream/other regions were never disturbed. This is the test the
   W6 check-in comment says "has no mechanism today."
6. **Recovery trigger honesty — no silent third result.** Assert an
   `.authority`/`.collapsed` refusal is surfaced in `refusals` (already true)
   AND that the recovery policy treats it as re-bootstrap, not as
   deferred-until-release (i.e. the grantee does NOT sit re-riding forever):
   after N ticks with no recovery action, the op is still unmerged and still
   refused — proving the "wait" path is a dead end and the client MUST act.
7. **Collapse composes with recovery.** A grantee whose sole grant root is
   deleted (collapse → `.collapsed`, total refusal per `GrantContext`'s doc)
   recovers by the SAME re-bootstrap path; assert it converges to the host's
   post-collapse state with none of its now-ungrounded edits.

## 7. D1 §5.2a amendment text

Add, immediately after the existing "Refusal is deferred-until-release, not
permanent rejection" bullet in §5.2a, a new subsection:

> ### 5.2b Authority refusals do not self-heal — recovery is re-bootstrap (W6 slice 2, task #24)
>
> The deferred-until-release property above is a LEASE property: a lease
> refusal heals when the holder releases, so the sender's re-ridden op
> eventually lands. A SUBTREE-GRANT authority refusal (`RefusalReason.authority`
> / `.collapsed`) has no release — nothing ever makes an out-of-grant op
> admissible — so "deferred-until-release" degenerates to a permanent poison:
> the refuser never merges the op, its frontier never advances past it
> (`admitRegions` refuses before `merge`), and `sync_core`'s frontier-delta
> re-offers it in every future batch, refused WHOLE alongside any legitimate
> edit bundled with it (per-agent run contiguity forbids admitting the batch
> minus the refused op; `ObjectDoc.Decoder.validate`). This is by construction,
> not a bug in the mechanism, and it is why the W6 check-in test sequences its
> out-of-grant negative case last.
>
> Two things resolve it, and neither is op-surgery:
>
> - **Prevention (primary).** The subtree grant is now ANNOUNCED to its grantee
>   over the graph quad's `OpKind.grant` frame (the same host→client authority
>   announcement the coarse per-doc grade already uses for text docs). The
>   grantee's projection refuses out-of-grant edits LOCALLY before the wire —
>   as leases already prevent lease violations by their bidirectional announce
>   — so an out-of-grant op is never minted and the poison class is
>   unreachable. Grantee-side knowledge is advisory: the host still enforces at
>   `admitRegions`; the announcement can never widen authority.
> - **Recovery (backstop).** A replica already poisoned (or a client that sends
>   out-of-grant anyway) recovers by DISCARDING its `GraphDoc` and re-bootstrap:
>   `GraphDoc.init` a fresh shell, re-attach, let the frontier exchange pull the
>   host's clean history (which never merged the poison), and replay the
>   still-wanted in-grant edits as new local events. The refused op existed only
>   on the grantee's own replica (the host refused it pre-merge; in the star
>   topology no third replica received it), so abandoning it un-writes no shared
>   event — it discards a local tail no one else ever accepted. Uses only the
>   empty-joiner bootstrap and the tested detach/re-attach; no fork, no new
>   document identity, no stemma delta.
>
> An `.authority`/`.collapsed` refusal is therefore a signal to RE-BOOTSTRAP,
> not to wait — the no-silent-third-result rule applied to authority: the
> grantee knows (its `refusals` list), and its recovery path is defined.

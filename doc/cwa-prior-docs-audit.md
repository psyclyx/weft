# Absorption audit: the nine deleted design docs vs contextual-workspace-architecture.md

Status: AUDIT RECORD, 2026-08-26. Produced during the review of
`doc/contextual-workspace-architecture.md` (see `doc/cwa-review.md` for the
corrected overall findings — a few dispositions below were re-scored there:
the register demolition and the negotiation/flag-day items are recoverable with
sentences, not contradictions; §13.7 partially seeds d3's recovery). This file
was the raw material for (a) the "Relation to prior designs" supersession map
(now architecture §1.1) and (b) the substrate companion — the still-binding
decisions below are re-homed normatively in `substrate.md`; this audit remains
the historical map of where each came from and what was deliberately
superseded. The deleted docs are retrievable via `git show HEAD:doc/<name>`
until the deletion commit ages out of convenient reach — which is why this
record exists.

Scope note that colors everything: the new doc is a workspace / protocol /
dispatch / collaboration-policy architecture with **no substrate layer** — no
CRDT/anchor/region/locus primitives, no document-storage or wire-format
decisions, no reconcile algorithms. Roughly half the deleted material lived
below its floor and has nowhere to land. The surviving sibling docs absorbed
nothing (their working-tree diffs are citation-removal only). **232 source
references across 78 files** cite the deleted docs; highest density:
`GraphCollab.zig` (d3 ×7, d1 ×3), `graph.zig` (w7 ×4), `transcript.zig`
(editable-projection ×3), `syntax_claim.zig`, `session/tests.zig`,
`region_lease.zig`, `wire.zig`, `remote_fs.zig`, `backing.zig`.

---

## 1. dispatch.md

Decisions: (1) three separable tiers — keymap (mode→key→name) → action
(providers·when·priority) → command registry; (2) keymap layering algebra —
priority tiers core(−100)<plugin(0)<config(100), mode→parent fallback chains, a
reserved `global` mode consulted after a mode's own chain, final check, never a
fallback target; (3) deliberate refusal of VSCode-style `when`-clauses on
bindings — context-sensitivity lives in the action tier; lookup stays a fast
total table walk; (4) action resolution `when={mode?,lang?}`, ties break toward
the more specific predicate, then later registration; (5) two policies — pick
(sync, single best, no-provider → graceful echo) and race (async fan-out,
merged against a stamped version); (6) actions ride the command door via
same-named trampoline commands; every mutator crosses `Context.edit`, routed to
the user's *or the plugin peer's* undo history.

Dispositions: (1) SUPERSEDED by §9/§10.2 (input-grammar→intention→catalog→
endpoint), cleaner on provenance. (2) DROPPED — §11.4 governs menu/toolbar
contributions, not keybinding layers; no parent-chain or `global`-layer
semantics anywhere; §10 specifies no precedence at all. (3) DROPPED — §10.2's
per-binding fallback lists are per-binding conditionality by another name; the
performance rationale is gone. (4) SUPERSEDED with a real behavior change —
§9.2 makes equal-strongest an explicit ambiguity where dispatch.md let
`lang:zig` silently beat an unconstrained default; ratify deliberately, it
affects every language plugin. (5) ABSORBED into §8; "graceful echo" superseded
by §9.3 absence semantics. (6) trampolines SUPERSEDED and demolished (§19); the
per-peer-undo half of the one-door rule is DROPPED (see extensibility.md).

## 2. extensibility.md

Decisions: (1) a buffer is a CRDT replica; every mutator is a peer; no bare
offset crosses a boundary without its version — rebase to an anchor or `null`,
never a stale third result; (2) Locus (`Tier{here,peer,shell}`) rides inside
handles; R1 no bare local-default paths; R2 fingerprint is identity, address a
hint; R4 net dials from the locus's vantage ("the locus IS the tunnel"); R5
remote degrades like a dead provider; (3) Principal
{agent, owner, role, caps, grant}; effective power = host_caps ×
min(owner_grant, manifest_grant); "act as the user" refused; (4) anchors/ranges
as first-class ABI values; **motions return ranges** (kills the shared-cursor
side-channel; makes `d/foo<CR>`, remote `d}`, async motions compose); (5)
`document.spawnPeer` + `ctx.asPeer` → per-peer selective undo (repl/clear
undoes only the tool peer; agent review separates claude#1 from codex#2); (6)
[FIX 2] applied action results re-attributed to the provider's principal and
CLAMPED to the fired range — out-of-range batch traps; [FIX 10] speced-but-
unimplemented params trap at register, never silently no-op; [FIX 11]
`subbuffer.claim` for nested language regions; [FIX 12] recursive fs.watch;
[FIX 13] `kv.*` per-plugin persistence.

Dispositions: (1) thesis SUPERSEDED deliberately (§1/§4/§14.1) — but the
concrete guarantee is DROPPED: no anchor primitive, no rebase-or-null; §6.2/
§15.5 operate at whole-resource revision granularity. (2) Locus mechanism
DROPPED (the word survives in §13.3); ambient-authority ban absorbed for
head/editor, not for host/locus. (3) ABSORBED and generalized by §13.5 — the
best absorption in the consolidation. (4) DROPPED — §6.6 Extent is the shape,
but nothing says motions return extents. (5) PARTIAL — attribution absorbed
(§12/§18); per-principal inverse DROPPED; agent-review/repl-clear lose their
basis. (6) clamp DROPPED (malicious-formatter laundering uncovered);
trap-not-no-op ABSORBED strongly (best-preserved principle); subbuffer/kv/
recursive-watch DROPPED. Pick bright line: candidate-identity half absorbed
(§14.5); the boundary budget (one bulk memcpy; one match_rank per keystroke;
never N guest calls) DROPPED. The mode model's mechanism
(`activate(predicate, contribution)`, want\have reconcile, retroactive
plugin-load reconcile) DROPPED — `src/core/mode.zig` ships it.

## 3. extensibility-critique.md

Decisions: (1) root cause of #1/#3/#7/#8 — the ABI expresses bytes/scalars but
not *identities* (anchors, ranges, peers), so every domain reinvents them as
side-channels; (2) #2 release-blocking: multiplayer edit-safety absent
(`peerCommit` ungated, no `ctx.principal`); "fire is free" must not imply
"apply is trusted"; (3) #5: vim policy in core — `lookupLayered` hardcodes
modal-beats-language; (4) #9: "order cannot matter" is false — six first-wins
mechanisms with no tiebreak; need `(priority, owner, id)` plus a
shadow-vs-collision distinction; (5) #10 silent no-op = forbidden third result;
#6 presence should be a grant-keyed replicated layer, not a bespoke wire; (6)
#11/#12/#13 sub-buffer regions, recursive watch, durable kv.

Dispositions: (1) SPLIT — resource/endpoint identity absorbed superbly
(§6.1–6.5); position identity and authorship identity DROPPED; the critique's
complaint ("banned bare offsets, then failed to provide the stamped-identity
replacement") now applies verbatim to the new doc's §18/§19. (2) ABSORBED
(§2.7/§5.1/§18); the apply-clamp half DROPPED. (3) first half ABSORBED
(§10.1/§7/§19); declared layer precedence DROPPED. (4) PARTIAL — spirit in
§9.2/§11.4; the total order, its application to all resolution, and
shadow-vs-collision DROPPED. (5) #10 ABSORBED (best-preserved); #6 presence
ABSORBED in outcome (§13.1/§18). (6) all three DROPPED.

## 4. sessions-design.md

Decisions: (1) buffers have typed backings — file | shell-remote | tool |
none(scratch); save writes the backing, save-as re-points it; (2) editors
connect to editors (no dedicated agent binary); one history root per shared
buffer; a joiner with a divergent local file imports the diff as their ops or
opens private — never merge unrelated histories, never guess by content
equality; (3) the coreutils tier is a first-class requirement — one persistent
remote shell (ssh the default spawner, not a dependency), ranged reads via
dd+base64, atomic writes via base64 -d > tmp && mv, host capability ladder
(shell+coreutils → weft-agent) auto-detected and surfaced in the status line;
`ssh box zls` LSP placement; (4) **the backing file is a peer** — external
writes are hash-detected, diffed, committed as that peer's ops; save is a
guarded test-and-set (upload temp → hash target → mv iff unchanged, else
STALE → merge → retry): "**no lost updates; bounded retry**"; (5) tool buffers:
keymap-mode + read_only belt-and-braces; a tool backing regenerates content by
being a plugin peer; (6) editable partial checkout (`PartialDoc`,
realize-from-viewport, bounce-realize-converge, `--partial`) and bulk load
(`openFromContent` — content is the compacted base; 4 MB from minutes → 0.2 s).

Dispositions: (1) PARTIAL — §7/§14.2 carry targets/persistence; the four-case
typed backing and save-as re-pointing DROPPED; **no `save` intention exists in
§10.2**. (2) sharing SUPERSEDED and better (§13.2); the divergent-checkout rule
DROPPED (§13.7's fork sentence covers reconnect, not open-time divergence). (3)
DROPPED entirely — §13.4 covers plugin asymmetry, never host asymmetry. (4)
DROPPED — §12's "preflight then commit" is the shape, but no stale detection,
no hash token, no merge-external-as-peer-ops, and **no no-lost-updates
acceptance gate**; shipped as `src/core/backing.zig`. (5) SUPERSEDED correctly
(§2.1/§19/§11.1). (6) DROPPED — §11.6's windowing is presentation-level, not
document-level; `PartialDoc.zig` ships with no design record.

## 5. north-star-plan.md

Decisions: (1) kernel = Container + Membrane + **platform providers as slots**
(window/input/present/rasterizer/proc/net/fs/clock as default providers —
nothing above can tell a default from a replacement; makes a DRM/libinput
compositor build expressible) + substrate; systems are manifests (values); (2)
Ctx is an immutable captured value; scopes supply facts + lifetime, **never
rank**; a background `setMode` fails to compile; transient/menu modes are
structurally paired (scope exit IS the pop); (3) total order
`(tier, priority, specificity, owner fingerprint, declaration index)`; tiers
core<imported<plugin<config<transient; **imported manifests land one tier below
the importer**; collision (different owners, equal keys, overlapping
predicates) = load-time error; `explain(slot, ctx)` first-class; query/value
re-resolve per fire, **feed/action sessions PIN their provider** ("an LSP feed
never migrates mid-stream"); (4) grants: capture time is the powerbox — handles
resolved at Ctx capture are part of the Ctx (no wallet → confused deputy
structurally impossible); scope exit revokes; text-region limits are
identity-anchored, collapse-and-trap; `head/attach` is a named grant and
attaching IS the consent act; (5) native-blob trust split, stated plainly:
"against *mistakes* the structure holds on both transports; against *malice*,
only wasm sandboxes" — native = kernel-module-grade consent, version-locked;
(6) three authority modes, honestly labeled — on_save / live / authoritative;
`authoritative` is the CORRECT design (not a fallback) for single-truth models:
"a seek is a COMMAND, the position is a latest-wins feed, and CRDT-merging it
would be actively wrong"; stated per tool, never defaulted; (7) a local head is
a degenerate remote attach; **remote heads fire the UI slots over the wire**
(the scene vocabulary is metric-free, hence wire-safe); zero-head resting
systems; live system swap; (8) a dispatch-latency instrument BUILT in W0a with
a baseline captured before anything moves; config evaluation SEALED
(deterministic, injected clock, no ambient I/O); the approved artifact is the
manifest value + hash; re-evaluation differing invalidates approval (closes
TOCTOU on the approval diff).

Dispositions: (1) kernel SUPERSEDED by a better-specified §5.1; **platform-as-
slots DROPPED entirely** (no platform row in §16; compositor aspiration lost).
(2) PARTIAL — scope kinds survive in §5.4; scopes-never-rank, structural
pairing, and the compile-time background-setMode impossibility DROPPED. (3)
SPLIT — `explain()` ABSORBED and improved (§9.2/§9.5, the single best
absorption); the total order, import-tier rule, declaration-index rule, and
provider pinning DROPPED. (4) LARGELY ABSORBED (§12/§9.1/§13.5/§18);
`head/attach` grant and identity-anchored region limits DROPPED. (5) DROPPED —
an honesty regression: §2.7/§18 assert the uniformity the old doc refused to
claim. (6) ALL THREE MODES DROPPED. (7) PARTIAL — head/system split absorbed
(§7/§18); §13.3 rule 1 is the opposite answer to remote-heads-fire-slots,
adopted without noting the trade (per cwa-review.md: compatible — a
scene-stream export is an Endpoint — but the thin-head topology needs a stated
sentence); zero-head systems and the daemon model DROPPED. (8) BOTH DROPPED —
the new doc has no performance requirement of any kind, and no config
evaluation/approval story. Phase gates ABSORBED in form (§17/§18/§20).

## 6. editable-projection.md (the deep dive)

Committed design: (1) Model 2 — one always-editable buffer; the Files buffer's
text IS the editable name tree; expanding a fold splices child lines in place;
(2) name-is-content, metadata-is-decoration (identity = hidden id-span, never
in the text; perms/size/glyph drawn beside via virtual_before/eol/gutter);
payoff stated structurally: `yy` yanks exactly the name in vim or helix or
modeless — "no editor learns the word dired"; (3) path-independent identity +
initial→current reconcile, purely by id, **across all open dired buffers** (a
moved file leaves one buffer and appears in another); five cases: untouched /
rename / move / delete / create; (4) **the register is the crux**: an id cannot
ride copied bytes (yank is raw slice→bytes; paste is a fresh insert → new CRDT
identities; anchors are position-keyed); the ONLY thing spanning
cut-in-A→paste-in-B is the register; hence core `register.zig` =
{text, linewise, payloads:[{offset,len,facts}]}; security property: retyped
text can never acquire an id (no span → create, never move); (5) the seam:
projection owns STRUCTURE, editor owns EDITING; (6) tool-backed `save` hook —
`on_save` returns an ordered op list; core shows a generic pending-changes
popup gated y/n; catches C-s / :w / :wq / palette-save, every route, any
editor; (7) phase-2 finding: the decoration placement enums exist but **no
renderer draws them**; recommended inline-virtual rendering (virtual_before as
leading dimmed non-document cells, caret stops shifted); explicitly generalizes
to inlay hints, git blame, breakpoint glyphs; fallback ladder recorded
(names-first ships the crux with zero render work); (8) generalizes to magit
staging-by-editing, editable buffer-list, config editor, grep-writeback.

Dispositions — **the capability is silently lost**: (1) DROPPED, and the new
doc's framing is hostile to it (§2.1 disease framing; §10.1; §4's content-union
non-goal never connected to wdired); §14.2 never binds Files to the
editable-sequence protocol — what it actually specifies is drafts + typed
actions + forms (and it is *silent* on rename specifically). (2) DROPPED — no
virtual text mechanism anywhere; with it goes the only inlay-hint/blame/
breakpoint-glyph mechanism the doc set had. (3) DROPPED including the
cross-buffer rule. (4) ACTIVELY REVERSED — §17.3.4 + §19 direct removal of
core registers against a shipped `src/core/register.zig` and an unrebutted
argument (per cwa-review.md: recoverable — §5.2's transfer package is the
intended home; the missing sentence is *transfer payloads carry
designations/facts*). (5) ABSORBED and strengthened (§2.3, §5.4, §18's
synthetic-grammar gate) — the one clean survival. (6) PARTIAL — change
proposals absorbed (§9.4/§12); the save-route binding DROPPED (no `save`
intention in §10.2); `Editor.setToolBacking` ships the hook and cites the
deleted file. (7) DROPPED — the finding will be rediscovered. (8) magit
staging superseded differently (§14.3 select-then-act, defensible); the rest
unmentioned.

## 7. d1-live-reconcile.md

Decisions: (1) a region is exactly one ObjId; an edit is in-region iff its
byte range falls entirely within one id-span — that distinction, not a timer,
is the fault line; (2) the commit-point hypothesis is WRONG for in-region text
— in-region edits translate immediately; batching is pure loss; (3) live
structure = on_save at automatic region-scoped commit points: declared
syntactic boundary (primary) → focus-leave → idle backstop; between commit
points the structural delta is local-only (peers never see a node flicker);
(4) the mode-per-tool table: **fs-authority and single-truth tools are never
live** — dired → on_save ("a half-typed rename must not `mv`"), magit →
on_save, media-player/system-monitor/log-tail/debugger-run-state →
authoritative, code buffer → live(text); (5) the three-check projection
contract making "no silent third result" enforceable by construction: on every
post-merge render — (i) every rendered region's NodeRef still resolves and is
reachable (deleted-while-editing is surfaced, never silently dropped); (ii)
every register key has mapConflictCount ≤ 1 or all conflicting values are
surfaced; (iii) cycle-break survivors are surfaced; text interleaving is the
only silent outcome and correct by FugueMax; (6) the fallback is
single-writer-per-REGION — a soft-state lease: acquire on focus-enter, release
on leave/idle/yield, reaped on disconnect; admission enforces it (an unheld
batch is refused loudly); display declares it (locked-by-Bob in presence hue;
a refused keystroke gets a visible message, never swallowed); (7) as-built
invariants: concurrent acquire converges by deterministic tiebreak (byte-wise
lower principal name), no linearizability promised; refusal is
deferred-until-release; leases survive reconnect by re-announcement.

Dispositions: (1)–(3) DROPPED (the word "leased" survives vestigially in
§6.3/§6.6 with no semantics). (4) DROPPED — §14.2's drafts are compatible in
outcome; the rule, rationale, and per-tool declaration requirement are gone.
(5) DROPPED — §15 covers none of the three cases; the new doc has no concept
of concurrent-write conflict sets in replicated state; the only
conflict-surfacing sentence anywhere is §13.7's reconnect fork. (6)+(7)
DROPPED — §13.5's Grant is authority, not mutual exclusion; shipped as
`src/core/session/region_lease.zig`, whose comments cite this file. Stemma
frontier (delta 3 etc.) partially preserved in stemma-unification.md; the
weft-side consequences DROPPED.

## 8. d3-refusal-recovery.md

Decisions: (1) the failure mode, proven from code: a subtree-grant refusal is
**permanent by construction** — the refuser returns before merge, its frontier
never advances past the refused op, `eventsSince` re-offers it in every batch;
`admitRegions` refuses straddling batches whole; leases escape (a release
exists), authority boundaries don't; (2) dead design #1: revert-in-same-batch
does not recover — a region is reported for every APPLIED change regardless of
net content; revert re-poisons; (3) dead design #2: op-subset admission is
structurally impossible — stemma merges only per-agent-contiguous batches;
later legitimate ops depend on the refused op through the run backbone even
when regions are disjoint; "do not build per-op admission"; (4) recovery is
re-bootstrap, not a fork: discard the poisoned replica, re-attach, pull clean
history, replay still-wanted in-grant edits as new events — safe because the
refused op existed only on the grantee's replica; (5) prevention (primary):
announce the subtree grant to its grantee over the existing grant frame;
grantee records granted_roots as display-and-prevention state, never
authority; edit path preflights locally — an out-of-grant keystroke is refused
visibly and **no out-of-grant event is ever minted**; root cause named: the
subtree grant is the one asymmetric-knowledge authority in the system;
restoring symmetry is the structural fix; (6) ranked order: recovery may ship
alone; **prevention without recovery is not acceptable to ship**; wire change
additive and version-tolerant by omission; (7) seven falsifiable tests incl.
two trace locks guarding the dead designs against substrate drift.

Dispositions: (1) DROPPED and assumed away — §15.13 describes a clean terminal
local failure, exactly what d3 disproved for replicated documents. (5) DROPPED
— §9.1/§13.6 codify discover-at-the-door, the poison precondition; §9.3's
disabled{reason} is catalog-scoped, and nothing requires an owner to announce
a grantee's scope. (4) DROPPED — §13.7's fork sentence is the nearest
relative, materially weaker, reconnect-scoped. (2)+(3) DROPPED — negative
knowledge, the most expensive kind to re-derive; the two obvious ideas any
future implementer will try are both proven impossible against this substrate.
(6) DROPPED. Wire additivity ABSORBED in generic form (§13.4/§13.7).
(Per cwa-review.md: the fix is one prevention paragraph citing this file, plus
the fork/re-bootstrap backstop — §13.7 and §13.5's grant-knowledge trichotomy
are the seeds.)

## 9. w7-rebase.md

Decisions: (1) option (i) DECIDED — rebase `Document` onto ObjectDoc-with-one-
root-text-node; option (ii) rejected (cannot host node identity; freezes two
Op types/facades/wire formats); (2) W7 SPLIT — W7a (substrate unification,
gate = drop-in parity) vs W7b (the flagship node layer, gate = the function
grant); "do not let 'swap the backing' be mistaken for 'flagship works'"; (3)
the parity ledger: anchors and compaction at parity; five remaining gaps —
eventsBetween, openFromContent, materializeAt, the partial-checkout family,
RLE wire; a naive swap regresses four shipped features; (4) the crux — node
identity vs anchor-pair buys exactly three things: move-survival, collapse
robustness, exact subtree containment; for a contiguous edited-but-not-moved
function the two are observably identical; (5) DECIDED 2026-08-22 — the wire
flag-day, ratified (collab pre-GA; a version-byte fork preserves compatibility
no live session needs), **with the reopening condition: "if a mixed-version
fleet exists before W7a lands, this decision reopens"**; (6) W7-0 hygiene
gate: no `.history.` field reach anywhere under src/; (7) AS-BUILT W7b
remainder (recorded, not implied done): the honest integration is the
PROJECTION (struct bodies become the code buffer's truth, flat text a derived
materialization) — **"a parallel dual-write representation is the forbidden
class"**; `syntax_claim.zig` identity is name-keyed v1 — **a rename mints a
new node** (silently breaking a grant); **single-reconciler discipline is
documented as a structural hazard, not yet enforced**; structural admission is
pure intra-subtree reparenting with pre-merge-union checks.

Dispositions: (1)+(2) DROPPED — no substrate phase in §17; stemma-unification
survives but explicitly defers the swap-vs-facade decision to weft, so the
decision now has no home. (3) DROPPED — `PartialDoc.zig`/`remote_fs.serveBase`
ship with no design record. (4) DROPPED, and the flagship capability itself
(sub-document grants) has no home in §13 — shipped as `grants.zig`
DocRegion/GraphSubtree + `command.checkDocRegion`. (5) per cwa-review.md:
temporal supersession on the decision's own terms (the reopening condition
materialized); owes a citation. (6) DROPPED (minor, stated repo invariant).
(7) DROPPED — **the most dangerous single deletion in the set**: three open
hazards on shipped code with no other written record.

---

## Dropped-items rollup (the supersession-map checklist)

Nothing below is covered in the new doc, architecture.md, d2-schema-payloads.md,
or stemma-unification.md. Items marked ★ have shipped code whose design record
this audit is now the only trace of.

### A. In-place editable projections
1. wdired-style in-place editing (rename-by-typing, dd/p-to-move,
   :w-to-reconcile) — not preserved, not replaced, not refused.
2. name-is-content / metadata-is-decoration and its structural payoff.
3. Hidden per-row id-spans + the initial→current id-diff (5 cases), including
   the cross-buffer rule.
4. ★ The register payload ferry as a core service (`src/core/register.zig`) —
   §17.3.4/§19 direct its removal; fix = transfer-carries-designations
   sentence.
5. The security property: retyped text can never acquire an id.
6. ★ The tool-backed `save` dispatch (`on_save` → op list → generic confirm →
   apply), every save route, any editor; no `save` intention exists in §10.2.
7. ★ The decoration render path (virtual_before/eol/gutter, inline-virtual
   cells, caret-stop shifting) — the doc set's only inlay-hint/blame/
   breakpoint-glyph mechanism — plus the phase-2 finding (enums exist, no
   renderer draws them) and the names-first fallback ladder.
8. Generalization targets: editable buffer-list, config editor, grep-writeback.

### B. Live reconcile & conflict semantics (d1)
9. Region = one ObjId; the in-region / cross-region fault line.
10. In-region text needs no commit point (batching is pure loss); structure
    does.
11. Region-scoped commit points (declared syntactic boundary → focus-leave →
    idle) and the local-until-commit rule.
12. The three-check projection contract; the new doc has no concept of
    concurrent-write conflict sets in replicated state.
13. ★ The per-region lease in full (`src/core/session/region_lease.zig`):
    acquire/release, per-region admission refusal, locked-by-Bob display,
    visible-message keystroke refusal, deterministic name tiebreak,
    deferred-until-release, re-announce-on-reconnect.
14. "fs-authority and single-truth tools are never live."

### C. Authority-refusal semantics (d3)
15. The permanent-poison failure mode; §15.13 assumes clean terminal failure.
16. Prevention by announcing a grant to its grantee + local preflight; the
    root-cause finding (asymmetric-knowledge authority generates the class).
17. Recovery by re-bootstrap and the argument that makes it safe.
18. The two proven-dead designs and their trace-lock tests.
19. The ranked-fallback rule (never ship prevention without recovery).

### D. Substrate & document core (w7, sessions)
20. ★ Sub-document / region-scoped grants entirely (`grants.zig` DocRegion/
    GraphSubtree, collapse-and-trap, `command.checkDocRegion`) and the
    "agent may edit only this function" flagship.
21. Identity anchors as a primitive (EventAnchor, rebase-or-null) — the new
    doc bans rendered rows/offsets as identity without supplying the
    replacement.
22. The W7a/W7b split, the parity ledger, and the four remaining stemma gaps.
23. ★ Editable partial checkout (`PartialDoc.zig`, realize-from-viewport,
    bounce-realize-converge, `--partial`) and bulk load (`openFromContent`).
24. The ratified wire flag-day and its reopening condition (owes a citation in
    §13.4).
25. ★ The AS-BUILT W7b remainder: unbuilt projection integration + "parallel
    dual-write is the forbidden class"; `syntax_claim.zig` name-keyed identity
    v1 (a rename mints a new node, silently breaking a grant);
    single-reconciler discipline documented but unenforced.
26. ★ Backing-is-a-peer + guarded test-and-set save (`src/core/backing.zig`):
    external-write detection, merge-as-peer-ops, STALE-retry, "no lost
    updates" — no acceptance gate exists.
27. The coreutils/shell-fs tier and the host capability ladder ("a first-class
    requirement, not a multiplayer side effect"), status-line tier surfacing,
    `ssh box zls` LSP placement.
28. The divergent-checkout rule (adopt-and-import-as-your-ops or decline into
    private; never merge unrelated histories; never guess by content
    equality).
29. The four-case typed backing (file | shell-remote | tool | none) and
    save-as re-pointing.

### E. Kernel, dispatch, and ABI
30. Keymap layering algebra: priority tiers, mode→parent chains, the `global`
    layer (consulted last, never a fallback target).
31. The refusal of `when`-clauses on bindings and its total-table-walk
    rationale (§10.2 reintroduces per-binding fallback lists).
32. The total resolution order `(tier, priority, specificity, owner,
    declaration index)`, import-tier-below-importer, declaration-index-within-
    one-owner, shadow-vs-collision.
33. Provider pinning for in-flight feed/action sessions.
34. anchor/range as first-class ABI values; motions returning ranges (with it,
    the `d/foo<CR>` async-motion composition fix).
35. `spawnPeer`/`asPeer` and per-peer selective undo.
36. Action-result range clamping (the malicious-formatter laundering fix).
37. ★ `subbuffer.claim` / virtual sub-buffers for nested language regions
    (`src/core/subbuffer.zig`).
38. The Locus model in full (locus-in-handle, URI grammar, R1–R5, the
    liveness ladder).
39. ★ The mode model's mechanism — `activate(predicate, contribution)`,
    want\have reconcile, retroactive plugin-load reconcile
    (`src/core/mode.zig`).
40. The pick boundary budget (native-only source→pool; one bulk memcpy; one
    match_rank per keystroke).
41. `kv.*` per-plugin persistence (frecency, recents, kill-ring) and
    recursive fs.watch (the O(files) shell-tier failure).
42. Platform-mechanisms-as-slots (window/input/present/rasterizer/proc/net/
    fs/clock) and the compositor build they made expressible.
43. The native-blob trust split ("against mistakes the structure holds on both
    transports; against malice, only wasm") — §2.7/§18 assert a uniformity the
    old doc called a lie.
44. The `authoritative` reconcile mode ("a seek is a COMMAND… CRDT-merging it
    would be actively wrong"), never defaulted silently.
45. Structurally-paired transient scopes (a leaked chord inexpressible) and
    the compile-time impossibility of a background `setMode`.
46. `head/attach` as a named grant with attach-as-consent.
47. Sealed, deterministic config evaluation with hash approval (closes TOCTOU
    on the approval diff).
48. The dispatch-latency instrument and baseline; the new doc has no
    performance requirement of any kind.
49. Zero-head resting systems, systems-as-swappable-manifests, the daemon
    model.
50. Remote heads firing UI slots over the wire (per cwa-review.md: compatible
    with §13.3 rule 1 as a scene-stream Endpoint export; needs one stated
    sentence on the thin-head topology).

### F. Process hygiene
51. 232 source references across 78 files cite the deleted docs. Highest
    density: `GraphCollab.zig` (d3 ×7, d1 ×3), `graph.zig` (w7 ×4),
    `transcript.zig` (editable-projection ×3), `syntax_claim.zig`,
    `session/tests.zig`, `region_lease.zig`, `wire.zig`, `remote_fs.zig`,
    `backing.zig`.

---

## Recommendations (carried into cwa-review.md's revision order)

1. If the consolidation is meant to *supersede* rather than *discard*, these
   need explicit dispositions in the new doc before merge: in-place editable
   projections (§14.2), the register/transfer question (§17.3.4 vs
   `src/core/register.zig`), sub-document grants (§13.5), concurrent-write
   conflict surfacing (§15), and the protocol-negotiation citation (§13.4 vs
   w7 §3.1).
2. The d1/d3/w7 as-built sections and the two proven-dead designs are records
   of shipped behavior and expensive negative knowledge; they belong in a
   substrate companion doc regardless of whether their parent plans survive.

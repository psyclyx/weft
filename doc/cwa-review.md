# Review of contextual-workspace-architecture.md (post-synthesis)

Status: REVIEW RECORD, 2026-08-26 — **APPLIED**: revision 2 of the subject doc
incorporates this review's revision order (the fork decision, embedding and
annotation sections, postures and reconcile modes, grant scope, the pushed-offer
catalog and latency commitments, the sentence-level dispositions, thinned
Phase 1, new gates, and the §20 rewrite). The companions are written: `substrate.md`
(normative re-homing of the d1/d3/w7/sessions decisions) and
`configuration.md` (the config model; naming grammar and bind arity decided
there). The dangling source citations have since been swept (see
"Post-review corrections"). The pre-revision draft is preserved as
`contextual-workspace-architecture.orig.md`. Subject:
`doc/contextual-workspace-architecture.md` (2026-08-25 draft). How produced: three independent code-verification passes over
the working tree, an absorption audit of the nine deleted design docs (full
results: `doc/cwa-prior-docs-audit.md`), cross-checks against the surviving
sibling docs and config files, and then an adversarial re-review of the whole
review by an independent agent, whose corrections are integrated here. This
document is the current, corrected state — it supersedes the intermediate drafts.

Companion artifacts:
- `doc/cwa-prior-docs-audit.md` — per-deleted-doc absorption dispositions + the
  dropped-items rollup (raw material for the supersession map and the substrate
  companion doc).
- `doc/cwa-config-decisions.md` — the configuration-model decision walk and the
  two stress-test plugin analyses (generic sidebar, note embeds).

## Verdict

The frame is right and should not be reframed: provider-owned identity, typed
versioned protocols, pure contextual resolution, publication-scoped grants, and
the §15 honesty boundaries are the correct generalization of what v1 already
proved in miniature (the caps registry, activation predicates, locus-in-handles,
the membrane). The §2 premises are real — verified against the tree, two of them
*understated*. The non-goals are hard-won: nearly every one maps to a shipped
footgun or a failure the code exhibits today.

The doc is **not startable as-is**, for reasons that are cheaper to fix than the
first-pass review claimed but more structural than a polish pass:

- **Finding 0** — it silently takes one side of the graph-vs-endpoint fork
  against the surviving north star, and most other findings are downstream of
  that unargued choice.
- **Finding 1** — it discards decided and partly *shipped* design from the nine
  docs it deletes, without disposition (232 dangling source citations across 78
  files).
- **Finding 2** — it collides with the landed D2 schema layer (one real design
  task + three cheap statements).
- **Finding 3** — three capability layers half the plugin ecosystem needs have
  no home in it, despite shipped partial implementations of all three; and the
  doc's own §2.2 premise depends on machinery its migration plan deletes.

Estimated shape of the fix: two or three focused revision passes on this doc,
plus three companion docs (substrate, config, input/dispatch). Not a rewrite.

## Finding 0 — the graph-vs-endpoint fork is unargued

`doc/architecture.md` (surviving, current) still says: "text is a degenerate
projection" (:26), "dired is a projection of the filesystem graph" (:75),
"**Editing a projection mutates the graph (the editable-projection work — dired
— is the first instance)**" (:85). The shipped substrate trajectory is squarely
that north: register ferry, subbuffers, GraphDoc/GraphCollab, region leases,
PartialDoc, editable dired name fields.

The new doc, without arguing it, reclassifies Files and Git as owner-authoritative
**Endpoint** services — an LSP-shaped typed-RPC world — and bans the universal
object (§4). The register ferry, sub-document grants, d3 refusal semantics, and
editable projections did not fall out of the consolidation independently; they
fell out **together because they are graph-north machinery**.

The endpoint model is likely *right* for external authorities (a filesystem or
git repo is not a CRDT you replicate; a mirror lies about authority and
staleness), and the graph remains right for owned/replicated state (documents,
notes, drafts, transcripts, plans). But that per-domain decision must be argued
**in the text of both docs**, or the project has two norths. This goes first in
the revision order; Findings 1 and 3 partially collapse into it.

## Premise audit (§2, verified against the working tree)

| Premise | Verdict | Evidence |
| --- | --- | --- |
| 2.1 entry secretly an editor | CONFIRMED verbatim | `Buffer` has literal `editor`/`mode`/`read_only`/`semantic_focus` fields (`src/core/Buffers.zig:57-82`); `attachFocusedSemanticView` builds a full Editor then sets `read_only = true` (`Buffers.zig:284-316`) |
| 2.1 two-pane limitation | CONFIRMED | Only `top_row` is per-pane (`src/gfx/window_layout.zig:65-69`); cursor/selection/folds per-buffer, mode per-head; a peeked pane draws no caret and shows the focused head's mode (`frame_builder.zig:536,551`) |
| 2.1 undo misrouting | CONFIRMED | `cUndo` goes unconditionally to `ctx.editor().undo` (`builtins.zig:191-194`); `save`/`navigate-back` are overridable actions, undo is not; field rollback in `plugin_semantic/field.zig:174-200` unreachable from `u` |
| 2.2 unhandled keys → insertion | CONFIRMED, mechanism must be re-attributed | The `.text` fallthrough exists (`dispatch.zig:499-501,581-590`); `default`'s `insert-text` is inherited unless a plugin manually opts out (`builtins.zig:586`; emacs deliberately inherits). **The Tab example is TRUE today but via a different path**: `cInsertTab` runs `semanticFieldInput` *before* the read-only check; `inputFocusedField` (`semantic.zig:917-983`) filters only `\r\n` for single-line fields, so `\t` passes to `provider.edit`; Model-2 dired ships editable name fields (`plugins/dired/guest.zig:857-860`, `files.zig:64`). During a rename in the file browser, Tab inserts a literal tab into the draft. §2.2 should re-attribute: input that fails structural interpretation is still synthesized into the nearest editable surface — the boundary error migrated into the field machinery. NB: this means §2.2's flagship symptom lives in the editable-field machinery Phases 3–5 would delete (see Finding 3b) |
| 2.3 concrete-command coupling | CONFIRMED for vim/git; two cited examples overstate | vim: 9 `semanticActive()` sites + a `semantic_command` column in the motion table (`vim.zig:67-93`); git: seven locked/private modes (`git.zig:292-484`). helix→vim is one line, dead in the helix profile; make→run is documented mode-name reuse. The airtight evidence is config: `config.northstar.js` has **110 `weft.bind` to concrete commands and 2 `weft.action`**; `dual.js` states its own load-order dependence |
| 2.4 presentation vs domain identity | CONFIRMED | One `Node` carries content+layout+focusable+facts+actions+target (`src/semantic_model/scene.zig:58-67`); dispatch is view-owner-exclusive (`view_runtime/action.zig:113-121`); git stores byte ranges into rendered text, restores focus by clamped ordinal heuristic (`git.zig:109-124,1739-1774`) |
| 2.5 separate worlds | CONFIRMED | Palette enumerates registry name strings; which-key reads the resolved key→command table; advertisement *is* authorization (`action.zig:87-96`); `invokeInteraction` skips even that (`action.zig:99-111`) |
| 2.6 ambient async | CONFIRMED strongly | `procToBuffer` re-resolves by name string at delivery (`wasm_host/proc.zig:229,310`); git `on_fill` reads whichever buffer is active and dispatches on its name (`git.zig:497-523`); LSP writes through ambient doors with snapshot guards; singletons everywhere (repl kills the prior session, `repl.zig:37-40`) |
| 2.7 authority divergence | CONFIRMED AND UNDERSTATED | **No buffer-mutation permission exists in any runtime** (perm space: fs_read/fs_write/net/proc/timer, `wasm_host/plugin.zig:28-44`). **The JS plane bypasses checks entirely** — `JsPlugin` has no perms/grant fields; `cProcSpawn`/`cFileRead`/`cAgentWrite` perform effects unchecked (`quickjs.zig:505-529,831-850,1017-1039`; `cAgentWrite` is *attributed* as an agent peer but not *authorized*). Native in-process: `perms = @splat(true)` (`window_head.zig:99`). Matches `extensibility-native-surface.md` MUST-FIX holes #1/#2 |
| 2.8 sharing too coarse | CONFIRMED | Per-buffer quads (ops/presence/diagnostics/blobs) with `DocKind{text,graph}`; `publish_presence` defaults **true** (`Collab.zig:65`) — sharing text today bundles presence, violating the doc's own §18 gate |
| 2.9 silent limits | PARTLY STALE — update examples | git MAX_FILES/MAX_HUNKS/RAW_CAP and whitespace 64KiB now *report*. Still silent: RENDER_CAP/PATCH_CAP/MAX_COLLAPSED, LSP MAX_DIAG=256, `pick_targets[256]`, consult/buffers arrays, git `activeName` 256-byte name truncation (`git.zig:518-522`). Live bug: grep/run truncate >1KiB paths with `@min` then open the wrong file (`grep.zig:93-95`, `run.zig:79-81`) |

## What the doc gets right (do not lose in revision)

The workspace-entry/editor split; the PhysicalInput/TextCommit split;
generation-checked endpoint refs; "catalog visibility is never authority"; the
pure resolution trace (`explain()` — the single best absorption from the deleted
docs); availability richer than a boolean; publications with epochs and
per-export grants; the at-most-once remote key; §13.7 offline behavior; §15;
§19. §16's conformance map matches the real plugin set (add `ex.zig`,
`badge.zig`; the `deny`/`fs_limit` fixtures it references exist). The doc is
quietly excellent for agents — self-describing actions + parameter schemas +
grants + provenance is an agent tool surface for free; §14.7 undersells this.

## Finding 1 — discards decided and shipped design without disposition

The nine deleted docs contained ratified decisions, proven-dead designs, and the
design records for shipped modules. Sibling-doc diffs are citation-scrubbing
only; **232 source references across 78 files** now cite documents that do not
exist (`GraphCollab.zig`, `region_lease.zig`, `syntax_claim.zig`, `backing.zig`,
`transcript.zig`, …). Full dispositions: `doc/cwa-prior-docs-audit.md`.

Re-scored after adversarial review — **one real contradiction, two dropped
requirements needing paragraphs, two non-contradictions needing sentences**:

1. **Sub-document grants (the real contradiction).** `grants.zig` ships
   `DocRegion` (:218) and `GraphSubtree` (:224) with collapse-and-trap,
   enforced at `command.zig:220` (`checkDocRegion`). §13.5's Grant scope is
   resource-level; §13.6's checkboxes are document-granular. "An agent may edit
   only this function" — the north-star flagship — is unexpressible in the
   doc's grant vocabulary. Needs a real design decision (designation-scoped
   grant targets would fit).
2. **Transfer carries identity (dropped requirement).** §5.2 already keeps
   "transfer protocol packages" in the standard composition — the
   editor-agnostic home `editable-projection.md` demanded (its complaint was
   vim's *private* register that helix free-rode). Missing sentence: *transfer
   payloads carry designations/facts, so cut→paste is move, not create*.
   §17.3.4/§19's demolition of "core-owned registers" is then fine as written.
3. **d3 poison prevention (dropped requirement).** §13.7's "rejected reconnect
   edits become a visible recoverable fork" *is* d3's recovery in one line, and
   §13.5's grant-knowledge trichotomy seeds prevention. Missing paragraph: for
   replicated history, refusal is poison-shaped by construction (refuse-before-
   merge → frontier never advances → re-offered forever; batches refuse whole),
   so admission must be *prevented* — announce grants to their grantees, check
   locally before minting ops — with fork/re-bootstrap as backstop. Cite d3's
   two proven-dead designs (revert-in-batch; op-subset admission) so nobody
   rebuilds them.
4. **Wire flag-day (non-contradiction).** w7's ratification carried "if a
   mixed-version fleet exists before W7a lands, this decision reopens"
   (w7:317). §13.4 describes the world where that condition holds. Owes a
   citation, not an argument.
5. **Presentation locus (non-contradiction).** "Remote heads fire the UI slots
   over the wire" (north-star-plan:452) and §13.3 rule 1 are compatible: the
   head still renders locally over wire-delivered content, and the shipped view
   runtime already carries a locus (`view_runtime/view.zig:281,297`) — a
   scene-stream export is an Endpoint like any other. Owes one sentence on
   whether the thin-head/daemon topology is in scope.

Remedy: (a) a "Relation to prior designs" section with an explicit supersession
map (absorbed / superseded-with-reasoning / out-of-layer, per decision — use the
audit doc as the checklist); (b) a **substrate companion doc** re-homing the
d1/d3/w7/sessions-design decisions and as-built records; (c) the five items
above resolved in the text; (d) dangling citations fixed as phases touch each
module.

## Finding 2 — the landed D2 schema layer

D2 (`d2-schema-payloads.md`) is landed (`src/core/schema.zig`, slot machinery).
Re-scored: **one Phase-1-blocking design task + three cheap statements**:

- **Task: generalize the closed identity marks.** D2 hard-codes `anchor` and
  `range` — text/CRDT-specific — as the only identity kinds; §4 forbids exactly
  this closed enum, and §14.3's OIDs/refs/hunk locators degrade to untyped
  `str`/`bytes` losing D2's restamp/grant-walk payoff. Generalize to
  locator-of-protocol-P per §6.3.
- Statement: add the `variant` constructor — D2's own pre-planned trigger
  ("degenerate encodings until a client forces a real `variant` constructor",
  d2:130-131); this architecture is that client (Designation, Extent,
  `Decision|NeedInput|Unavailable`, availability, outcomes, `Export` are sums).
- Statement: restamp is for the *observation* path (anti-spoofing — matches the
  code's intent); refuse-or-re-resolve is for *effects*. Say the split.
- Statement: versioning — slot/protocol name is the major unit; D2's
  additive-only rule covers minor evolution; content-derived digests negotiate
  at the collaboration membrane only.

Also: D2's roadmap chain points at deleted `north-star-plan.md`; unify the two
migration clocks (D2's W-chain and §17's phases) into one.

## Finding 3 — three missing capability layers (each half-shipped)

**(a) Annotation/decoration layers.** No mechanism for a third party to put
visuals over another's presentation: diagnostics squiggles, search highlights,
git gutter/blame, inlay hints, DAP inline values, ghost text, indent guides,
easymotion labels, breakpoint glyphs, IME preedit. The substrate ships —
`core/layers.zig` ("Annotation layers — the feed substrate", including
*presence spans*: the doc's own §13.1 presence renders through a mechanism the
doc doesn't have), `capabilities.md`'s diagnostic/highlight feeds,
`rendering.md`'s `ui/overlay`/`ui/gutter-segment` slots, editable-projection's
committed decoration renderer and its recorded finding (placement enums exist;
an inline-virtual renderer is the cheap path). Pull in a standard annotation
protocol package: revision-stamped extent→role/content feeds into named
provider-owned layers, composited by the presentation.

**(b) Presentation embedding (the general form of "editable projections").**
One capability at three depths: (i) **render-embed** — read-only, async
placeholder→resolved, windowed, hit/focus mapping composed recursively through
the §11.6 contract; (ii) **editable field** — a single-line extent routing
TextCommits to an endpoint, everything else read-only *by construction* (the
inverse of `readOnlySpan`); (iii) **full sub-editor** with its own input state
— explicitly deferrable. Note embeds, notebook cells, the console prompt line,
and wdired name fields are this one mechanism at different depths. Currently
the capability is neither preserved, superseded, nor refused: §14.2 is silent
on rename (form-based *permission* editing only); §19 would delete the register
ferry; and per the premise audit, **§2.2's flagship symptom lives in the shipped
field machinery** (`on_semantic_field_edit`, `inputFocusedField`,
`requestFocusedFieldEdit` at `semantic.zig:989`). This also contradicts the
surviving north star (architecture.md:85). Decide explicitly; the shipped
investment and the embeds use-case (see `cwa-config-decisions.md`) argue for
depths (i)+(ii) in scope, (iii) deferred.

**(c) Input postures + reconcile modes.** The doc demolishes locked modes
(right) but gives a presentation no way to declare how input *rests* —
re-opening the mode-leak class. Shipped `restingMode`/`lockedMode`/`textInput`
is the crude version; the clean version: a presentation-declared **posture**
(`structural` / `text` / `field` / `capture`) that the input grammar interprets
— declaration in the presentation, policy in the grammar. `capture` (raw
physical input to an endpoint + mandatory user-configurable break-out) is the
missing story for terminal emulators — §1 lists terminals; no PTY/terminal
protocol exists anywhere. And d1's **on_save / live / authoritative** table
belongs here as per-tool protocol metadata ("a half-typed rename must not
`mv`"; "a seek is a command, the position is a latest-wins feed, and
CRDT-merging it would be actively wrong"), stated per tool, never defaulted.

## Additional findings (from the adversarial re-review)

- **§17 contradicts its own sequencing.** "No dual-architecture adapters" — yet
  Phase-3-migrated grammars must drive unmigrated Git/LSP for ~five phases,
  which requires intention→legacy-command trampolines (§19's banned artifact).
  Define "opaque legacy entries" to sanction exactly this bridge, with a
  shrinking CI-enforced allowlist.
- **§13.6 confused-deputy hole.** The approval preview must render from
  *authenticated grant descriptors*, never provider-supplied labels — otherwise
  a checkbox saying "See my cursor" can sit over a grant for `git.push`.
  Presentation metadata has no authorization semantics (§9.1), but in §13.6 it
  *mediates consent*. Needs a stated rule.
- **The two-clock problem.** `FocusRef` is presentation-revision-local (§6.4);
  offers capture resource revisions (§9.1). The mapping contract — who
  translates a hit at presentation-rev N to a designation valid at resource-rev
  M, and what "stale" means when the clocks disagree — is unspecified and
  load-bearing for Git's hybrid presentation.
- **Interaction-stack input routing** is unspecified: which grammar owns keys
  while an interaction is up, and how postures compose with the stack. The
  mode-leak class in v2 costume; adjacent to but distinct from postures.
- **§5.2's "replaceable composition" is untested.** Every acceptance gate
  assumes the standard workspace. Add a gate (a notebook-shell or tiling
  composition) or mark replaceability aspirational.
- **Transfer as egress.** Once transfer payloads carry designations,
  yank-in-granted-region → paste-at-a-peer moves identity metadata across a
  publication boundary; §13's egress rights never mention the transfer package.

## Disciplines to restore (with destinations)

Into **this doc, Phase 1**: the dispatch-latency instrument + budget with a
baseline captured before anything moves (north-star-plan C10), and the
**pushed-offer-table catalog model** — providers publish declarative,
revision-stamped offer tables; the catalog is a pure function over them;
per-keystroke resolution is a cached table walk. This is an architectural
commitment, not garnish: without it, per-keystroke resolution over wasm
providers is dead on arrival, and it is what makes Q3/Q6/Q16 answerable
coherently. Also: the native-blob trust statement — uniform authority *model*
with honest enforcement tiers ("against mistakes the structure holds on both
transports; against malice, only wasm sandboxes"; native in-process is TCB with
kernel-module-grade consent). §2.7/§18 currently assert a uniformity the prior
doc called a lie.

Into **companion docs**: the five-key total resolution order
`(tier, priority, specificity, owner fingerprint, declaration index)` with
import-tier-below-importer, shadow-vs-collision, and provider pinning for
in-flight sessions (input/dispatch companion — this doc needs only "a
deterministic total order exists; see X"); the position-identity primitive
(EventAnchor, rebase-or-null) as a named standard locator (substrate companion
— note it becomes load-bearing for embeds); sealed config evaluation + manifest
hash approval (config companion); durable targets / `weft://` grammar (upgraded
to load-bearing by embeds — designation story).

## Plugin gallery (trimmed to the instructive entries)

Clean inside the frame: `copy-path` contributor (the doc's own gate);
kakoune-style grammar (multi-extent Selection is native); **jj/Sapling/Pijul**
(stage is already a separate protocol — add a sentence that the VCS package
must not bake the index in as mandatory); **org-mode** (one resource
implementing sequence+hierarchy+items+tables; Tab resolves by designation under
cursor — the Files logic generalizing); keycast (only behind an explicit
input-observation grant — add a line); **agent-driven editing** (the catalog is
the agent tool surface; provenance separates human from executing plugin).

Possible only after the Finding-3 pulls: ghost text, third-party
gutter/blame/inlay/inline-values/search-highlight (all → annotation layers);
wdired/wgrep/inline rename (→ embedding depth ii + §12 sagas); notebooks
(→ embedding, depth iii deferred); terminal emulator (→ capture posture + PTY
package); minimap (→ `ui/rail` + annotation feed); dot-repeat/macros as plugin
(needs one clarifying paragraph: replaying an *intention* re-resolves at
current focus — legal; reusing a stale *decision* — forbidden; §11.4 as written
reads as banning both). **IME/compose-key** (from the re-review): sits between
PhysicalInput and TextCommit, needs preedit-at-caret rendering — stresses §10's
split, postures, and annotation layers simultaneously.

Deliberately outside, rightly: keypress-synthesis IPC; advice/monkey-patching
(state the escape valve: published seams or fork); universal sync-everything;
magical global keybindings; raw JSON-RPC tunnels; silent truncation. Input
middleware (hardtime-style filtering): the pipeline is deliberately not a
filter chain — say it's deliberate.

Two further stress-tests (user-supplied, 2026-08-25) with full analyses and
proposed acceptance gates in `doc/cwa-config-decisions.md`: the **generic
hierarchical sidebar** (needs pane-role *attributes* + layout slot,
follow-focus via a focus feed + retarget op, open-placement hint + policy slot,
and the config model) and **note embeds/transclusion** (needs presentation
embedding, durable text-serializable designations, anchored extents,
query-as-resource reification, presentation-choice-as-parameter). Both fit the
frame; both land exactly in the named holes.

## Migration critique

Phases 1–4 are a horizontal tunnel with first payoff at Phase 5, and Phase 1.1
ratifies everything up front — the waterfall version of the mistake §20 Q5
avoids. Thin Phases 1–4 to what a **Files-plus-one-grammar tracer bullet**
needs (kernel handles, entry/editor split, physical-input separation, minimal
pushed-offer catalog, generic tree UI), gated by the e2e workflow harness; let
Git/LSP/collab migrations force the remaining contracts. Add gates: the latency
budget; plugin ergonomics (`copy-path` in ~50 lines against SDK defaults);
crash isolation (a hung provider killed mid-invocation leaves the workspace
consistent); **no-lost-updates save** (shipped behavior in `backing.zig` with
no gate). Make §19 executable: CI check with a shrinking legacy allowlist per
phase. Unify the two roadmap clocks.

## Answers to §20 (recommendations)

1. **Designation wire form**: D2 encoding + the variant constructor; payloads
   pure values, never handles; standard locators include path-entry, OID,
   span-at-snapshot, and stemma `EventAnchor` (wire.md presence proves
   portability).
2. **Snapshot vs lease**: endpoints leased (generation-checked, revoked on
   teardown/epoch); offers snapshot values (endpoint ref + revision constraint
   + expiry); decisions single-use short leases — for *mutating* actions,
   single-use so the at-most-once key composes locally as well as remotely;
   only designations are reconstructible.
3. **Predicate language**: extend the shipped activation `Predicate` algebra
   (`mode.zig`: host-evaluated data, O(contributions), general expressions
   refused per the ABI footgun list) with protocol-presence, designation-kind,
   extent-shape, and grant-covers atoms; dynamic eligibility is a
   provider-published revision-stamped *fact* or an honest `checking` state.
   One predicate language for activation, capability scope, and offer
   eligibility.
4. **Standard vs plugin protocols**: `std.*` in-repo with conformance fixtures;
   `plugin.<id>.*`; promotion = two independent implementations + a fixture.
   Pick ONE naming grammar — the tree currently has three (flat commands,
   dotted semantic actions, slash slots).
5. **Query/feed**: as the doc says — kernel owns cancellation/backpressure/
   invocation identity; promote patterns after LSP + DAP + collab. Add provider
   pinning for in-flight sessions.
6. **Fallback selection**: the same pure resolver as actions; generic
   tree/table/text/form ship as lowest-tier match-all providers; no probing;
   ambiguity explicit.
7. **Authenticated vs advisory**: authenticated — publication descriptors,
   epochs, grants, revocations, at-most-once outcomes (riding the op-class
   channel like today's grade frame); advisory — presentation metadata. **And
   the consequence: §13.6's approval preview renders from authenticated grant
   descriptors, never provider labels** (see the confused-deputy finding).
8. **At-most-once retention**: per (participant, publication, epoch,
   invocation) until epoch end or bounded TTL+LRU; a miss returns an explicit
   `unknown-outcome` terminal task state requiring user re-issue; never silent
   retry.
9. **Accessibility**: §11.5's list is right, as data over the presentation
   contract with §11.6's bounded window as the traversal unit; event ordering,
   live-region timing, platform role mapping stay in per-platform bridges.
10. **Legacy window**: scoped per migrated area, not calendar; enforced by the
    CI allowlist; the e2e harness runs both profiles until each area's cutover.

## Live bugs (fix now, independent of the migration)

1. grep/run truncate >1KiB paths with `@min` then open the truncated path
   (`grep.zig:93-95`, `run.zig:79-81`); same pattern truncates buffer names at
   256 in git `activeName` (`git.zig:518-522`).
2. The JS plugin plane is wholly ungated — `cProcSpawn`/`cFileRead`/
   `cAgentWrite` with no permission checks, no grant fields on `JsPlugin` — and
   the ACP agent runs on it.
3. `publish_presence` defaults true: sharing text bundles presence (and a
   diagnostics channel) by default, contrary to the §18 gate.

## Revision order

1. Decide the graph-vs-endpoint fork explicitly, per domain, in this doc and
   `architecture.md`.
2. Decide presentation embedding (three depths) + annotation layers — they
   change the presentation contract everything else builds on; the sidebar and
   embeds analyses are the motivating examples and gate sources.
3. Write the supersession map over the nine deleted docs; create the substrate
   companion doc (d1/d3/w7/sessions decisions, proven-dead designs, as-built
   remainders — checklist in `cwa-prior-docs-audit.md`).
4. D2: the locator generalization + the three statements.
5. Sentence-level dispositions: transfer-carries-designations; d3 prevention
   paragraph; thin-head topology; flag-day citation; §13.6 authenticated-
   preview rule; §17 legacy-bridge definition; sub-document grant scope in
   §13.5; postures; on_save/live/authoritative table.
6. Latency gate + pushed-offer-table catalog as Phase-1 commitments; companion
   docs for config (see `cwa-config-decisions.md` — written alongside, the
   sidebar is its acceptance test), input/dispatch (total order, postures,
   interaction routing), and substrate.

## Post-review corrections (2026-08-26)

Four claims above describe a tree that has since moved on; recorded here rather
than edited in place, so the review stays a record of what it saw.

1. **The dispatch-latency instrument already existed.** `src/e2e/latency_test.zig`
   times `dispatchSpec` across representative categories and compares against a
   committed baseline (`src/e2e/latency_baseline.zon`, landed in `a277cb2`).
   Phase 1's item 4 is therefore a re-point, not a build.
2. **`schema.zig` already had `variant`.** The D2 amendment asking for a variant
   constructor was already satisfied: `Schema.variant` is a bounded tagged union
   with `VariantValue` payloads and encode/decode support.
3. **`cAgentWrite` was already authorized.** The JS plane's `qjs_file_write`
   routes through `command.renderInto`, whose grade gate caps `.agent`/`.plugin`
   at the doc's own grant and refuses `Unauthorized`. The ungated-effect finding
   stands for `cProcSpawn`/`cFileRead`, not for buffer mutation.
4. **The premise audit describes the pre-wave tree.** Waves 1 and 2 have landed
   since this review was written; findings that read as open should be checked
   against the current tree before being scheduled.
5. **The dangling source citations are swept.** All 232 comment references to
   the nine deleted docs now point at their current owner (`substrate.md`,
   `configuration.md`, `contextual-workspace-architecture.md`,
   `extensibility-native-surface.md`, or `cwa-prior-docs-audit.md` where only
   the historical record holds the decision).
6. **Wave H landed.** Viewport attributes, the placement policy, and input
   postures (§7, §9.4, §10.4) are in, on `main` as of `fd8b032`
   (2026-08-27).
7. **Wave I landed.** The first two §11.8 embedding depths — render-embed
   and editable field, compositing through the annotation seam — are in, on
   `main` as of `fd8b032` (2026-08-27).
8. **Correction 3 was itself wrong; `cAgentWrite` is now gated.** The claim
   that `command.renderInto` already authorized `qjs_file_write` does not
   survive reading the gate: it computes `gradeMin(doc.my_grant, .edit)`, and
   `Document.my_grant` defaults to `.own` (`src/core/Document.zig:131`), so
   the check passes trivially for every local buffer. It is a COLLAB
   authority check — what grade this peer holds on a shared document — not
   path confinement, and it says nothing at all about *which* path an agent
   may bind and fill. The original ungated-effect finding therefore did
   stand for `cAgentWrite`: with no `requirePerm(.fs_write)` and no
   `pathWithinLimit`, `weft.grant("acp", "fs_write", {root: …})` confined
   nothing at that door, and an ACP agent's `fs/write_text_file` could bind a
   buffer at any absolute path outside its granted root. (Not silent disk
   corruption — the write lands in a buffer, and only a user save reaches
   disk — but a confinement gap all the same.) `cAgentWrite` now takes
   `cFileRead`'s two checks, possession then limit, and `qjs_file_write`
   returns `denied` so `weft_qjs.c` throws at the JS call site instead of
   refusing silently. Correction 3 is left above as written, per this
   section's own convention.

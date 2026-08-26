# Configuration model + two stress-test plugins (sidebar, note embeds)

Status: DECISION WALK, 2026-08-26 — ABSORBED: the normative form of these
decisions is `configuration.md` (config model) plus the architecture doc's
§7/§9.4/§11.8/§18 (sidebar and embeds machinery and gates). This file remains
the rationale record — the option analysis, risks, and hard-to-undo rankings
behind those choices. The two plugins below are the motivating examples and
acceptance-gate sources.

## D0. The line: where config code is welcome

Foundations already decided elsewhere: config evaluation is SEALED
(deterministic, injected clock, no ambient I/O; output = a manifest value +
hash that approval binds to — north-star-plan, must be restored), and config
runs as an ordinary principal ("config is a plugin with no special powers" —
extensibility-native-surface.md). Given those, the line is not code-vs-data.
It is two orthogonal lines:

1. **Eval-time vs runtime.** Code that runs at eval to *compute the manifest*
   is unlimited and idiomatic — a loop generating twelve bindings is
   programming-the-manifest, not a smell. What must end up AS DATA is anything
   that participates in **resolution**: bindings, provider registrations, slot
   overrides, placements, predicates, grants. Not aesthetics — `explain()`,
   which-key, the approval diff, and the deterministic total order all read
   the manifest; runtime code there breaks explanation and approval at once.
2. **Provider vs interposer.** Config MAY register runtime code — a statusline
   segment, a placement policy, a one-off action. That is just a small plugin
   living in the config file, paying normal plugin costs: it is a principal,
   occupies a slot at the config tier, appears in resolution traces as itself.
   What is REFUSED is code that *intercepts* rather than *provides* —
   undeclared hooks wrapping other plugins' dispatch or sitting in the
   keystroke path outside a slot (the Emacs-advice failure mode; breaks
   explainability and the latency contract).

> Code is welcome at eval time and welcome as a declared provider in a slot;
> it is refused as an undeclared interposer.

Payoff to state as a feature: because config and plugins are the same thing, a
provider that grows up **graduates by moving to a file** — no rewrite. That is
the moldable-dev on-ramp. Friction where behavior fits no slot is the signal a
slot is missing (the ABI footgun list already applies this rule to predicates).

Three config planes, distinguished once:
- **Manifest plane** — declarations feeding resolution and approval (bindings,
  providers, slots, grants, fragments via `weft.use`, viewport/present
  declarations). Data by necessity; sealed-eval + hash-approved.
- **Instance plane** — scoped options on live things ("*this* sidebar's Files
  view hides dotfiles"). The flat `weft.set(owner, key, value)` triple cannot
  express the scoping; needs a small scoped-value substrate resolved by the
  same most-specific-wins machinery.
- **Content plane** — parameters stored in resources (a note-embed's view
  params). Owned by the embed contract, not the config system.

The architecture doc owns exactly three invariants; everything else goes in
the config companion doc: (1) resolution inputs are manifest data; (2)
config-registered providers are ordinary principals at the config tier; (3)
sealed eval + manifest hash is the trust boundary (restores the dropped TOCTOU
close).

## D1. Pane roles: attributes + a policy slot, not an enum

Recommend: a small set of orthogonal, workspace-enforced viewport
**attributes** (participates-in-cycling, persistent-across-entries, dock-edge,
focus-follow-eligible), layout as the `ui/layout` slot (rendering.md),
"sidebar" as a named *bundle of attributes* in a config fragment
(`weft.use("sidebar")`). Rejected: a role enum (`primary|dock|drawer`) with
baked semantics — a closed ontology (the doc's own non-goal) whose vocabulary
will churn; and the status quo, where every sidebar-ish plugin reinvents
window management (complecting subject + presentation + layout + lifecycle +
input) and two such plugins fight.

Gain: sidebars/drawers/palettes declarable without kernel ontology; layout
swappable as one slot. Risk: attribute soup — apply rendering.md's granularity
rule (carve an attribute iff someone would swap just it); version attributes
like any protocol. Hard to undo: the enum (configs would reference role names
with baked semantics); attributes are additive and deprecable.

## D2. Follow-focus: a feed + an op, not a binding language

Recommend: two ordinary primitives — **primary-focus-change as a subscribable
feed** (pane attributes visible, so companions ignore companion-focus; that
kills the outline-retargets-to-itself bug structurally) and **viewport
retarget as a protocol op** ("present resource R in viewport V") — plus a
*consumer* doing the following: a shipped first-party companion-view helper
parameterized by config, or ten lines of provider code in someone's config.
Both sanctioned under D0.

Rejected: declarative reactive subject bindings
(`subject: follows(focused, lang.symbols)`) evaluated by the workspace — a
mini expression language with evaluation order, error semantics, explain
integration, and grammar versioning, invented to avoid ten lines of code. The
decisive argument for the simple version: both primitives are needed
regardless (statuslines, titles, breadcrumbs, presence all consume focus
state; retarget is just placement), so the architecture pays nothing new.

Gain: no DSL; two reusable primitives; a laggy follower is honestly a laggy
consumer, not a mysteriously broken kernel. Risk: slight retarget latency
(acceptable, UI-async by nature). Hard to undo: the DSL, extremely (user
configs would embed expressions in a bespoke grammar); consumers, trivially.
Complection avoided: the DSL fuses query language + reactivity + workspace
state; the split keeps feed = state change, query = the provider's business,
retarget = an op.

## D3. Open placement: a hint + one policy slot, not a rule system

Recommend: §9.4 outcomes carry an optional placement **hint**
(self | primary | new-split | background); one first-wins **policy slot** maps
(hint, source-viewport attributes, target kind) → pane; the default provider
is a small sane table; exotic routing = override the provider with a little
code. Rejected: a declarative placement-rule system (`display-buffer-alist`
is the cautionary tale of a rule *language* accreting until nobody can predict
placement) and the status quo (openers pick panes imperatively — the source of
"grep result opened inside my sidebar" jank).

Gain: kills the misplaced-open class; policy swappable as one slot; placement
decisions appear in resolution traces. Risk: hint vocabulary too coarse — keep
hints optional, let the provider see the full outcome + context; resist
growing the default's table (exotics belong in overrides). Hard to undo: a
rule DSL, very; the hint set, moderately (protocol-versioned); default
provider behavior, trivially.

## Decision summary

| Decision | Recommend | Biggest gain | Biggest risk | Hardest-to-undo (avoid) |
| --- | --- | --- | --- | --- |
| Pane roles | Orthogonal attributes + `ui/layout` slot; "sidebar" = named bundle | Sidebars without kernel ontology | Attribute drift | A role **enum** with baked semantics |
| Following | Focus feed + retarget op + shipped helper; loop may be config code | Two primitives everything reuses | Slight retarget lag | A reactive **binding DSL** |
| Placement | Outcome hint + one policy slot + small default | Kills misplaced-open jank | Default table growing hair | A placement **rule language** |
| Config line | Eval-time code unlimited; runtime code = declared providers; interposition refused | Explain/approval stay sound; graduation is a file move | Slot gaps forcing hacks (treat as signal) | Any undeclared runtime hook surface |

Through-line: everywhere the first instinct was new declarative *vocabulary*,
the simpler answer was an ordinary feed/op/slot already needed elsewhere, plus
permission for a little provider code. The only things that genuinely must be
data are what `explain()` and the approval hash consume.

---

## Stress-test plugin 1: the generic hierarchical sidebar

Goal: a docked sidebar showing hierarchical things — slot in the file browser
for a project view, or document symbols, or tree-sitter objects — as a
*configured composition*, not a bespoke plugin.

What already works on paper: anything implementing the hierarchy protocol
package (§5.3) renders in the generic tree presentation (§5.2); Tab/Return
resolve to the same intentions everywhere; the catalog union puts each
provider's actions on its rows; the two-panes-one-resource acceptance gate
covers sidebar + Files entry showing the same directory. The sidebar is *the
generic tree presentation, docked*.

Four missing pieces (D1–D3 above supply the first three; the config companion
supplies the fourth):
1. Pane attributes + layout slot (D1) — lifecycle, cycling exclusion,
   persistence, dock edge.
2. Follow-focus (D2) — a symbols outline's subject is a function of the
   focused entry; the companion consumer retargets on the focus feed,
   ignoring companion-focus.
3. Open placement (D3) — Return in the sidebar opens in the primary pane
   while the sidebar keeps its root.
4. The config model — the sidebar is a manifest fragment: a viewport
   declaration + a subject + a presentation choice + instance-plane options
   (hidden files, sort, depth). This is systems-as-manifests (north-star
   missing primitive #3) arriving concretely.

Sidebar-context behavior: same designations, same actions; compact affordances
(§9.1's compact labels); title/navigation suppressed (the sidebar keeps its
root); input posture `structural`.

Proposed acceptance gate:
> A docked sidebar showing project files, document symbols, or tree-sitter
> objects is a config fragment plus the generic tree presentation —
> expressible with zero interposing behavior, everything visible to
> `explain()`; following-logic may be a few lines of declared provider code.

## Stress-test plugin 2: note embeds (transclusion)

Goal: embed live things in notes — a git commit, a file browser, a link to
where you were when you captured a thought — stored as text, resolved as
needed, always up to date, without hurting note-editing perf, with a clean
fallback when unresolvable. Bonus: multiple views on the same data.
Generalizes to literate/moldable dev, spreadsheet-ish reactive journals,
dashboards, inline agent conversations, PR review comments.

The model that fits: an embed is a **text span containing a serialized durable
designation plus view parameters** (a `weft://`-style value in the note's
character sequence). Text is the storage format AND the fallback rendering:
when a designation cannot resolve (offline peer, missing provider, revoked
grant, dead commit), the embed renders as its own textual form plus a reason —
the fallback is the storage form showing through (generalize-the-degenerate-
case at micro scale). The note presentation hosts, at each embed span, an
embedded presentation of the designated resource: lazily (resolve on
scroll-into-view, §11.6 windowing), live (subscribing to the resource's
feeds), asynchronously (placeholder → resolved; the typing hot path never
blocks on resolution — the latency contract applies).

Falls out with zero new machinery:
- Durable designations for the examples exist: commit OIDs (§14.3), Files
  entry identity, and capture-context links = a target + a stemma
  `EventAnchor` (wire.md's presence already proves anchors portable and
  rebase-safe on the wire).
- Grants: embedding confers nothing; opening a note full of embeds you lack
  grants for degrades each to text+reason — "catalog visibility is never
  authority" paying off unprompted.
- PR review comments: the embedded resource is a shared replica while the
  note stays private — publication boundaries attach per embedded resource
  (§13.2 granularity).
- Inline agent conversations: an embed designating an ACP session resource
  (instantiable sessions, §14.7); the prompt line is an editable field.
- Dashboards: a note that is mostly embeds, opened at startup. The note is
  the ad-hoc UI composition surface (the moldable-dev story).

Five demands — each an upgrade of an existing review finding, not a new hole:
1. **Presentation embedding** (cwa-review.md Finding 3b, general form): one
   capability at three depths — (i) render-embed: read-only, async, windowed,
   hit/focus mapping composed recursively through the §11.6 contract; (ii)
   editable field: a single-line extent routing TextCommits to an endpoint,
   the rest read-only by construction; (iii) full sub-editor with its own
   input state — deferrable. Embeds mostly need (i), plus (ii) for prompt
   lines and checkbox-style updates. Note embeds, notebook cells, the console
   prompt, and wdired name fields are this one mechanism at different depths.
2. **Durable, text-serializable designations** — the `weft://` grammar (or
   equivalent) becomes normative, because designations now live inside
   documents (upgraded from session-restore nicety to load-bearing).
3. **Anchored extents** — embed spans must survive concurrent edits to the
   note (it is a CRDT), so extents are anchor-stamped: the position-identity
   primitive (audit item 21) becomes load-bearing here too.
4. **Query-as-resource** — the reactive half: an embed whose designation is a
   *reified standing query* (protocol + parameters as a durable target) with a
   subscription lifetime; a table or sparkline presentation renders the feed.
   §8 already has subscriptions; the missing sentence is that query+params can
   be reified into a designatable, embeddable target. The reactive dependency
   graph (spreadsheet-grade incremental evaluation) stays in the query-provider
   plugin (a notes-facts service), NOT the kernel — the kernel gives
   revision-stamped subscriptions; the plugin gives reactivity. That layering
   keeps "spreadsheet" and "literate dev" both expressible without either
   being built.
5. **Presentation choice as an embed parameter** — the same query designation
   renders as a table in one note and a sparkline in another (Q6's selection
   machinery once presentation choice is per-instance parameterizable).

On the graph question (cwa-review.md Finding 0): v1 works with pure-text notes
plus a parser; an ObjectDoc-backed notes plugin would make embeds graph nodes
whose text projection IS the URI text. The embed contract should not care
which — a good test that the fork decision has been made cleanly.

Proposed acceptance gates:
> A note containing an embedded live commit, an embedded directory listing,
> and a captured-location link renders lazily, stays current, degrades each
> embed to its textual form with a reason when unresolvable, and typing
> latency in the note is unaffected.

> One embedded query renders as a table in one note and a sparkline in
> another.
